# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "open3"
require "rbconfig"

module TebakoRuntimeBuilder
  # Packaging host platform (gem Tebako::ScenarioManagerBase plus the
  # OptionsManager host_platform id used by runtime package names)
  class Platform # rubocop:disable Metrics/ClassLength
    def initialize(ostype = RUBY_PLATFORM, arch = RbConfig::CONFIG["host_cpu"])
      @ostype = ostype
      @arch = arch
      @linux = @ostype =~ /linux/ ? true : false
      @musl = @ostype =~ /linux-musl/ ? true : false
      @macos = @ostype =~ /darwin/ ? true : false
      @msys  = @ostype =~ /msys|mingw|cygwin/ ? true : false

      # The mount-root CONVENTION (tamatebako/ruby's patch literals are
      # the owner — keep these equal to them). Builds never fall back to
      # it: the value flows from the tarball's tebako-mount-root manifest
      # (MountRoot, exit 132 when absent). What reads the convention is
      # the host-side expectation of a built exe's compiled-in root (the
      # boot smoke) and the CMake default for bare invocations.
      @fs_mount_point = @msys ? "A:/t" : "/__tfs__"
      @exe_suffix = @msys ? ".exe" : ""
    end

    attr_reader :ostype, :fs_mount_point, :exe_suffix

    # Build environment for the CMake configure/build invocations
    def b_env
      u_flags = if @macos
                  "-DTARGET_OS_SIMULATOR=0 -DTARGET_OS_IPHONE=0  #{ENV.fetch("CXXFLAGS", nil)}"
                elsif @msys
                  "-DGFLAGS_IS_A_DLL=0   #{ENV.fetch("CXXFLAGS", nil)}"
                else
                  ENV.fetch("CXXFLAGS", nil)
                end
      { "CXXFLAGS" => u_flags }
    end

    def linux?
      @linux
    end

    def linux_gnu?
      @linux && !@musl
    end

    def linux_musl?
      @linux && @musl
    end

    def m_files
      @m_files ||= if @linux || @macos
                     "Unix Makefiles"
                   elsif @msys
                     "MinGW Makefiles"
                   else
                     raise TebakoRuntimeBuilder::Error.new("#{@ostype} is not supported.", 112)
                   end
    end

    def macos?
      @macos
    end

    def msys?
      @msys
    end

    # The msys2 environment this mingw host builds in: the pacman package
    # namespace (pactoys' pacboy resolves `:p` against it —
    # mingw-w64-<ucrt-x86_64|clang-aarch64>-*) and the msys2 toolchain root
    # the openssl/zlib dev packages install under. x86_64 pairs ucrt64 (the
    # proven gcc shape); arm64 pairs clangarm64 (the llvm toolchain — the
    # only aarch64-w64-mingw32 environment, and the one MSYS2 itself builds
    # its aarch64 ruby in). Non-msys hosts raise: there is no environment
    # to name.
    def msys_env
      raise TebakoRuntimeBuilder::Error.new("#{@ostype} is not a mingw host — no msys2 environment", 112) unless @msys

      host_arch_id == "arm64" ? "clangarm64" : "ucrt64"
    end

    # Exactly x86_64 (never aarch64/arm64): the 3.1 line's YJIT arms on
    # this arch only — the boot smoke's derivation keys on it.
    def x86_64?
      @arch == "x86_64"
    end

    def musl?
      @musl
    end

    def ncores
      if @ncores.nil?
        if @macos
          out, st = Open3.capture2e("sysctl", "-n", "hw.ncpu")
        else
          out, st = Open3.capture2e("nproc", "--all")
        end

        @ncores = !st.signaled? && st.exitstatus.zero? ? out.strip.to_i : 4
      end
      @ncores
    end

    # (os id, arch id) → release platform id. Owned by tpkg::Platform
    # (tebako-rs, docs/spec/03 §3); NOT derivable by formula
    # ("windows-ucrt64" carries no arch segment). windows/arm64 follows
    # the product's RESERVED release-asset name ("windows-ucrt-arm64" —
    # the aarch64-windows-ucrt triplet, which tpkg parses but rejects in
    # payload manifests until the platform ships); this factory's leg is
    # publish-gated OFF until the product un-reserves it.
    HOST_IDS = {
      %w[windows x86_64] => "windows-ucrt64",
      %w[windows arm64] => "windows-ucrt-arm64",
      %w[macos arm64] => "macos-arm64",
      %w[macos x86_64] => "macos-x86_64",
      %w[linux-gnu x86_64] => "linux-gnu-x86_64",
      %w[linux-gnu arm64] => "linux-gnu-arm64",
      %w[linux-musl x86_64] => "linux-musl-x86_64",
      %w[linux-musl arm64] => "linux-musl-arm64"
    }.freeze

    # The lookup for callers with no detected host (the release pipeline's
    # expected-asset model); same named failure as the instance path.
    def self.host_id_for(os_id, arch_id)
      HOST_IDS.fetch([os_id, arch_id]) { raise TebakoRuntimeBuilder::Error.new("#{os_id}/#{arch_id}", 112) }
    end

    # (os id, arch id) → the tamatebako/tebako release's link-unit platform
    # id (the product release.yml's matrix.platform; differs from HOST_IDS
    # on windows). The single owner of the mapping for BOTH the CI leg
    # planner's artifact gate (scripts/compute_matrix.rb) and
    # ci/link-unit-download.sh's pin-hit fetch. windows/arm64 pairs the
    # msys2 clangarm64 environment (triple aarch64-w64-mingw32) with the
    # aarch64-pc-windows-gnullvm Rust target, so its pid follows the
    # x86_64-windows-gnu convention — but NO product release publishes an
    # arm64 windows unit yet (v2.8.11 verified: x86_64-windows-gnu is the
    # only windows unit). The planner skips the leg loudly naming the exact
    # missing asset; if the eventual asset spells its pid differently, this
    # table is the one-line fix.
    LINK_UNIT_PIDS = {
      %w[linux-gnu x86_64] => "linux-gnu-x86_64",
      %w[linux-gnu arm64] => "linux-gnu-arm64",
      %w[linux-musl x86_64] => "linux-musl-x86_64",
      %w[linux-musl arm64] => "linux-musl-arm64",
      %w[macos x86_64] => "macos-x86_64",
      %w[macos arm64] => "macos-arm64",
      %w[windows x86_64] => "x86_64-windows-gnu",
      %w[windows arm64] => "aarch64-windows-gnu"
    }.freeze

    # The lookup for callers with no detected host (the planner's artifact
    # gate); same named failure as host_id_for.
    def self.link_unit_pid_for(os_id, arch_id)
      LINK_UNIT_PIDS.fetch([os_id, arch_id]) { raise TebakoRuntimeBuilder::Error.new("#{os_id}/#{arch_id}", 112) }
    end

    # host_id → the spec 03 §3 vcpkg-form triplet (the in-image payload
    # manifest's provides.provides[].platform grammar). The mapping is
    # owned by tpkg::Platform (tamatebako/tebako — the single
    # triplet ↔ release-asset-name owner); this mirrors it for the
    # factory's manifest emission, and a drift fails loudly at the boot
    # smoke (the driver refuses an unknown triplet at manifest parse,
    # exit 65). windows-ucrt-arm64's triplet is the product's RESERVED
    # axis entry: tpkg parses it but payload-manifest validate rejects
    # its use until the platform ships — the leg's publish gate keeps a
    # served manifest from reaching consumers before that.
    TPKG_TRIPLETS = {
      "windows-ucrt64" => "x86_64-windows-ucrt",
      "windows-ucrt-arm64" => "aarch64-windows-ucrt",
      "macos-arm64" => "aarch64-macos",
      "macos-x86_64" => "x86_64-macos",
      "linux-gnu-x86_64" => "x86_64-linux-gnu",
      "linux-gnu-arm64" => "aarch64-linux-gnu",
      "linux-musl-x86_64" => "x86_64-linux-musl",
      "linux-musl-arm64" => "aarch64-linux-musl"
    }.freeze

    # This platform's spec 03 §3 triplet (e.g. "x86_64-windows-ucrt").
    def tpkg_triplet
      TPKG_TRIPLETS.fetch(host_id) do
        raise TebakoRuntimeBuilder::Error.new("no spec 03 §3 triplet for host_id '#{host_id}'", 112)
      end
    end

    # Platform id as used by tebako-runtime-ruby package names
    # (e.g. "macos-arm64", "windows-ucrt64")
    def host_id
      self.class.host_id_for(host_os_id, host_arch_id)
    end

    def brew_prefix(package)
      out, st = Open3.capture2("brew --prefix #{package}")
      unless st.exitstatus.zero?
        raise TebakoRuntimeBuilder::Error, "brew --prefix #{package} failed with code #{st.exitstatus}"
      end

      out.strip
    end

    private

    def host_os_id
      case @ostype
      when /msys|mingw|cygwin/ then "windows"
      when /darwin/ then "macos"
      when /linux-musl/ then "linux-musl"
      when /linux/ then "linux-gnu"
      else
        raise TebakoRuntimeBuilder::Error.new(@ostype, 112)
      end
    end

    def host_arch_id
      case @arch
      when /^(x86_64|amd64|x64)$/ then "x86_64"
      when /^(aarch64|arm64)$/ then "arm64"
      else
        raise TebakoRuntimeBuilder::Error.new(@arch, 112)
      end
    end
  end
end
