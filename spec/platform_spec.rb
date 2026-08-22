# frozen_string_literal: true

require "spec_helper"

RSpec.describe TebakoRuntimeBuilder::Platform do
  it "detects linux-gnu" do
    platform = described_class.new("x86_64-linux-gnu", "x86_64")
    expect(platform.linux?).to be(true)
    expect(platform.linux_gnu?).to be(true)
    expect(platform.linux_musl?).to be(false)
    expect(platform.macos?).to be(false)
    expect(platform.msys?).to be(false)
    expect(platform.host_id).to eq("linux-gnu-x86_64")
    expect(platform.fs_mount_point).to eq("/__tfs__")
    expect(platform.exe_suffix).to eq("")
    expect(platform.m_files).to eq("Unix Makefiles")
  end

  it "detects linux-musl" do
    platform = described_class.new("x86_64-linux-musl", "x86_64")
    expect(platform.linux?).to be(true)
    expect(platform.linux_gnu?).to be(false)
    expect(platform.musl?).to be(true)
    expect(platform.host_id).to eq("linux-musl-x86_64")
  end

  it "detects macos" do
    platform = described_class.new("arm64-darwin23", "arm64")
    expect(platform.macos?).to be(true)
    expect(platform.musl?).to be(false)
    expect(platform.host_id).to eq("macos-arm64")
    expect(platform.fs_mount_point).to eq("/__tfs__")
    expect(platform.b_env["CXXFLAGS"]).to include("-DTARGET_OS_SIMULATOR=0")
  end

  it "detects msys" do
    platform = described_class.new("x64-mingw-ucrt", "x86_64")
    expect(platform.msys?).to be(true)
    expect(platform.host_id).to eq("windows-ucrt64")
    expect(platform.fs_mount_point).to eq("A:/t")
    expect(platform.exe_suffix).to eq(".exe")
    expect(platform.m_files).to eq("MinGW Makefiles")
    expect(platform.b_env["CXXFLAGS"]).to include("-DGFLAGS_IS_A_DLL=0")
  end

  it "maps aarch64 to arm64" do
    expect(described_class.new("aarch64-linux-gnu", "aarch64").host_id).to eq("linux-gnu-arm64")
  end

  it "names the spec 03 §3 vcpkg triplet for every host_id" do
    {
      %w[x64-mingw-ucrt x86_64] => "x86_64-windows-ucrt",
      %w[arm64-darwin23 arm64] => "aarch64-macos",
      %w[x86_64-darwin23 x86_64] => "x86_64-macos",
      %w[x86_64-linux-gnu x86_64] => "x86_64-linux-gnu",
      %w[aarch64-linux-gnu aarch64] => "aarch64-linux-gnu",
      %w[x86_64-linux-musl x86_64] => "x86_64-linux-musl",
      %w[aarch64-linux-musl aarch64] => "aarch64-linux-musl"
    }.each do |(ostype, arch), triplet|
      expect(described_class.new(ostype, arch).tpkg_triplet).to eq(triplet)
    end
  end

  it "keeps the triplet mirror total over the host_id axis" do
    # tpkg::Platform (tamatebako/tebako) owns the triplet ↔ release-asset
    # mapping; TPKG_TRIPLETS mirrors it — every host_id must map, and the
    # reverse of every entry must be the host_id itself.
    expect(described_class::TPKG_TRIPLETS.keys).to match_array(described_class::HOST_IDS.values)
  end

  it "rejects unsupported operating systems" do
    expect { described_class.new("x86_64-freebsd", "x86_64").host_id }
      .to raise_error(TebakoRuntimeBuilder::Error)
    expect { described_class.new("x86_64-freebsd", "x86_64").m_files }
      .to raise_error(TebakoRuntimeBuilder::Error)
  end
end
