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

  it "names the reserved windows-ucrt-arm64 host id for the arm64 windows host" do
    arm64 = described_class.new("aarch64-mingw-ucrt", "aarch64")
    expect(arm64.msys?).to be(true)
    expect(arm64.host_id).to eq("windows-ucrt-arm64")
    expect(arm64.tpkg_triplet).to eq("aarch64-windows-ucrt")
    expect(arm64.fs_mount_point).to eq("A:/t")
    expect(arm64.exe_suffix).to eq(".exe")
  end

  it "names the msys2 environment per arch: ucrt64 on x86_64, clangarm64 on arm64" do
    expect(described_class.new("x64-mingw-ucrt", "x86_64").msys_env).to eq("ucrt64")
    expect(described_class.new("aarch64-mingw-ucrt", "aarch64").msys_env).to eq("clangarm64")
  end

  it "fails named (112) asking the msys environment of a POSIX host" do
    expect { described_class.new("x86_64-pc-linux-gnu", "x86_64").msys_env }
      .to raise_error(TebakoRuntimeBuilder::Error) { |e| expect(e.error_code).to eq(112) }
  end

  it "maps every platform to the product's link-unit platform ids" do
    expectations = {
      %w[linux-gnu x86_64] => "linux-gnu-x86_64",
      %w[linux-gnu arm64] => "linux-gnu-arm64",
      %w[linux-musl x86_64] => "linux-musl-x86_64",
      %w[linux-musl arm64] => "linux-musl-arm64",
      %w[macos x86_64] => "macos-x86_64",
      %w[macos arm64] => "macos-arm64",
      %w[windows x86_64] => "x86_64-windows-gnu",
      %w[windows arm64] => "aarch64-windows-gnu"
    }
    expectations.each do |(os, arch), pid|
      expect(described_class.link_unit_pid_for(os, arch)).to eq(pid)
    end
  end

  it "fails named (112) outside the link-unit pid vocabulary" do
    expect { described_class.link_unit_pid_for("sunos", "sparc") }
      .to raise_error(TebakoRuntimeBuilder::Error) { |e| expect(e.error_code).to eq(112) }
  end

  it "names the spec 03 §3 vcpkg triplet for every host_id" do
    {
      %w[x64-mingw-ucrt x86_64] => "x86_64-windows-ucrt",
      %w[aarch64-mingw-ucrt aarch64] => "aarch64-windows-ucrt",
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
