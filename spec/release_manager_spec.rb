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
FakeAsset = Struct.new(:id, :name, :browser_download_url, :digest, :state)

# A page of the asset listing: data plus a Sawyer-shaped rels whose
# :next link serves the following page (the real API's shape — raw rel
# gets are NOT auto-paginated).
class FakePage
  attr_reader :data

  def initialize(data, next_link)
    @data = data
    @next_link = next_link
  end

  def rels
    @next_link ? { next: @next_link } : {}
  end
end

class FakePageLink
  def initialize(store, offset)
    @store = store
    @offset = offset
  end

  def get
    @store.page_at(@offset)
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
    @store.page_at(0)
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
  attr_accessor :manifest_json, :delete_propagation, :page_size

  def initialize(names = [])
    @assets = names.each_with_index.map { |name, index| FakeAsset.new(index + 1, name, "https://download.test/#{name}") }
    @manifest_json = nil
    @delete_propagation = 0
    init_recorders
  end

  def init_recorders
    @uploads = []
    @deletes = []
    @updates = []
    @attempts = Hash.new(0)
    @upload_content_types = {}
    @contents = {}
    @deleted_assets = {}
    @pending_deletes = {}
    @failures = Hash.new { |hash, key| hash[key] = [] }
    @page_size = 0
  end

  # Paged listing: page_size <= 0 serves everything in one page (the
  # historical fake); a positive size slices the visible assets and links
  # the pages, exactly like the real API's default-30 pages.
  def page_at(offset)
    all = tick_and_visible_assets
    return FakePage.new(all, nil) if page_size.to_i <= 0

    slice = all.drop(offset).first(page_size)
    following = offset + page_size
    FakePage.new(slice, (following < all.size ? FakePageLink.new(self, following) : nil))
  end

  def fail_next(call, error)
    @failures[call] << error
  end

  def attempt(call)
    @attempts[call] += 1
    raise @failures[call].shift unless @failures[call].empty?
  end

  # Per-url asset bytes for the download path; an unstubbed url falls
  # back to the manifest body (the manifest merge reads it through the
  # same client get).
  def content_for(url)
    @contents.fetch(url) { @manifest_json }
  end

  def set_content(url, body)
    @contents[url] = body
  end

  # A landed upload becomes servable: the edge (and the asset's own
  # browser url) serve exactly the bytes that landed, and the listing's
  # digest is their sha256 (the real API's shape).
  def register_upload(asset, bytes)
    asset.digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    @contents[asset.browser_download_url] = bytes
    tag = ENV.fetch("TEBAKO_VERSION", nil)
    return unless tag

    @contents["https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{tag}/#{asset.name}"] = bytes
  end

  # One listing = one propagation tick: a freshly deleted asset stays
  # visible for delete_propagation ticks (the real API's eventual
  # consistency), then vanishes.
  def tick_and_visible_assets
    @pending_deletes.each_key { |id| @pending_deletes[id] -= 1 }
    @pending_deletes.delete_if { |_id, ttl| ttl.negative? }
    visible_assets
  end

  def visible_assets
    @assets + @pending_deletes.keys.filter_map { |id| @deleted_assets[id] }
  end

  def delete_asset(id)
    asset = @assets.find { |candidate| candidate.id == id }
    return unless asset

    @assets.delete(asset)
    return unless delete_propagation.positive?

    @deleted_assets[id] = asset
    @pending_deletes[id] = delete_propagation
  end

  # A same-name upload while the deleted predecessor is still listed
  # 422s, exactly like the real API.
  def assert_uploadable!(name)
    raise Octokit::UnprocessableEntity if visible_assets.any? { |asset| asset.name == name }
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

  def upload_asset(_url, path, content_type:, name:)
    @store.attempt(:upload)
    @store.assert_uploadable!(name)
    asset = FakeAsset.new(@store.assets.size + 100, name, "https://download.test/#{name}")
    @store.uploads << name
    @store.upload_content_types[name] = content_type
    @store.assets << asset
    @store.register_upload(asset, File.binread(path))
  end

  def delete_release_asset(id)
    @store.attempt(:delete)
    @store.deletes << id
    @store.delete_asset(id)
  end

  def update_release(_url, body:)
    @store.attempt(:update)
    @store.updates << body
  end

  def get(url)
    @store.attempt(:get)
    @store.content_for(url) or raise Octokit::NotFound
  end
end

