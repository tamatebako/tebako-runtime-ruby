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
end
