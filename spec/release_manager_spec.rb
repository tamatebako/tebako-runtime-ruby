# frozen_string_literal: true

require "spec_helper"
require "digest"
require "json"
require "pathname"

require_relative "../scripts/upload_release"

# Contract version the specs publish under (never a real release version)
SPEC_VERSION = "9.9.9"

# Recording octokit stand-ins: ReleaseManager accepts any client object
# (client:), and every publish interaction becomes observable through the
# store's public collections; transient failures are scriptable per call.
FakeAsset = Struct.new(:id, :name)

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

  def initialize(names = [])
    @assets = names.each_with_index.map { |name, index| FakeAsset.new(index + 1, name) }
    @uploads = []
    @deletes = []
    @updates = []
    @attempts = Hash.new(0)
    @upload_content_types = {}
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
end

RSpec.describe ReleaseManager do
  around do |example|
    old = %w[GITHUB_TOKEN TEBAKO_VERSION EXPECTED_ENV_MATRIX EXPECTED_RUBY_MATRIX FORCE_REBUILD]
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
    @dir.join(name).tap { |path| path.write(contents) }
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

    expect(entry.keys).to contain_exactly(:tebako_version, :ruby_version, :platform,
                                          :filename, :sha256, :size_bytes, :image)
    expect(entry[:tebako_version]).to eq(SPEC_VERSION)
    expect(entry[:sha256]).to eq(Digest::SHA256.file(exe).hexdigest)
    expect(entry[:size_bytes]).to eq(exe.size)
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
      store.assets << FakeAsset.new(1, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-x86_64.exe")
      store.assets << FakeAsset.new(2, "tebako-runtime-#{SPEC_VERSION}-3.3.7-windows-x86_64.tfs")
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

  describe "process_release completeness enforcement" do
    let(:store) { FakeAssetStore.new }
    let(:client) { FakeClient.new(store) }
    let(:fake_manager) { described_class.new(client: client) }

    def stage_packages(*names)
      dir = @dir.join("runtime-packages")
      dir.mkdir
      names.each { |name| dir.join(name).write("bytes-of-#{name}") }
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
  end
end
