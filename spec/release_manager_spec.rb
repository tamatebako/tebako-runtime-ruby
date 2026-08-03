# frozen_string_literal: true

require "spec_helper"
require "digest"
require "json"
require "pathname"
require "yaml"

require_relative "../scripts/upload_release"

# Contract version the specs publish under (never a real release version)
SPEC_VERSION = "9.9.9"

# The builder-emitted contract sidecar every era-2 runtime package carries
# (spec 18 C2); executable fixtures get one by default.
SPEC_CONTRACT = {
  "contract_era" => 2,
  "image_layout" => 1,
  "mount_root" => "/__tfs__",
  "built_from" => {
    "release" => "v0.2.13",
    "sources" => [{ "name" => "tfs-ruby-3.3.7-src.tar.gz", "sha256" => "0" * 64 }]
  }
}.freeze

# Recording octokit stand-ins: ReleaseManager accepts any client object
# (client:), and every publish interaction becomes observable through the
# store's public collections; transient failures are scriptable per call.
FakeAsset = Struct.new(:id, :name, :browser_download_url)

class FakeResponse
  attr_reader :data

  def initialize(data)
    @data = data
  end
end

class FakeAssetsRel
  attr_reader :gets

  def initialize(store)
    @store = store
    @gets = 0
  end

  def get
    @gets += 1
    FakeResponse.new(@store.assets)
  end
end

class FakeRelease
  attr_reader :id, :url, :rels

  def initialize(store)
    @id = 42
    @url = "https://api.github.test/releases/42"
    @rels = { assets: FakeAssetsRel.new(store) }
  end
end

class FakeAssetStore
  attr_reader :assets, :uploads, :deletes, :updates, :attempts, :upload_content_types
  attr_accessor :manifest_json

  def initialize(names = [])
    @assets = names.each_with_index.map { |name, index| FakeAsset.new(index + 1, name, "https://download.test/#{name}") }
    @uploads = []
    @deletes = []
    @updates = []
    @attempts = Hash.new(0)
    @upload_content_types = {}
    @manifest_json = nil
    @failures = Hash.new { |hash, key| hash[key] = [] }
  end

  def fail_next(call, error)
    @failures[call] << error
  end

  def attempt(call)
    @attempts[call] += 1
    raise @failures[call].shift unless @failures[call].empty?
  end
end

class FakeClient
  def initialize(store)
    @store = store
    @release = FakeRelease.new(store)
  end

  attr_reader :release

  def release_for_tag(_repo, _tag)
    @release
  end

  def upload_asset(_url, _path, content_type:, name:)
    @store.attempt(:upload)
    @store.uploads << name
    @store.upload_content_types[name] = content_type
    @store.assets << FakeAsset.new(@store.assets.size + 100, name)
  end

  def delete_release_asset(id)
    @store.attempt(:delete)
    @store.deletes << id
    @store.assets.reject! { |asset| asset.id == id }
  end

  def update_release(_url, body:)
    @store.attempt(:update)
    @store.updates << body
  end

  def get(_url)
    @store.attempt(:get)
    @store.manifest_json or raise Octokit::NotFound
  end
end

