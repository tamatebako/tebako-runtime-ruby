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
  class Platform
    def initialize(ostype = RUBY_PLATFORM, arch = RbConfig::CONFIG["host_cpu"])
      @ostype = ostype
      @arch = arch
      @linux = @ostype =~ /linux/ ? true : false
      @musl = @ostype =~ /linux-musl/ ? true : false
      @macos = @ostype =~ /darwin/ ? true : false
      @msys  = @ostype =~ /msys|mingw|cygwin/ ? true : false

      @fs_mount_point = @msys ? "A:/__tebako_memfs__" : "/__tebako_memfs__"
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

    # Platform id as used by tebako-runtime-ruby package names
    # (e.g. "macos-arm64", "linux-gnu-x86_64")
    def host_id
      "#{host_os_id}-#{host_arch_id}"
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