RSpec.describe ReleaseManager do
  around do |example|
    old = %w[GITHUB_TOKEN TEBAKO_VERSION EXPECTED_ENV_MATRIX EXPECTED_RUBY_MATRIX FORCE_REBUILD AUDIT_ONLY
             TEBAKO_PUBLISH_SETTLED_PATH].to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV["GITHUB_TOKEN"] = "test-token"
    ENV["TEBAKO_VERSION"] = SPEC_VERSION
    ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"macos-15","container":null,"os":"macos","arch":"arm64"}]'
    ENV["EXPECTED_RUBY_MATRIX"] = '["3.3.7"]'
    ENV.delete("FORCE_REBUILD")
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      # The settled-asset ledger (cross-invocation wedge memory) lives in
      # the per-example tmpdir: the default path is the process CWD, and a
      # spec writing it would pollute the repo checkout and leak
      # settlement between examples.
      ENV["TEBAKO_PUBLISH_SETTLED_PATH"] = @dir.join("settled-ledger").to_s
      example.run
    end
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  let(:manager) { described_class.new }

  def package(name, contents = name)
    @dir.join(name).tap do |path|
      path.write(contents)
      unless name.end_with?(".tfs", ".dll", ".abi", ReleaseManager::CONTRACT_SIDECAR_SUFFIX)
        write_contract_sidecar(path)
      end
    end
  end

  def write_contract_sidecar(path, contract = SPEC_CONTRACT)
    File.write("#{path.to_s.sub(/\.exe\z/, "")}#{ReleaseManager::CONTRACT_SIDECAR_SUFFIX}", YAML.dump(contract))
  end

  def with_packages(&block)
    Dir.chdir(@dir, &block)
  end

  # The 50–200 MB runtime assets have out-written the 60 s Faraday
  # default twice in one publish day (the v0.16.3 gnu/musl retries) —
  # the client must carry upload-sized timeouts.
  it "builds the Octokit client with upload-sized request timeouts" do
    captured = nil
    allow(Octokit::Client).to receive(:new) do |**kwargs|
      captured = kwargs
      FakeClient.new(FakeAssetStore.new)
    end

    described_class.new

    request = captured.fetch(:connection_options).fetch(:request)
    expect(request[:write_timeout]).to eq(600)
    expect(request[:open_timeout]).to eq(30)
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

  it "folds the sibling .dll into the windows package entry as an additive dll key (issue 40)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.tfs")
    dll = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.dll")

    entries = manager.build_manifest_entries([exe, img, dll])

    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry[:filename]).to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
    expect(entry[:dll]).to eq(
      filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.dll",
      install_as: "x64-ucrt-ruby330.dll",
      sha256: Digest::SHA256.file(dll).hexdigest,
      size_bytes: dll.size
    )
  end

  it "checksummes the windows ruby DLL after its package and image" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.tfs")
    dll = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.dll")
    entries = manager.build_manifest_entries([exe, img, dll])

    with_packages do
      sums = manager.generate_sha256sums(entries).read.lines.map(&:chomp)
      expect(sums).to eq(
        [
          "#{Digest::SHA256.file(exe).hexdigest}  #{exe.basename}",
          "#{Digest::SHA256.file(img).hexdigest}  #{img.basename}",
          "#{Digest::SHA256.file(dll).hexdigest}  #{dll.basename}"
        ]
      )
    end
  end

  it "warns when a windows package lacks its ruby DLL and when a DLL is orphaned" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
    orphan = package("tebako-runtime-#{SPEC_VERSION}-4.0.6-windows-ucrt64.dll")

    expect { manager.report_missing_packages([exe, orphan]) }
      .to output(/3\.3\.7-windows-ucrt64 has no ruby DLL.*4\.0\.6-windows-ucrt64\.dll has no matching runtime package/m)
      .to_stdout
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
      expect(packages.map(&:extname)).not_to include(".abi")
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
      store.assets << FakeAsset.new(3, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.dll")
      store.assets << FakeAsset.new(4, "SHA256SUMS.txt")
      store.assets << FakeAsset.new(5, "manifest.json")

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
    end

    it "fails loud when the windows ruby DLL is missing (issue 40)" do
      ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"windows-2022","container":null,"os":"windows","arch":"x86_64"}]'
      store.assets << FakeAsset.new(1, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.exe")
      store.assets << FakeAsset.new(2, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-ucrt64.tfs")
      store.assets << FakeAsset.new(3, "SHA256SUMS.txt")
      store.assets << FakeAsset.new(4, "manifest.json")

      expect { fake_manager.verify_completeness(release) }
        .to raise_error(/incomplete.*1 missing/)
        .and output(/Missing asset: tebako-runtime-#{SPEC_VERSION}-3\.3\.7-windows-ucrt64\.dll/).to_stdout
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

    # The v0.16.1 publish died on this: a POST timed out but landed
    # server-side; every retry then 422'd until the attempts ran out.
    # The content check short-circuits the first 422.
    it "treats a 422 as done when the timed-out attempt landed the same content" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, exe.read)
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to output(/already on the release with matching content/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
      expect(store.uploads).to be_empty
    end

    # The listing's digest is the authority: the download edge can serve
    # a deleted partial for hours — a matching digest accepts without a
    # byte read, and never deletes a good upload on a stale edge (the
    # v0.16.3 gnu publish looped exactly so).
    it "accepts a landed asset whose listing digest matches, even with a stale edge" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      asset = FakeAsset.new(7, exe.basename.to_s, url)
      asset.digest = "sha256:#{Digest::SHA256.hexdigest(exe.read)}"
      store.assets << asset
      store.set_content(url, "stale partial bytes")
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to output(/already on the release with matching content/).to_stdout
      expect(store.deletes).to be_empty
    end

    # The same 422 with DIFFERENT landed bytes is a partial (a timed-out
    # POST that landed incomplete) or a stale asset blocking the name:
    # delete it and land the retry — blind re-POSTs can never win (the
    # v0.16.3 publish exhausted its budget exactly here).
    it "deletes a 422's mismatched asset and lands the retry" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, "stale bytes")

      fake_manager.perform_upload(release, exe, exe.basename.to_s)

      expect(store.attempts[:upload]).to eq(2)
      expect(store.uploads).to eq([exe.basename.to_s])
      expect(store.deletes).to eq([7])
    end

    # A name wedged server-side (the replace cannot land within the
    # budget) keeps the previous asset AND its previous manifest entry —
    # byte-truthful, loudly warned, never a failed publish.
    it "keeps the previous asset and entry when the replace cannot land" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      previous = { filename: exe.basename.to_s, sha256: "1" * 64, platform: "macos-arm64" }
      store.delete_propagation = 999 # the delete never clears the listing
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, "previous bytes")
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      allow(fake_manager).to receive(:current_shas)
        .and_return(exe.basename.to_s => Digest::SHA256.hexdigest(exe.read))
      # The wait is wall-clock-bounded now: an advancing clock keeps a
      # never-propagating delete from spending real seconds per poll.
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }
      (ReleaseManager::UPLOAD_RETRY_DELAYS.size + 1).times { store.fail_next(:upload, Octokit::UnprocessableEntity.new) }

      expect { fake_manager.upload_package(release, exe) }
        .to output(/keeping the previous asset/).to_stdout
      expect(fake_manager.apply_stale_keeps([{ filename: exe.basename.to_s, sha256: "2" * 64 }]))
        .to eq([previous])
    end

    # A listed-but-unreadable landed asset (mid-propagation) proves
    # nothing — back off, never crash the publish on the read.
    it "treats an unreadable landed asset as not landed and keeps backing off" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s, "https://download.test/#{exe.basename}")
      (ReleaseManager::UPLOAD_RETRY_DELAYS.size + 1).times { store.fail_next(:upload, Octokit::UnprocessableEntity.new) }

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Octokit::UnprocessableEntity)
      expect(store.attempts[:upload]).to eq(ReleaseManager::UPLOAD_RETRY_DELAYS.size + 1)
    end

    # The v0.16.1 windows publish lost SHA256SUMS.txt to this: the delete's
    # re-upload 422'd four times inside ~20 s because the deletion had not
    # propagated. force_upload now polls for the absence first — exactly
    # one upload attempt, no 422 spent.
    it "force_upload waits out deletion propagation before re-uploading" do
      store.assets << FakeAsset.new(7, "SHA256SUMS.txt", "https://download.test/SHA256SUMS.txt")
      store.delete_propagation = 3
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("new sums") }

      fake_manager.force_upload(release, file)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq(["SHA256SUMS.txt"])
      expect(store.attempts[:upload]).to eq(1)
    end

    # Read-first: the served bytes already match → no mutation at all
    # (the delete-then-reupload pair is the API's most race-prone move).
    it "force_upload makes no mutation when the served metadata already matches" do
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("sums bytes") }
      store.set_content(
        "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/SHA256SUMS.txt",
        "sums bytes"
      )

      expect { fake_manager.force_upload(release, file) }.to output(/already current/).to_stdout
      expect(store.uploads).to be_empty
      expect(store.deletes).to be_empty
    end

    # The listing lags behind the edge: a landed asset can be unlisted yet
    # serving its bytes. The canonical URL fallback accepts it by content.
    it "accepts a landed duplicate via the canonical URL when the listing misses" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.set_content(
        "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/#{exe.basename}",
        exe.read
      )
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to output(/already on the release with matching content/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
    end

    # The 2026-08-03 night: a deleted name 422'd re-uploads for >25 min
    # while replicas disagreed. The convergence loop cycles read-first →
    # delete → upload → verify until the edge serves our bytes.
    it "converges the metadata across a flapping backend" do
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("fresh sums") }
      url = "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/SHA256SUMS.txt"
      store.assets << FakeAsset.new(7, "SHA256SUMS.txt", "https://download.test/SHA256SUMS.txt")
      store.set_content(url, "stale sums")
      store.fail_next(:upload, Octokit::UnprocessableEntity.new)

      expect { fake_manager.force_upload(release, file) }
        .to output(/already current on the release/).to_stdout
      expect(store.uploads).to eq(["SHA256SUMS.txt"])
    end

    # …but never forever: an unconvergeable name is a named failure.
    it "raises when the metadata never converges within the budget" do
      file = @dir.join("SHA256SUMS.txt").tap { |path| path.write("fresh sums") }
      store.set_content(
        "https://github.com/tamatebako/tebako-runtime-ruby/releases/download/v#{SPEC_VERSION}/SHA256SUMS.txt",
        "stale sums"
      )
      (4 * ReleaseManager::METADATA_CONVERGENCE_DELAYS.size).times do
        store.fail_next(:upload, Octokit::UnprocessableEntity.new)
      end

      expect { fake_manager.force_upload(release, file) }
        .to raise_error(/could not converge SHA256SUMS\.txt/)
    end

    # A canonical name wedged server-side (a deleted name 422ing
    # re-uploads for hours) must never block the publish: the
    # content-addressed twin uploads first and is the authority, the
    # canonical mirror demotes to a loud warning.
    it "publishes the content-addressed metadata when the canonical name is wedged" do
      entries = [{ filename: "pkg-a", sha256: "0" * 64 }]
      store.delete_propagation = 999 # the delete never clears the listing
      store.assets << FakeAsset.new(7, "SHA256SUMS.txt", "https://download.test/SHA256SUMS.txt")
      store.assets << FakeAsset.new(8, "manifest.json", "https://download.test/manifest.json")
      store.set_content("https://download.test/SHA256SUMS.txt", "stale sums")
      store.set_content("https://download.test/manifest.json", "stale manifest")
      # The wait is wall-clock-bounded now: an advancing clock keeps a
      # never-propagating delete from spending real seconds per poll.
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }

      expect { fake_manager.upload_metadata(release, entries) }
        .to output(/::warning::canonical SHA256SUMS\.txt could not be refreshed/).to_stdout
      expect(store.uploads).to include(a_string_matching(/SHA256SUMS-[0-9a-f]{8}\.txt/))
      expect(store.uploads).to include(a_string_matching(/manifest-[0-9a-f]{8}\.json/))
    end

    it "raises after the upload attempts are exhausted" do
      (ReleaseManager::UPLOAD_RETRY_DELAYS.size + 1).times { store.fail_next(:upload, Faraday::TimeoutError.new) }
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Faraday::TimeoutError)
      expect(store.attempts[:upload]).to eq(ReleaseManager::UPLOAD_RETRY_DELAYS.size + 1)
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

  # 2026-08-20 incident (run 32346716268, "Publish the runtime packages"):
  # one wedged exe/.tfs pair burned the full 150-minute step timeout, zero
  # of 338 assets updated. The three wounds, spec-locked: the
  # deletion-propagation wait is wall-clock-bounded and ends in a named
  # error (it sleeps between polls, never spins, never silently gives up);
  # a settled asset is never re-attempted within the run — the workspace
  # ledger carries the settlement across the per-platform invocations (no
  # exe<->tfs ping-pong); and the per-asset wall-clock cap bounds a
  # fully-wedged asset's effort.
  describe "wedged asset settlement (2026-08-20)" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    before { allow(fake_manager).to receive(:sleep) }

    it "sleeps between deletion-propagation polls until the asset leaves the listing" do
      store.assets << FakeAsset.new(7, "asset.tgz", "https://download.test/asset.tgz")
      store.delete_propagation = 2 # the listing clears on the third poll

      expect { fake_manager.remove_existing_asset(release, "asset.tgz") }
        .to output(/Waiting for the deletion of asset\.tgz to propagate/).to_stdout
      expect(fake_manager).to have_received(:sleep)
        .with(ReleaseManager::DELETION_PROPAGATION_POLL_INTERVAL).exactly(:twice)
    end

    it "times out with a named error when the deletion never propagates" do
      store.assets << FakeAsset.new(7, "asset.tgz", "https://download.test/asset.tgz")
      allow(fake_manager).to receive(:monotonic_now).and_return(0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 70.0)

      expect { fake_manager.wait_for_absence(release, "asset.tgz") }
        .to raise_error(DeletionPropagationTimeout, /deletion of asset\.tgz has not propagated within 60s/)
    end

    it "demotes the propagation timeout to a loud warning at the delete call sites" do
      store.assets << FakeAsset.new(7, "asset.tgz", "https://download.test/asset.tgz")
      store.delete_propagation = 999 # the delete never clears the listing
      allow(fake_manager).to receive(:monotonic_now).and_return(0.0, 70.0)

      expect { fake_manager.remove_existing_asset(release, "asset.tgz") }
        .to output(/::warning::the deletion of asset\.tgz has not propagated/).to_stdout
      expect(store.deletes).to eq([7])
    end

    # The incident's shape: the wedged exe warn-kept, then its own .tfs
    # re-entered the replace path — and the next platform invocation
    # re-attempted the exe. A settled asset is never attempted again in
    # the run, and its facets stand down with it.
    it "never re-attempts a settled asset and stands its .tfs facet down" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      tfs = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
      url = "https://download.test/#{exe.basename}"
      previous = { filename: exe.basename.to_s, sha256: "1" * 64, platform: "macos-arm64",
                   image: { filename: tfs.basename.to_s, sha256: "2" * 64, size_bytes: 1 } }
      store.delete_propagation = 999 # the delete never clears the listing
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, "previous bytes")
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      allow(fake_manager).to receive(:current_shas)
        .and_return(exe.basename.to_s => Digest::SHA256.hexdigest(exe.read))
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }

      expect { fake_manager.upload_package(release, exe) }
        .to output(/keeping the previous asset/).to_stdout
      expect(store.attempts[:upload]).to eq(1)

      expect { fake_manager.upload_package(release, exe) }
        .to output(/never re-attempted/).to_stdout
      expect { fake_manager.upload_package(release, tfs) }
        .to output(/never re-attempted/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
    end

    # The publish step runs one upload_release.rb process per platform;
    # the settlement must survive the process boundary or each invocation
    # re-burns the wedge (the incident's 3x 20-minute re-attempts).
    it "carries the settlement across the per-platform invocations via the workspace ledger" do
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-arm64")

      second = described_class.new(client: FakeClient.new(store))
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-arm64")

      expect { second.upload_package(release, exe) }
        .to output(/never re-attempted/).to_stdout
      expect(store.attempts[:upload]).to eq(0)
      expect(store.deletes).to be_empty
    end

    # The incident's kill shot: a wedged .tfs has no TOP-LEVEL manifest
    # entry (facets key under their package's entry), so the warn-keep
    # gate found "nothing to keep" and re-raised — exit 1, the platform
    # invocation dead, the pair re-attempted by the next one. The gate
    # now covers facets.
    it "warn-keeps a wedged .tfs facet instead of failing the publish" do
      tfs = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs")
      url = "https://download.test/#{tfs.basename}"
      store.delete_propagation = 999
      store.assets << FakeAsset.new(7, tfs.basename.to_s, url)
                    .tap { |asset| asset.digest = "sha256:#{"0" * 64}" }
      previous = { filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64", sha256: "1" * 64,
                   platform: "macos-arm64",
                   image: { filename: tfs.basename.to_s, sha256: "2" * 64, size_bytes: 1 } }
      allow(fake_manager).to receive(:previous_manifest_entries).and_return([previous])
      allow(fake_manager).to receive(:current_shas)
        .and_return(tfs.basename.to_s => Digest::SHA256.file(tfs).hexdigest)
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }

      expect { fake_manager.upload_package(release, tfs) }
        .to output(/keeping the previous asset/).to_stdout
      expect(fake_manager.settled?(tfs.basename.to_s)).to be(true)
    end

    # A LATER invocation builds fresh entries for the wedged platform;
    # without the ledger-driven revert the manifest would describe bytes
    # the release does not serve.
    it "reverts a settled package's fresh manifest entry in later invocations too" do
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      previous = { filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                   sha256: "1" * 64, platform: "macos-arm64" }
      fresh = { filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
                sha256: "9" * 64, platform: "macos-arm64" }

      second = described_class.new(client: FakeClient.new(store))
      allow(second).to receive(:previous_manifest_entries).and_return([previous])

      expect(second.apply_stale_keeps([fresh])).to eq([previous])
    end

    # A fully-wedged asset: every POST 422s, every delete never
    # propagates. The per-asset cap ends the effort inside the budget
    # instead of grinding the whole escalating delay series (the
    # incident's ~20 minutes per asset per invocation).
    it "bounds a fully-wedged asset by the per-asset wall-clock cap" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      url = "https://download.test/#{exe.basename}"
      store.delete_propagation = 999
      store.assets << FakeAsset.new(7, exe.basename.to_s, url)
      store.set_content(url, "previous bytes")
      clock = 0.0
      allow(fake_manager).to receive(:monotonic_now) { clock += 120.0 }

      expect { fake_manager.perform_upload(release, exe, exe.basename.to_s) }
        .to raise_error(Octokit::UnprocessableEntity)
        .and output(/per-asset upload budget \(300s\) is exhausted/).to_stdout
      expect(store.attempts[:upload]).to eq(1)
    end

    it "prints the end-of-step summary naming every kept package" do
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      fake_manager.settle_asset!("tebako-runtime-#{SPEC_VERSION}-3.1.6-linux-gnu-arm64.tfs")

      expect { fake_manager.print_settled_summary }
        .to output(/Publish summary: 2 package\(s\) kept their previous bytes.*3\.1\.6-linux-gnu-arm64.*3\.3\.7-macos-arm64/m)
        .to_stdout
    end

    it "stays silent when nothing wedged" do
      expect { fake_manager.print_settled_summary }.not_to output(/.+/).to_stdout
    end
  end

  # Raw rel gets are NOT auto-paginated (auto_paginate covers client
  # methods only): with 100+ assets, a first-page-only lookup silently
  # misses — then the publish re-uploads an existing asset, and a timeout
  # on that upload becomes the 422 cascade. all_assets walks the pages.
  describe "asset listing pagination" do
    let(:store) { FakeAssetStore.new }
    let(:release) { FakeRelease.new(store) }
    let(:fake_manager) { described_class.new(client: FakeClient.new(store)) }

    it "finds an asset that only exists past page one" do
      store.page_size = 30
      40.times { |i| store.assets << FakeAsset.new(i + 1, "asset-#{format("%02d", i)}") }
      store.assets << FakeAsset.new(99, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

      expect(fake_manager.find_asset(release, "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"))
        .not_to be_nil
    end

    it "skips re-uploading an existing asset that only exists past page one" do
      store.page_size = 30
      40.times { |i| store.assets << FakeAsset.new(i + 1, "asset-#{format("%02d", i)}") }
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(99, exe.basename.to_s)

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
      expect(store.uploads).to be_empty
    end

    it "verify_completeness sees assets past page one" do
      store.page_size = 30
      40.times { |i| store.assets << FakeAsset.new(i + 1, "asset-#{format("%02d", i)}") }
      ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64",
       "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.tfs",
       "SHA256SUMS.txt", "manifest.json"].each_with_index do |name, index|
        store.assets << FakeAsset.new(100 + index, name)
      end

      expect { fake_manager.verify_completeness(release) }.not_to raise_error
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

    it "re-uploads a listed asset whose upload never committed (state \"starter\")" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s, nil, nil, "starter")
      previous_manifest([previous_entry(exe.basename.to_s, "macos-arm64", Digest::SHA256.file(exe).hexdigest)])
      fake_manager.build_manifest_entries([exe])

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "re-uploads a listed asset with no previous manifest entry when the listing digest differs" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s).tap { |a| a.digest = "sha256:#{"0" * 64}" }
      fake_manager.build_manifest_entries([exe])

      fake_manager.upload_package(release, exe)

      expect(store.deletes).to eq([7])
      expect(store.uploads).to eq([exe.basename.to_s])
    end

    it "keeps a listed asset with no previous manifest entry when the listing digest matches" do
      exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
      store.assets << FakeAsset.new(7, exe.basename.to_s)
                               .tap { |a| a.digest = "sha256:#{Digest::SHA256.file(exe).hexdigest}" }
      fake_manager.build_manifest_entries([exe])

      expect(fake_manager.upload_package(release, exe)).to eq(exe.basename.to_s)
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
