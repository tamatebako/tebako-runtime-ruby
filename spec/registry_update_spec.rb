# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "tmpdir"
require "yaml"

require_relative "../tools/registry_update"

# Recording stand-ins in the sign_release_spec idiom: the renderer accepts
# any client object, and every interaction is observable through the fake.
RegistrySpecRelease = Struct.new(:url, :tag_name)
RegistrySpecAsset = Struct.new(:name, :browser_download_url)
RegistrySpecContents = Struct.new(:content)

# The Octokit stand-in: one release carrying shard assets whose bodies are
# canned JSON, and a contents-API registry source that is a static
# document, a proc (so a spec can read back what the last run wrote), or
# Octokit::NotFound (no registry on main yet).
class FakeRegistryClient
  def initialize(release:, shards:, registry: nil)
    @release = release
    @shards = shards
    @registry = registry
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def release_assets(url)
    url == @release.url ? @shards.map(&:first) : []
  end

  def get(url)
    @shards.to_h { |asset, body| [asset.browser_download_url, body] }.fetch(url)
  end

  def contents(_repo, **)
    source = @registry.respond_to?(:call) ? @registry.call : @registry
    raise Octokit::NotFound if source.nil?

    RegistrySpecContents.new(Base64.strict_encode64(source))
  end
end

