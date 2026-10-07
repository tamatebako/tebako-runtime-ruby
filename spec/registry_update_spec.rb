# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "tmpdir"
require "yaml"

require_relative "../tools/registry_update"

# Recording stand-ins: the renderer accepts any client object, and every
# interaction is observable through the fake.
RegistrySpecRelease = Struct.new(:url, :tag_name)
RegistrySpecAsset = Struct.new(:name, :browser_download_url)
RegistrySpecContents = Struct.new(:content)

# The Octokit stand-in: one release carrying shard assets whose bodies are
# canned JSON, and a contents-API registry source that is a static
# document, a proc (so a spec can read back what the last run wrote), or
# Octokit::NotFound (no registry on main yet).
class FakeRegistryClient
  attr_reader :queried_tags

  def initialize(release:, shards:, registry: nil)
    @release = release
    @shards = shards
    @registry = registry
    @queried_tags = []
  end

  def release_for_tag(_repo, tag)
    @queried_tags << tag
    @release
  end

  def release_assets(url)
    url == @release.url ? @shards.map(&:first) : []
  end

  def get(url)
    body = @shards.to_h { |asset, body| [asset.browser_download_url, body] }.fetch(url)
    raise body if body.is_a?(Exception)

    body
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

  # One shard fixture: the .manifest.json asset plus the <name>.sha256
  # sidecar assets the verification pass (tebako#711 ask 3) checks every
  # rendered pin against — a fixture release must serve what its shards
  # pin. `sidecar`/`blksum_sidecar` modes: true serves the pin (the
  # default), a String serves that digest instead (a desync fixture),
  # false carries no sidecar asset at all, an Exception makes the fetch
  # raise (an unreadable sidecar).
  def shard(ruby:, platform:, filename: nil, sha256: nil, tebako_version: version, bundle: nil, blksum: nil, # rubocop:disable Metrics/ParameterLists
            per_file_assets: false, sidecar: true, blksum_sidecar: true)
    suffix = platform.start_with?("windows") ? ".exe" : ""
    filename ||= "tebako-runtime-#{tebako_version}-#{ruby}-#{platform}#{suffix}"
    sha256 ||= Digest::SHA256.hexdigest("BYTES-#{filename}")
    card = { "tebako_version" => tebako_version, "ruby_version" => ruby,
             "platform" => platform, "filename" => filename, "sha256" => sha256 }
    add_facets(card, filename, bundle, blksum, per_file_assets)
    [spec_asset("#{filename}.manifest.json", JSON.generate(card)),
     *shard_sidecars(filename, sha256, bundle, blksum, sidecar, blksum_sidecar)]
  end

  def shard_sidecars(filename, sha256, bundle, blksum, sidecar, blksum_sidecar) # rubocop:disable Metrics/ParameterLists
    artifact = bundle ? [bundle.fetch("filename"), bundle.fetch("sha256")] : [filename, sha256]
    pairs = sidecar_pair(artifact.first, artifact.last, sidecar)
    pairs.concat(sidecar_pair(blksum.fetch("filename"), blksum.fetch("sha256"), blksum_sidecar)) if blksum
    pairs
  end

  def spec_asset(name, body)
    [RegistrySpecAsset.new(name, "https://download.test/#{name}"), body]
  end

  def sidecar_pair(name, sha256, mode)
    return [] if mode == false

    body = mode
    body = "#{sha256}  #{name}\n" if mode == true
    body = "#{mode}  #{name}\n" if mode.is_a?(String)
    [spec_asset("#{name}.sha256", body)]
  end

  # The expected per-row release ref (tebako#711 ask 1): the tag THIS
  # render read the shards from — v<version>, or the TEBAKO_RELEASE_TAG
  # override when the catalog is sharded across tags.
  def row_ref(tag = "v#{version}")
    { "ref" => "tfs:github:tamatebako/tebako-runtime-ruby:#{tag}" }
  end

  def add_facets(card, filename, bundle, blksum, per_file_assets)
    card["bundle"] = bundle if bundle
    card["image"] = image_card(filename, blksum) if blksum
    card["per_file_assets"] = true if per_file_assets
  end

  def image_card(filename, blksum)
    image = "#{filename.sub(/\.exe\z/, "")}.tfs"
    { "filename" => image, "sha256" => Digest::SHA256.hexdigest("BYTES-#{image}"),
      "size_bytes" => 100, "blksum" => blksum }
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

  def shards_of(*list)
    list.flat_map { |args| shard(**args) }
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
    # spec 28 §8's flavor axis: an implementation-named edge sees only
    # entries carrying the same key — entry-level, never per version row.
    expect(payload["implementation"]).to eq("mri")
    # Numeric sort, never lexical: 3.3.12 < 3.4.10 < 3.10.1.
    expect(payload["versions"].map { |v| v["version"] })
      .to eq(["3.3.12-9.9.9", "3.4.10-9.9.9", "3.10.1-9.9.9"])
    v344 = payload["versions"].find { |v| v["version"] == "3.4.10-9.9.9" }
    expect(v344["platforms"].keys).to eq(%w[aarch64-macos x86_64-windows-ucrt])
    expect(v344["platforms"]["aarch64-macos"])
      .to eq("artifact" => "tebako-runtime-9.9.9-3.4.10-macos-arm64",
             "sha256" => Digest::SHA256.hexdigest("BYTES-tebako-runtime-9.9.9-3.4.10-macos-arm64"),
             "release" => row_ref)
    expect(v344["platforms"]["x86_64-windows-ucrt"]["artifact"])
      .to eq("tebako-runtime-9.9.9-3.4.10-windows-ucrt64.exe")
    expect(v344["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-ruby:v9.9.9")
    expect(payload["default"]).to eq("3.10.1-9.9.9")
  end

  # Spec 36 §5: a bundle-era shard's platform row names the BUNDLE (the
  # one payload asset the release serves) and pins its sha — the shard's
  # exe field stays a member pin, never the served artifact.
  it "renders the bundle as the platform artifact on bundle-era shards" do
    stem = "tebako-runtime-9.9.9-3.4.10-macos-arm64"
    bundle_sha = Digest::SHA256.hexdigest("BYTES-#{stem}.tar.gz")
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64",
                         bundle: { "filename" => "#{stem}.tar.gz", "sha256" => bundle_sha,
                                   "size_bytes" => 46_012_377 } })
    doc = YAML.safe_load(render(shards))

    row = doc["payloads"].find { |p| p["name"] == "ruby" }
                         .fetch("versions").find { |v| v["version"] == "3.4.10-9.9.9" }
                         .fetch("platforms").fetch("aarch64-macos")
    expect(row).to eq("artifact" => "#{stem}.tar.gz", "sha256" => bundle_sha, "release" => row_ref)
  end

  # Spec 39 §3 MINOR 4: the shard's `image.blksum` pin mirrors into the
  # platform row verbatim — the registry is the loader's resolution-level
  # source for the lazy arm's sidecar fetch.
  it "mirrors the shard's image.blksum pin into the platform row (per-file era)" do
    pin = { "filename" => "tebako-runtime-9.9.9-3.4.10-macos-arm64.tfs.blksum.json",
            "sha256" => "c" * 64 }
    doc = YAML.safe_load(render(shards_of({ ruby: "3.4.10", platform: "macos-arm64", blksum: pin })))

    row = doc["payloads"].find { |p| p["name"] == "ruby" }
                         .fetch("versions").find { |v| v["version"] == "3.4.10-9.9.9" }
                         .fetch("platforms").fetch("aarch64-macos")
    expect(row["blksum"]).to eq(pin)
  end

  it "mirrors the image.blksum pin on bundle-era rows too" do
    stem = "tebako-runtime-9.9.9-3.4.10-macos-arm64"
    pin = { "filename" => "#{stem}.tfs.blksum.json", "sha256" => "d" * 64 }
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64", blksum: pin,
                         bundle: { "filename" => "#{stem}.tar.gz", "sha256" => "b" * 64,
                                   "size_bytes" => 46_012_377 } })
    doc = YAML.safe_load(render(shards))

    row = doc["payloads"].find { |p| p["name"] == "ruby" }
                         .fetch("versions").find { |v| v["version"] == "3.4.10-9.9.9" }
                         .fetch("platforms").fetch("aarch64-macos")
    expect(row).to eq("artifact" => "#{stem}.tar.gz", "sha256" => "b" * 64, "blksum" => pin,
                      "release" => row_ref)
  end

  # Spec 36 §3's co-publish shape + §5's amendment: a co-published
  # bundle-era shard (bundle + the "per_file_assets" witness + the
  # image.blksum pin) renders the SAME platform row — the bundle stays
  # the artifact, the blksum pin mirrors, and the witness itself is NOT
  # mirrored (the registry grammar is unchanged: the row already
  # co-expresses everything the lazy arm resolves).
  it "renders a co-published bundle-era shard identically (the witness is not mirrored)" do
    stem = "tebako-runtime-9.9.9-3.4.10-macos-arm64"
    pin = { "filename" => "#{stem}.tfs.blksum.json", "sha256" => "e" * 64 }
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64", blksum: pin,
                         per_file_assets: true,
                         bundle: { "filename" => "#{stem}.tar.gz", "sha256" => "f" * 64,
                                   "size_bytes" => 46_012_377 } })
    doc = YAML.safe_load(render(shards))

    row = doc["payloads"].find { |p| p["name"] == "ruby" }
                         .fetch("versions").find { |v| v["version"] == "3.4.10-9.9.9" }
                         .fetch("platforms").fetch("aarch64-macos")
    expect(row).to eq("artifact" => "#{stem}.tar.gz", "sha256" => "f" * 64, "blksum" => pin,
                      "release" => row_ref)
  end

  it "renders no blksum key for a pre-blksum shard (the additive-key compat rule)" do
    doc = YAML.safe_load(render(shards_of({ ruby: "3.4.10", platform: "macos-arm64" })))

    row = doc["payloads"].find { |p| p["name"] == "ruby" }
                         .fetch("versions").find { |v| v["version"] == "3.4.10-9.9.9" }
                         .fetch("platforms").fetch("aarch64-macos")
    expect(row).not_to have_key("blksum")
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
                                     ),
                                     "release" => row_ref
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

  it "upserts implementation onto an implementation-less ruby entry (the spec 28 §8 backfill, never a hand-edit)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: ruby
          kind: runtime
          engine: ruby
          versions:
            - version: '3.4.10-9.9.8'
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.8-3.4.10-macos-arm64
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-ruby:v9.9.8}
          default: '3.4.10-9.9.8'
    YAML
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    payload = doc["payloads"].find { |p| p["name"] == "ruby" }
    expect(payload["implementation"]).to eq("mri")
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

  it "queries the TEBAKO_RELEASE_TAG release when the override is set" do
    Dir.mktmpdir do |dir|
      shards = shards_of({ ruby: "3.4.10", platform: "linux-gnu-x86_64" })
      client = FakeRegistryClient.new(release: release, shards: shards)
      described_class.new(client: client,
                          env: { "TEBAKO_VERSION" => version,
                                 "TEBAKO_RELEASE_TAG" => "v#{version}-ruby9.9",
                                 "REGISTRY_PATH" => File.join(dir, "r.yaml") }).run
      expect(client.queried_tags).to eq(["v#{version}-ruby9.9"])
    end
  end

  # tebako#711 ask 1: every platform row names the shard tag it was
  # rendered from in its own release.ref — post-tebako-runtime-ruby#235 a
  # version line unions rows from several per-platform shard tags, which
  # the version-level ref cannot name. The key is additive (spec 37 §2's
  # leniency rule: pre-MINOR readers ignore it).
  it "names the render's tag in every platform row's own release.ref" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64" },
                       { ruby: "3.4.10", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards))

    platforms = doc["payloads"].find { |p| p["name"] == "ruby" }
                               .fetch("versions").first.fetch("platforms")
    expect(platforms.values).to all(include("release" => row_ref))
  end

  it "names the TEBAKO_RELEASE_TAG override tag in the rows' release.ref when set" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.yaml")
      shards = shards_of({ ruby: "3.4.10", platform: "linux-gnu-x86_64" })
      client = FakeRegistryClient.new(release: release, shards: shards)
      described_class.new(client: client,
                          env: { "TEBAKO_VERSION" => version,
                                 "TEBAKO_RELEASE_TAG" => "v#{version}-ruby9.9",
                                 "REGISTRY_PATH" => path }).run
      version_row = YAML.safe_load_file(path)["payloads"].first.fetch("versions").first
      expect(version_row["release"]).to eq(row_ref("v#{version}-ruby9.9"))
      expect(version_row["platforms"].values).to all(include("release" => row_ref("v#{version}-ruby9.9")))
    end
  end

  # tebako#711 ask 3: before anything merges, every rendered pin is
  # verified against the bytes its tag actually serves (the <name>.sha256
  # sidecars) — a desynced release can never become a published registry
  # row, and one refusal names EVERY desynced row.
  it "fails named, listing every desynced row, when the tag serves bytes other than the pins" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64", sidecar: "0" * 64 },
                       { ruby: "3.3.12", platform: "linux-gnu-x86_64", sidecar: "1" * 64 })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError) do |e|
        expect(e.message).to include("desync")
        expect(e.message).to include("3.4.10-9.9.9 aarch64-macos: tebako-runtime-9.9.9-3.4.10-macos-arm64 pins")
        expect(e.message).to include("but v9.9.9 serves #{"0" * 64}")
        expect(e.message).to include("3.3.12-9.9.9 x86_64-linux-gnu: tebako-runtime-9.9.9-3.3.12-linux-gnu-x86_64 pins")
        expect(e.message).to include("but v9.9.9 serves #{"1" * 64}")
      end
  end

  it "fails named when a rendered artifact has no .sha256 sidecar on the tag" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64", sidecar: false })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError,
                      /no tebako-runtime-9\.9\.9-3\.4\.10-macos-arm64\.sha256 asset on v9\.9\.9/)
  end

  it "fails named when a sidecar is unreadable (the fetch error folds into the desync line)" do
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64",
                         sidecar: StandardError.new("boom") })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /unreadable on v9\.9\.9 \(StandardError: boom\)/)
  end

  it "verifies the blksum pin against its own sidecar" do
    pin = { "filename" => "tebako-runtime-9.9.9-3.4.10-macos-arm64.tfs.blksum.json",
            "sha256" => "c" * 64 }
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64", blksum: pin,
                         blksum_sidecar: "9" * 64 })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError,
                      /blksum\.json pins c{64} but v9\.9\.9 serves 9{64}/)
  end

  it "verifies bundle-era rows against the bundle's sidecar" do
    stem = "tebako-runtime-9.9.9-3.4.10-macos-arm64"
    shards = shards_of({ ruby: "3.4.10", platform: "macos-arm64",
                         bundle: { "filename" => "#{stem}.tar.gz", "sha256" => "b" * 64,
                                   "size_bytes" => 46_012_377 },
                         sidecar: "2" * 64 })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /#{stem}\.tar\.gz pins b{64} but/)
  end

  it "fails named when the release carries no shards" do
    expect { render([]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no \.manifest\.json shards/)
  end
end
