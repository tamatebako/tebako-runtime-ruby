# frozen_string_literal: true

require "spec_helper"
require "digest"
require "json"
require "pathname"

require_relative "../scripts/upload_release"

# Contract version the specs publish under (never a real release version)
SPEC_VERSION = "9.9.9"

RSpec.describe ReleaseManager do
  around do |example|
    old = %w[GITHUB_TOKEN TEBAKO_VERSION EXPECTED_ENV_MATRIX EXPECTED_RUBY_MATRIX]
          .to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV["GITHUB_TOKEN"] = "test-token"
    ENV["TEBAKO_VERSION"] = SPEC_VERSION
    ENV["EXPECTED_ENV_MATRIX"] = '[{"host":"macos-15","container":null,"os":"macos","arch":"arm64"}]'
    ENV["EXPECTED_RUBY_MATRIX"] = '["3.3.7"]'
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

  it "folds the sibling .dwarfs into the package entry as an additive image key" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs")

    entries = manager.build_manifest_entries([exe, img])

    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry[:filename]).to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    expect(entry[:ruby_version]).to eq("3.3.7")
    expect(entry[:platform]).to eq("macos-arm64")
    expect(entry[:image]).to eq(
      filename: "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs",
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
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs")

    entry = manager.build_manifest_entries([exe, img]).first

    expect(entry.keys).to contain_exactly(:tebako_version, :ruby_version, :platform,
                                          :filename, :sha256, :size_bytes, :image)
    expect(entry[:tebako_version]).to eq(SPEC_VERSION)
    expect(entry[:sha256]).to eq(Digest::SHA256.file(exe).hexdigest)
    expect(entry[:size_bytes]).to eq(exe.size)
  end

  it "checksummes both the package and its image, image line following its package" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs")
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
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs",
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64",
      "tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64.dwarfs"
    ]

    executables = manager.categorize_packages(files)
    images = manager.categorize_images(files)

    expect(executables["macos"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"])
    expect(executables["linux-gnu"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64"])
    expect(images["macos"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs"])
    expect(images["linux-gnu"]).to eq(["tebako-runtime-#{SPEC_VERSION}-3.3.7-linux-gnu-x86_64.dwarfs"])
    expect(images["linux-musl"]).to be_empty
  end

  it "lists image sections in the release notes after the executables" do
    sections = manager.initialize_sections
    sections["macos"] = ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64"]
    images = manager.initialize_sections
    images["macos"] = ["tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs"]

    notes = manager.generate_release_notes(sections, images)

    expect(notes).to include("### macOS executables\n- tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64\n")
    expect(notes).to include("### macOS filesystem images\n- tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs\n")
  end

  it "warns when a package lacks its image" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")

    expect { manager.report_missing_packages([exe]) }
      .to output(/has no filesystem image \(tebako-runtime-#{SPEC_VERSION}-3\.3\.7-macos-arm64\.dwarfs\)/)
      .to_stdout
  end

  it "warns when an image is orphaned (no matching package)" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs")
    orphan = package("tebako-runtime-#{SPEC_VERSION}-4.0.6-linux-musl-arm64.dwarfs")

    expect { manager.report_missing_packages([exe, img, orphan]) }
      .to output(/4\.0\.6-linux-musl-arm64\.dwarfs has no matching runtime package/)
      .to_stdout
  end

  it "still warns about missing expected packages" do
    expect { manager.report_missing_packages([]) }
      .to output(/Missing runtime package: tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64/).to_stdout
  end

  it "writes the manifest.json asset with the image entries" do
    exe = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64")
    img = package("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs")
    entries = manager.build_manifest_entries([exe, img])

    with_packages do
      manifest = JSON.parse(manager.generate_manifest(entries).read)
      expect(manifest.size).to eq(1)
      expect(manifest.first["image"]["filename"])
        .to eq("tebako-runtime-#{SPEC_VERSION}-3.3.7-macos-arm64.dwarfs")
      expect(manifest.first["image"]["sha256"]).to eq(Digest::SHA256.file(img).hexdigest)
      expect(manifest.first["image"]["size_bytes"]).to eq(img.size)
    end
  end
end
