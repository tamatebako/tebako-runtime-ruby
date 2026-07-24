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

require "fileutils"

module TebakoRuntimeBuilder
  # End-to-end runtime package build (tools/build_runtime):
  # fetch the pre-patched ruby source (SHA256-verified against the
  # tamatebako/ruby release SHA256SUMS), run the CMake project in build/,
  # then relink and strip the runtime binary to the output path.
  class Builder
    def initialize(repo_root:, ruby_version:, tebako_version:, prefix:, output:, # rubocop:disable Metrics/ParameterLists
                   patchelf: false, jobs: nil, release: SourceFetcher::DEFAULT_RELEASE, mirror: nil)
      @repo_root = repo_root
      @ruby_version = ruby_version
      @tebako_version = tebako_version
      @prefix = File.expand_path(prefix)
      @output = output
      @patchelf = patchelf
      @jobs = jobs
      @release = release
      @mirror = mirror
      @platform = TebakoRuntimeBuilder::Platform.new
    end

    def run
      tarball, sha256 = fetcher.fetch(@ruby_version)
      puts "-- Building tebako runtime for ruby #{@ruby_version} " \
           "(tebako #{@tebako_version}, #{@platform.host_id})"
      cmake_configure(tarball, sha256)
      cmake_build
      finalize
      @output
    end

    def default_output
      File.join(Dir.pwd, "runtime-packages",
                "tebako-runtime-#{@tebako_version}-#{@ruby_version}-#{@platform.host_id}#{@platform.exe_suffix}")
    end

    private

    def fetcher
      @fetcher ||= TebakoRuntimeBuilder::SourceFetcher.new(release: @release, mirror: @mirror,
                                                           cache_dir: File.join(@prefix, "downloads"))
    end

    def output
      @output ||= default_output
    end

    def deps
      File.join(@prefix, "deps")
    end

    def output_folder
      File.join(@prefix, "o")
    end

    def ruby_source_dir
      File.join(deps, "src", "_ruby_#{@ruby_version}")
    end

    def ncores
      @jobs || @platform.ncores
    end

    def cmake_configure(tarball, sha256) # rubocop:disable Metrics/MethodLength
      args = ["cmake",
              "-DCMAKE_BUILD_TYPE=Release",
              "-DRUBY_VER:STRING=#{@ruby_version}",
              "-DRUBY_HASH:STRING=#{sha256}",
              "-DRUBY_TARBALL:STRING=file://#{tarball}",
              "-DRUNTIME_NAME:STRING=#{File.basename(output).sub(/\.exe\z/, "")}",
              "-DDEPS:STRING=#{deps}",
              "-DTEBAKO_VERSION:STRING=#{@tebako_version}",
              "-DLOG_LEVEL:STRING=error"]
      args << "-DREMOVE_GLIBC_PRIVATE=ON" if @patchelf && @platform.linux_gnu?
      args += ["-G", @platform.m_files, "-B", output_folder, "-S", File.join(@repo_root, "build")]

      FileUtils.mkdir_p(output_folder)
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture(args, env: @platform.b_env)
    rescue TebakoRuntimeBuilder::Error => e
      raise TebakoRuntimeBuilder::Error.new("'build_runtime' configure step failed: #{e.message}", 103)
    end

    def cmake_build
      args = ["cmake", "--build", output_folder, "--target", "tebako", "--parallel", ncores.to_s]
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture(args, env: @platform.b_env)
    rescue TebakoRuntimeBuilder::Error => e
      raise TebakoRuntimeBuilder::Error.new("'build_runtime' build step failed: #{e.message}", 104)
    end

    def finalize
      FileUtils.mkdir_p(File.dirname(output))
      patchelf = @patchelf && @platform.linux_gnu? ? File.join(deps, "bin", "patchelf") : nil
      TebakoRuntimeBuilder::BuildPasses.finalize(@platform.ostype, ruby_source_dir, output, @ruby_version, patchelf)
    end
  end
end
