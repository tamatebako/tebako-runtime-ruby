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
    expect(platform.fs_mount_point).to eq("/__tebako_memfs__")
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
    expect(platform.fs_mount_point).to eq("/__tebako_memfs__")
    expect(platform.b_env["CXXFLAGS"]).to include("-DTARGET_OS_SIMULATOR=0")
  end

  it "detects msys" do
    platform = described_class.new("x64-mingw-ucrt", "x86_64")
    expect(platform.msys?).to be(true)
    expect(platform.host_id).to eq("windows-x86_64")
    expect(platform.fs_mount_point).to eq("A:/__tebako_memfs__")
    expect(platform.exe_suffix).to eq(".exe")
    expect(platform.m_files).to eq("MinGW Makefiles")
    expect(platform.b_env["CXXFLAGS"]).to include("-DGFLAGS_IS_A_DLL=0")
  end

  it "maps aarch64 to arm64" do
    expect(described_class.new("aarch64-linux-gnu", "aarch64").host_id).to eq("linux-gnu-arm64")
  end

  it "rejects unsupported operating systems" do
    expect { described_class.new("x86_64-freebsd", "x86_64").host_id }
      .to raise_error(TebakoRuntimeBuilder::Error)
    expect { described_class.new("x86_64-freebsd", "x86_64").m_files }
      .to raise_error(TebakoRuntimeBuilder::Error)
  end
end