RSpec.describe RegistryUpdate do
  let(:version) { "9.9.9" }
  let(:release) { RegistrySpecRelease.new("https://api.test/releases/1", "v#{version}") }

  def shard(ruby:, platform:, filename: nil, sha256: nil, tebako_version: version)
    suffix = platform.start_with?("windows") ? ".exe" : ""
    filename ||= "tebako-runtime-#{tebako_version}-#{ruby}-#{platform}#{suffix}"
    sha256 ||= Digest::SHA256.hexdigest("BYTES-#{filename}")
    body = JSON.generate("tebako_version" => tebako_version, "ruby_version" => ruby,
                         "platform" => platform, "filename" => filename, "sha256" => sha256)
    asset = RegistrySpecAsset.new("#{filename}.manifest.json", "https://download.test/#{filename}.manifest.json")
    @bodies[asset] = body
    asset
  end

  def render(shards, registry: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tpkg-registry.yaml")
      client = FakeRegistryClient.new(release: release, shards: shards, registry: registry)
      described_class.new(client: client,
                          env: { "TEBAKO_VERSION" => version, "REGISTRY_PATH" => path }).run
      yield path if block_given?
      return File.read(path)
    end
  end

  before { @bodies = {} }

  def shards_of(*list)
    list.map { |args| shard(**args) }.map { |asset| [asset, @bodies[asset]] }
  end

  it "derives the registry from the shards: composite versions, triplet rows, release ref" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" },
                       { ruby: "3.4.10", platform: "windows-ucrt64" },
                       { ruby: "3.3.12", platform: "macos-arm64" },
                       { ruby: "3.10.1", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards))

    expect(doc["schema_version"]).to eq(1)
    payload = doc["payloads"].find { |p| p["name"] == "ruby" }
    expect(payload["kind"]).to eq("runtime")
    expect(payload["engine"]).to eq("ruby")
    # Numeric sort, never lexical: 3.3.12 < 3.4.10 < 3.10.1.
    expect(payload["versions"].map { |v| v["version"] })
      .to eq(["3.3.12-9.9.9", "3.4.10-9.9.9", "3.10.1-9.9.9"])
    v344 = payload["versions"].find { |v| v["version"] == "3.4.10-9.9.9" }
    expect(v344["platforms"].keys).to eq(%w[aarch64-macos x86_64-windows-ucrt])
    expect(v344["platforms"]["aarch64-macos"])
      .to eq("artifact" => "tebako-runtime-9.9.9-3.4.10-macos-arm64",
             "sha256" => Digest::SHA256.hexdigest("BYTES-tebako-runtime-9.9.9-3.4.10-macos-arm64"))
    expect(v344["platforms"]["x86_64-windows-ucrt"]["artifact"])
      .to eq("tebako-runtime-9.9.9-3.4.10-windows-ucrt64.exe")
    expect(v344["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-ruby:v9.9.9")
    expect(payload["default"]).to eq("3.10.1-9.9.9")
  end

  it "upserts into an existing registry, preserving other payloads and withdrawn marks" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: metanorma
          kind: app
          versions:
            - version: '1.2.3'
              platforms: universal
              release: {ref: tfs:github:tebako-packages/metanorma:1.2.3}
        - name: ruby
          kind: runtime
          engine: ruby
          versions:
            - version: '3.3.12-9.9.8'
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.8-3.3.12-macos-arm64
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-ruby:v9.9.8}
          default: '3.3.12-9.9.8'
    YAML
    shards = shards_of({ ruby: "3.3.12", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("metanorma", "ruby")
    payload = doc["payloads"].find { |p| p["name"] == "ruby" }
    old = payload["versions"].find { |v| v["version"] == "3.3.12-9.9.8" }
    expect(old["status"]).to eq("withdrawn")
    expect(old["platforms"]).to have_key("aarch64-macos")
    new = payload["versions"].find { |v| v["version"] == "3.3.12-9.9.9" }
    expect(new["platforms"]).to eq("x86_64-linux-gnu" => {
                                     "artifact" => "tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64",
                                     "sha256" => Digest::SHA256.hexdigest(
                                       "BYTES-tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64"
                                     )
                                   })
    # The default moves off the withdrawn line onto the live one.
    expect(payload["default"]).to eq("3.3.12-9.9.9")
  end

  it "unions platform rows when a version already exists (new rows win per triplet)" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" })
    first = render(shards)
    more = shards_of({ ruby: "3.4.10", platform: "linux-musl-arm64" })
    doc = YAML.safe_load(render(more, registry: first))
    payload = doc["payloads"].find { |p| p["name"] == "ruby" }
    version_row = payload["versions"].find { |v| v["version"] == "3.4.10-9.9.9" }
    expect(version_row["platforms"].keys).to eq(%w[aarch64-linux-musl aarch64-macos])
  end

  it "is byte-idempotent: rendering over its own output changes nothing" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" },
                       { ruby: "3.3.12", platform: "windows-ucrt64" })
    first = render(shards)
    second = render(shards, registry: -> { first })
    expect(second).to eq(first)
  end

  it "carries the ownership header (never hand-edit except status: withdrawn)" do
    output = render(shards_of({ ruby: "3.4.10", platform: "macos-arm64" }))
    expect(output).to include("OWNED BY tools/registry_update.rb")
    expect(output).to include("status: withdrawn")
  end

  it "seeds the document when main carries no registry yet" do
    doc = YAML.safe_load(render(shards_of({ ruby: "3.4.10", platform: "macos-arm64" }), registry: nil))
    expect(doc["schema_version"]).to eq(1)
    expect(doc["payloads"].map { |p| p["name"] }).to eq(["ruby"])
  end

  it "drops the default loudly when every version is withdrawn" do
    # The withdrawn entry's own release re-renders (the composite version
    # key is unchanged), the merge preserves the mark, and no live line
    # remains for `default:` to name.
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: ruby
          kind: runtime
          engine: ruby
          versions:
            - version: '3.4.10-9.9.9'
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.9-3.4.10-macos-arm64
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-ruby:v9.9.9}
          default: '3.4.10-9.9.9'
    YAML
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" })
    output = nil
    expect do
      output = render(shards, registry: existing)
    end.to output(/no default/).to_stderr
    payload = YAML.safe_load(output)["payloads"].find { |p| p["name"] == "ruby" }
    expect(payload).not_to have_key("default")
    expect(payload["versions"].first["status"]).to eq("withdrawn")
  end

  it "fails named when an existing version carries `platforms: universal` (never both shapes)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: ruby
          kind: runtime
          engine: ruby
          versions:
            - version: '3.4.10-9.9.9'
              platforms: universal
              release: {ref: tfs:github:tamatebako/tebako-runtime-ruby:v9.9.9}
    YAML
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" })
    expect { render(shards, registry: existing) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /never both/)
  end

  it "fails named when a shard declares another tebako version" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64", tebako_version: "0.0.1" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /declares tebako_version "0.0.1"/)
  end

  it "fails named when a shard names an unknown platform" do
    shards = shards_of({ ruby: "3.4.10", platform: "plan9-arm64" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /unknown platform "plan9-arm64"/)
  end

  it "fails named when two shards claim the same triplet for one ruby" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64",
                         filename: "tebako-runtime-9.9.9-3.4.10-macos-arm64-a" },
                       { ruby: "3.4.10", platform: "macos-arm64",
                         filename: "tebako-runtime-9.9.9-3.4.10-macos-arm64-b" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /two shards claim aarch64-macos/)
  end

  it "fails named when the tag has no release" do
    client = FakeRegistryClient.new(release: release, shards: [])
    def client.release_for_tag(_repo, _tag)
      raise Octokit::NotFound
    end
    Dir.mktmpdir do |dir|
      updater = described_class.new(client: client,
                                    env: { "TEBAKO_VERSION" => version,
                                           "REGISTRY_PATH" => File.join(dir, "r.yaml") })
      expect { updater.run }
        .to raise_error(RegistryUpdate::RegistryUpdateError, /no release found for tag v9.9.9/)
    end
  end

  it "fails named when the release carries no shards" do
    expect { render([]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no \.manifest\.json shards/)
  end
end
