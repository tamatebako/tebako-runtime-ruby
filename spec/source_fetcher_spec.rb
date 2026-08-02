# frozen_string_literal: true

require "spec_helper"
require "digest"
require "fileutils"

RSpec.describe TebakoRuntimeBuilder::SourceFetcher do
  let(:mirror_dir) { Dir.mktmpdir }
  let(:cache_dir) { Dir.mktmpdir }
  let(:tarball_content) { "fake-patched-ruby-source-tarball" }
  let(:sha256) { Digest::SHA256.hexdigest(tarball_content) }

  let(:fetcher) do
    described_class.new(mirror: "file://#{mirror_dir}", cache_dir: cache_dir)
  end

  before do
    File.binwrite(File.join(mirror_dir, "tfs-ruby-3.3.7-src.tar.gz"), tarball_content)
    File.write(File.join(mirror_dir, "SHA256SUMS"),
               "#{sha256}  tfs-ruby-3.3.7-src.tar.gz\n" \
               "#{Digest::SHA256.hexdigest("other")}  tfs-ruby-3.4.2-src.tar.gz\n")
  end

  after do
    FileUtils.remove_entry(mirror_dir)
    FileUtils.remove_entry(cache_dir)
  end

  it "downloads and verifies the asset named in SHA256SUMS" do
    path, sum = fetcher.fetch("3.3.7")
    expect(sum).to eq(sha256)
    expect(File.binread(path)).to eq(tarball_content)
  end

  it "serves a verified cached download without re-reading the mirror" do
    fetcher.fetch("3.3.7")
    FileUtils.rm(File.join(mirror_dir, "tfs-ruby-3.3.7-src.tar.gz"))
    path, = fetcher.fetch("3.3.7")
    expect(File.binread(path)).to eq(tarball_content)
  end

  it "raises and deletes the download on a checksum mismatch" do
    File.write(File.join(mirror_dir, "SHA256SUMS"),
               "#{"0" * 64}  tfs-ruby-3.3.7-src.tar.gz\n")
    FileUtils.rm_rf(File.join(cache_dir, described_class::DEFAULT_RELEASE))
    expect { fetcher.fetch("3.3.7") }.to raise_error(TebakoRuntimeBuilder::Error, /expected SHA256/)
    expect(Dir.glob(File.join(cache_dir, "**", "tfs-ruby-3.3.7-src.tar.gz"))).to be_empty
  end

  it "raises when the asset is not in SHA256SUMS" do
    expect { fetcher.fetch("3.2.7") }.to raise_error(TebakoRuntimeBuilder::Error, /not found in the SHA256SUMS/)
  end

  it "raises when the mirror asset is missing" do
    FileUtils.rm(File.join(mirror_dir, "tfs-ruby-3.3.7-src.tar.gz"))
    expect { fetcher.fetch("3.3.7") }.to raise_error(TebakoRuntimeBuilder::Error, /not found/)
  end

  it "names assets per the tamatebako/ruby release contract" do
    expect(fetcher.asset_name("4.0.6")).to eq("tfs-ruby-4.0.6-src.tar.gz")
  end

  describe "#tarball_sha256" do
    it "reads the version's own sum from the release's SHA256SUMS" do
      expect(fetcher.tarball_sha256("3.3.7")).to eq(sha256)
    end

    it "raises, naming the asset and release, when the version is not published" do
      expect { fetcher.tarball_sha256("3.2.7") }
        .to raise_error(TebakoRuntimeBuilder::Error, /tfs-ruby-3\.2\.7-src\.tar\.gz not found in the SHA256SUMS/)
    end
  end

  describe ".scenario_asset_names" do
    it "resolves the unsuffixed linux-gnu scenario for gnu and macos" do
      expect(described_class.scenario_asset_names("3.3.7",
                                                  TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu", "x86_64")))
        .to eq(["tfs-ruby-3.3.7-src.tar.gz"])
      expect(described_class.scenario_asset_names("3.3.7",
                                                  TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64")))
        .to eq(["tfs-ruby-3.3.7-src.tar.gz"])
    end

    it "resolves the musl scenario for linux-musl" do
      expect(described_class.scenario_asset_names("3.3.7",
                                                  TebakoRuntimeBuilder::Platform.new("x86_64-linux-musl", "x86_64")))
        .to eq(["tfs-ruby-3.3.7-src-linux-musl.tar.gz"])
    end

    it "resolves the two-pass msys scenario for msys/mingw" do
      expect(described_class.scenario_asset_names("3.3.7",
                                                  TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64")))
        .to eq(["tfs-ruby-3.3.7-src-msys-pass1.tar.gz", "tfs-ruby-3.3.7-src-msys-pass2.tar.gz"])
    end
  end

  describe "#fetch_assets" do
    before do
      %w[tfs-ruby-3.3.7-src-linux-musl.tar.gz tfs-ruby-3.3.7-src-msys-pass1.tar.gz
         tfs-ruby-3.3.7-src-msys-pass2.tar.gz].each do |name|
        File.binwrite(File.join(mirror_dir, name), "content-of-#{name}")
      end
      File.write(File.join(mirror_dir, "SHA256SUMS"),
                 ["#{sha256}  tfs-ruby-3.3.7-src.tar.gz",
                  "#{Digest::SHA256.hexdigest("content-of-tfs-ruby-3.3.7-src-linux-musl.tar.gz")}  " \
                  "tfs-ruby-3.3.7-src-linux-musl.tar.gz",
                  "#{Digest::SHA256.hexdigest("content-of-tfs-ruby-3.3.7-src-msys-pass1.tar.gz")}  " \
                  "tfs-ruby-3.3.7-src-msys-pass1.tar.gz",
                  "#{Digest::SHA256.hexdigest("content-of-tfs-ruby-3.3.7-src-msys-pass2.tar.gz")}  " \
                  "tfs-ruby-3.3.7-src-msys-pass2.tar.gz"].join("\n") << "\n")
    end

    it "fetches the single musl scenario asset, verified" do
      platform = TebakoRuntimeBuilder::Platform.new("x86_64-linux-musl", "x86_64")
      assets = fetcher.fetch_assets("3.3.7", platform)
      expect(assets.length).to eq(1)
      path, sum = assets[0]
      expect(sum).to eq(Digest::SHA256.hexdigest("content-of-tfs-ruby-3.3.7-src-linux-musl.tar.gz"))
      expect(File.binread(path)).to eq("content-of-tfs-ruby-3.3.7-src-linux-musl.tar.gz")
    end

    it "fetches both msys pass trees in order, each verified" do
      platform = TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64")
      assets = fetcher.fetch_assets("3.3.7", platform)
      expect(assets.length).to eq(2)
      expect(assets.map { |path,| File.basename(path) })
        .to eq(["tfs-ruby-3.3.7-src-msys-pass1.tar.gz", "tfs-ruby-3.3.7-src-msys-pass2.tar.gz"])
      expect(File.binread(assets[0][0])).to eq("content-of-tfs-ruby-3.3.7-src-msys-pass1.tar.gz")
      expect(File.binread(assets[1][0])).to eq("content-of-tfs-ruby-3.3.7-src-msys-pass2.tar.gz")
    end

    it "fetches the unsuffixed asset for gnu" do
      platform = TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu", "x86_64")
      path, sum = fetcher.fetch_assets("3.3.7", platform)[0]
      expect(sum).to eq(sha256)
      expect(File.binread(path)).to eq(tarball_content)
    end
  end
end