RSpec.describe ReleaseManager do
  around do |example|
    old = %w[GITHUB_TOKEN TEBAKO_VERSION EXPECTED_ENV_MATRIX EXPECTED_RUBY_MATRIX FORCE_REBUILD AUDIT_ONLY]
          .to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV["GITHUB_TOKEN"] = "test-token"
    ENV["TEBAKO_VERSION"] = SPEC_VERSION
    ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"macos-15","container":null,"os":"macos","arch":"arm64"}]'
    ENV["EXPECTED_RUBY_MATRIX"] = '["3.3.7"]'
    ENV.delete("FORCE_REBUILD")
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  let(:manager) { described_class.new }

  def package(name, contents = name)
    @dir.join(name).tap do |path|
      path.write(contents)
      write_contract_sidecar(path) unless name.end_with?(".tfs", ".abi", ReleaseManager::CONTRACT_SIDECAR_SUFFIX)
    end
  end

  def write_contract_sidecar(path, contract = SPEC_CONTRACT)
    File.write("#{path.to_s.sub(%r{\.exe\z}, '')}#{ReleaseManager::CONTRACT_SIDECAR_SUFFIX}", YAML.dump(contract))
  end

  def with_packages(&block)
    Dir.chdir(@dir, &block)
  end

  it "folds the sibling .tfs into the package entry as an additive image key" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")

    entries = manager.build_manifest_entries([exe, img])

    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry[:filename]).to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    expect(entry[:ruby_version]).to eq("3.3.7")
    expect(entry[:platform]).to eq("macos-arm64")
    expect(entry[:image]).to eq(
      filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs",
      sha256: Digest::SHA256.file(img).hexdigest,
      size_bytes: img.size
    )
  end

  it "omits the image key when the package has no sibling image" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    entries = manager.build_manifest_entries([exe])

    expect(entries.size).to eq(1)
    expect(entries.first).not_to have_key(:image)
  end

  it "keeps pre-image manifest consumers working (existing keys unchanged)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")

    entry = manager.build_manifest_entries([exe, img]).first

    expect(entry.keys).to contain_exactly(:tebako_version, :contract_era, :contract_version, :ruby_version,
                                          :platform, :filename, :sha256, :size_bytes,
                                          :mount_root, :image_layout, :built_from, :image)
    expect(entry[:tebako_version]).to eq(SPEC_VERSION)
    expect(entry[:sha256]).to eq(Digest::SHA256.file(exe).hexdigest)
    expect(entry[:size_bytes]).to eq(exe.size)
  end

  # Spec 18 C2: the era-2 contract card — contract_era / mount_root /
  # image_layout / built_from flow from the package's builder-emitted
  # .contract.yaml sidecar into the entry unchanged.
  it "flows the contract sidecar fields into the manifest entry" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    entry = manager.build_manifest_entries([exe]).first

    expect(entry[:contract_era]).to eq(2)
    expect(entry[:mount_root]).to eq("/__tfs__")
    expect(entry[:image_layout]).to eq(1)
    expect(entry[:built_from]).to eq(
      "release" => "v0.2.13",
      "sources" => [{ "name" => "tfs-ruby-3.3.7-src.tar.gz", "sha256" => "0" * 64 }]
    )
  end

  # S11/S16: a package without the builder's contract sidecar is pre-era;
  # the publish refuses it by name rather than shipping an under-declared
  # manifest entry (fail closed — no special pleading for side-loaded
  # runtimes either).
  it "refuses a package without the contract sidecar" do
    exe = @dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").tap { |path| path.write("exe") }

    expect { manager.build_manifest_entries([exe]) }
      .to raise_error(/carries no \.contract\.yaml contract sidecar.*pre-era/)
  end

  it "refuses a sidecar declaring a contract era this pipeline does not speak" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    write_contract_sidecar(exe, SPEC_CONTRACT.merge("contract_era" => 3))

    expect { manager.build_manifest_entries([exe]) }
      .to raise_error(/contract_era 3.*speaks 2.*upgrade/)
  end

  it "refuses a sidecar missing contract fields" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    write_contract_sidecar(exe, SPEC_CONTRACT.reject { |key,| key == "mount_root" })

    expect { manager.build_manifest_entries([exe]) }
      .to raise_error(/missing mount_root/)
  end

  # Roadmap 45: every published package entry names the bootstrap <->
  # runtime contract it was built for; the value comes from contract.yml,
  # the release pipeline's single source of truth (never hardcode it here --
  # the next contract bump edits contract.yml and the driver define only).
  it "emits the repo contract version into every manifest entry" do
    expected = YAML.load_file(File.join(REPO_ROOT, "contract.yml")).fetch("contract_version")
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    other = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64")

    entries = manager.build_manifest_entries([exe, other])

    expect(entries.map { |entry| entry[:contract_version] }).to eq([expected, expected])
  end

  # spec 05 §5's abi line: build_runtime's <package>.abi sidecar folds
  # into the entry as the additive `abi` key; absent sidecar, no key
  # (the compat window — pre-abi releases stay consumable).
  it "emits the abi line from the .abi sidecar, omitting it when absent" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.abi").tap do |sidecar|
      sidecar.write("arm64-darwin-23\n")
    end
    plain = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64")

    with_packages do
      # build_manifest_entries sorts by basename: 3.1.6 (no sidecar)
      # first, 3.3.7 (sidecar) second
      entries = manager.build_manifest_entries([exe, plain])
      expect(entries.first).not_to have_key(:abi)
      expect(entries.last[:abi]).to eq("arm64-darwin-23")
    end
  end

  it "never treats .abi sidecars as packages" do
    dir = @dir.join("runtime-packages")
    dir.mkdir
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").write("exe")
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.abi").write("arm64-darwin-23\n")

    with_packages do
      packages = manager.validate_packages_directory
      expect(packages.map { |p| p.extname }).not_to include(".abi")
    end
  end

  it "never treats .contract.yaml sidecars as packages" do
    dir = @dir.join("runtime-packages")
    dir.mkdir
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64").write("exe")
    dir.join("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64#{ReleaseManager::CONTRACT_SIDECAR_SUFFIX}")
       .write(YAML.dump(SPEC_CONTRACT))

    with_packages do
      packages = manager.validate_packages_directory
      expect(packages.map { |p| p.basename.to_s })
        .to contain_exactly("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    end
  end

  it "checksummes both the package and its image, image line following its package" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
    lone = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64")
    entries = manager.build_manifest_entries([exe, img, lone])

    with_packages do
      sums = manager.generate_sha256sums(entries).read.lines.map(&:chomp)
      # Entries (and their sums lines) sort by package name: 3.1.6 < 3.3.7
      expect(sums).to eq(
        [
          "#{Digest::SHA256.file(lone).hexdigest}  #{lone.basename}",
          "#{Digest::SHA256.file(exe).hexdigest}  #{exe.basename}",
          "#{Digest::SHA256.file(img).hexdigest}  #{img.basename}"
        ]
      )
    end
  end

  it "splits images out of the executables sections into their own" do
    files = [
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs",
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64",
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64.tfs"
    ]

    executables = manager.categorize_packages(files)
    images = manager.categorize_images(files)

    expect(executables["macos"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"])
    expect(executables["linux-gnu"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64"])
    expect(images["macos"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs"])
    expect(images["linux-gnu"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64.tfs"])
    expect(images["linux-musl"]).to be_empty
  end

  it "lists image sections in the release notes after the executables" do
    sections = manager.initialize_sections
    sections["macos"] = ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"]
    images = manager.initialize_sections
    images["macos"] = ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs"]

    notes = manager.generate_release_notes(sections, images)

    expect(notes).to include("### macOS executables\n- tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64\n")
    expect(notes).to include("### macOS filesystem images\n- tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs\n")
  end

  it "warns when a package lacks its image" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    expect { manager.report_missing_packages([exe]) }
      .to output(/has no filesystem image \(tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64\.tfs\)/)
      .to_stdout
  end

  it "warns when an image is orphaned (no matching package)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
    orphan = package("tebako-runtime-#{SPEC_VERSION}-4.0.6-linux-musl-arm64.tfs")

    expect { manager.report_missing_packages([exe, img, orphan]) }
      .to output(/4\.0\.6-linux-musl-arm64\.tfs has no matching runtime package/)
      .to_stdout
  end

  it "still warns about missing expected packages" do
    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64/).to_stdout
  end

  it "reads the prepare job's object-shaped ruby matrix rows ({version, src_sha256})" do
    ENV["EXPECTED_RUBY_MATRIX"] = "[{\"version\":\"3.3.7\",\"src_sha256\":\"#{"a" * 64}\"}]"

    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64/).to_stdout
  end

  it "writes the manifest.json asset with the image entries" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
    entries = manager.build_manifest_entries([exe, img])

    with_packages do
      manifest = JSON.parse(manager.generate_manifest(entries).read)
      expect(manifest.size).to eq(1)
      expect(manifest.first["image"]["filename"])
        .to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
      expect(manifest.first["image"]["sha256"]).to eq(Digest::SHA256.file(img).hexdigest)
      expect(manifest.first["image"]["size_bytes"]).to eq(img.size)
    end
  end

  # Spec 18 C2: the published manifest.json IS the release card — the
  # loader reads the contract set before any download, so the JSON must
  # carry every era-2 field (validated here, at the producer).
  it "writes the era-2 contract set into the manifest.json asset" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    entries = manager.build_manifest_entries([exe])

    with_packages do
      manifest = JSON.parse(manager.generate_manifest(entries).read)
      entry = manifest.first
      expect(entry["contract_era"]).to eq(2)
      expect(entry["contract_version"]).to eq(YAML.load_file(File.join(REPO_ROOT, "contract.yml"))
                                                 .fetch("contract_version"))
      expect(entry["mount_root"]).to eq("/__tfs__")
      expect(entry["image_layout"]).to eq(1)
      expect(entry["built_from"]).to eq(
        "release" => "v0.2.13",
        "sources" => [{ "name" => "tfs-ruby-3.3.7-src.tar.gz", "sha256" => "0" * 64 }]
      )
    end
  end

  describe "#verify_completeness" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }
    let(:expected) do
      ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
       "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs",
       "SHA256SUMS.txt", "manifest.json"]
    end

    it "passes quietly when every expected asset is on the release" do
      expected.each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
    end

    it "fails loud and lists a package that never landed" do
      expected.reject { |name| name.end_with?("macos-arm64") }
              .each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*1 missing/)
        .and output(/::error::Missing asset: tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64/).to_stdout
    end

    it "fails loud when a filesystem image is missing" do
      expected.reject { |name| name.end_with?(".tfs") }
              .each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }.to raise_error(/incomplete/)
    end

    it "fails loud when the metadata files did not land" do
      expected.first(2).each { |name| store.assets << FakeAsset.new(store.assets.size + 1, name) }

      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*2 missing/)
        .and output(/Missing asset: SHA256SUMS\.txt/).to_stdout
    end

    it "accepts a windows executable carrying the .exe suffix" do
      ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"windows-2022","container":null,"os":"windows","arch":"x86_64"}]'
      store.assets << FakeAsset.new(1, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
      store.assets << FakeAsset.new(2, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.tfs")
      store.assets << FakeAsset.new(3, "SHA256SUMS.txt")
      store.assets << FakeAsset.new(4, "manifest.json")

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
    end

    it "warns and passes when no expected matrix is available" do
      ENV.delete("EXPECTED_ENV_MATRIX")
      ENV.delete("EXPECTED_RUBY_MATRIX")

      expect { fake_manager.verify_completeness(release) }
        .to output(/completeness is not verifiable/).to_stdout
    end
  end

  describe "publish retry and replace behavior" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    before { allow(fake_manager).to receive(:sleep) }

    it "retries a 422 upload (the delete-then-reupload race) until it lands" do
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      fake_manager.perform_upload(release, exe, exe.basename.to_s)

      expect(store.attempts[:upload]).to eq(3)
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "raises after the upload attempts are exhausted" do
      4.times { store.fail_next(:upload, Faraday::TimeoutError.new) }
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Faraday::TimeoutError)
      expect(store.attempts[:upload]).to eq(4)
    end

    it "retries transient timeouts on idempotent calls" do
      calls = 0
      result = fake_manager.with_transient_retries do
        calls += 1
        raise Faraday::ConnectionFailed, "refused" if calls < 3

        "ok"
      end

      expect(result).to eq("ok")
      expect(calls).to eq(3)
    end

    it "keeps an existing asset unless FORCE_REBUILD is set" do
      store.assets << FakeAsset.new(7, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    it "deletes then re-uploads an existing asset under FORCE_REBUILD" do
      ENV["FORCE_REBUILD"] = "true"
      store.assets << FakeAsset.new(7, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "looks assets up through the paginated assets rel, not the embedded array" do
      fake_manager.find_asset(release, "anything")

      expect(release.rels[:assets].gets).to eq(1)
    end
  end

  # The per-platform publish: each platform leg republishes only its own
  # packages. The manifest merge keeps the previous manifest's entries for
  # every OTHER platform verbatim (the release never loses coverage because
  # one platform republished), and the idempotent skip keeps an unchanged
  # asset from re-uploading (same name + same sha256).
  describe "per-platform manifest merge and idempotent skip" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: client) }
    let(:client) { FakeClient.new(store) }

    def previous_manifest(entries)
      store.manifest_json = JSON.generate(entries)
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")
    end

    def previous_entry(filename, platform, sha256, image_sha256: nil)
      entry = { "tebako_version" => SPEC_VERSION, "filename" => filename,
                "platform" => platform, "sha256" => sha256, "size_bytes" => 1 }
      entry["image"] = { "filename" => "#{filename}.tfs", "sha256" => image_sha256, "size_bytes" => 1 } if image_sha256
      entry
    end

    it "keeps other platforms' entries (image metadata intact) and replaces only this run's platform" do
      previous_manifest([
                          previous_entry("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64",
                                         "linux-gnu-x86_64", "a" * 64, image_sha256: "b" * 64),
                          previous_entry("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                                         "macos-arm64", "c" * 64),
                          previous_entry("tebako-runtime-#{SPEC_VERSION}-4.0.6-windows-ucrt64.exe",
                                         "windows-ucrt64", "d" * 64)
                        ])
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      new_entries = fake_manager.build_manifest_entries([exe])

      merged = fake_manager.merged_manifest_entries(new_entries)

      expect(merged.map { |entry| entry[:filename] }).to eq(
        ["tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64",
         "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
         "tebako-runtime-#{SPEC_VERSION}-4.0.6-windows-ucrt64.exe"]
      )
      # The replaced platform carries THIS run's sha, not the previous one
      expect(merged.find { |entry| entry[:platform] == "macos-arm64" }[:sha256])
        .to eq(Digest::SHA256.file(exe).hexdigest)
      # The kept platforms survive the JSON round trip, image entry included
      kept = merged.find { |entry| entry[:platform] == "linux-gnu-x86_64" }
      expect(kept[:sha256]).to eq("a" * 64)
      expect(kept[:image][:sha256]).to eq("b" * 64)
    end

    it "publishes only this run's entries when there is no previous manifest" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      merged = fake_manager.merged_manifest_entries(fake_manager.build_manifest_entries([exe]))

      expect(merged.map { |entry| entry[:filename] })
        .to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"])
    end

    it "skips re-uploading an asset whose content is unchanged (same name, same sha256)" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", Digest::SHA256.file(exe).hexdigest)])
      fake_manager.build_manifest_entries([exe])

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    it "re-uploads an asset whose content moved (same name, different sha256)" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", "f" * 64)])
      fake_manager.build_manifest_entries([exe])

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "keeps an existing asset when the previous manifest is unreadable (fail conservative)" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
      store.assets << FakeAsset.new(90, "manifest.json", "https://download.test/manifest.json")
      store.manifest_json = "not json {"
      fake_manager.build_manifest_entries([exe])

      expect do
        expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      end.to output(/could not read the previous manifest/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end
  end

  describe "process_release completeness enforcement" do
    let(:store) { FakeAssetStore.new }
    let(:client) { FakeClient.new(store) }
    let(:fake_manager) { described_class.new(client: client) }

    def stage_packages(*names)
      dir = @dir.join("runtime-packages")
      dir.mkdir
      names.each do |name|
        path = dir.join(name)
        path.write("bytes-of-#{name}")
        write_contract_sidecar(path) unless name.end_with?(".tfs")
      end
    end

    it "publishes and passes the gate when the expected set is complete" do
      stage_packages("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                     "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")

      with_packages do
        expect { fake_manager.process_release }
          .to output(/Successfully updated release notes/).to_stdout
      end
      expect(store.uploads).to include("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                                       "SHA256SUMS.txt", "manifest.json")
      expect(store.updates.size).to eq(1)
    end

    it "fails the publish when an expected package never lands" do
      stage_packages("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64",
                     "tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-x86_64.tfs")

      with_packages do
        expect { fake_manager.process_release }
          .to raise_error(/incomplete \(2 missing/)
          .and output(/::error::Missing asset: tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64/).to_stdout
      end
    end

    # AUDIT_ONLY (the 04 audit / a publish dry run): strictly read-only —
    # no uploads, no notes, no local packages needed; the release is only
    # verified against the expected matrix.
    it "audit mode uploads nothing and passes when the release is complete" do
      ENV["AUDIT_ONLY"] = "true"
      ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
       "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs",
       "SHA256SUMS.txt", "manifest.json"].each_with_index do |name, index|
        store.assets << FakeAsset.new(index + 1, name, "https://download.test/#{name}")
      end

      expect { fake_manager.process_release }.to output(/AUDIT mode/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.updates).to be_empty
    end

    it "audit mode fails an incomplete release, still uploading nothing" do
      ENV["AUDIT_ONLY"] = "true"

      expect { fake_manager.process_release }
        .to raise_error(/incomplete \(4 missing/)
        .and output(/AUDIT mode/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.updates).to be_empty
    end

    it "audit mode refuses a tag with no release (and never creates one)" do
      ENV["AUDIT_ONLY"] = "true"
      allow(client).to receive(:release_for_tag).and_raise(Octokit::NotFound)

      expect { fake_manager.process_release }
        .to raise_error(/no release found for tag/)
    end
  end
end
