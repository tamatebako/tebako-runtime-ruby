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
require "yaml"

module TebakoRuntimeBuilder
  # End-to-end runtime package build (tools/build_runtime):
  # fetch the pre-patched ruby source (SHA256-verified against the
  # tamatebako/ruby release SHA256SUMS), run the CMake project in build/,
  # then relink and strip the runtime binary to the output path.
  class Builder # rubocop:disable Metrics/ClassLength
    def initialize(repo_root:, ruby_version:, tebako_version:, prefix:, output:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   patchelf: false, jobs: nil, release: SourceFetcher::DEFAULT_RELEASE, mirror: nil,
                   image: true, embed_image: false, tfs: nil)
      @repo_root = repo_root
      @ruby_version = ruby_version
      @tebako_version = tebako_version
      @prefix = File.expand_path(prefix)
      @output = output
      @patchelf = patchelf
      @jobs = jobs
      @release = release
      @mirror = mirror
      @image = image
      @embed_image = embed_image
      @tfs = tfs
      @platform = TebakoRuntimeBuilder::Platform.new
    end

    def run
      check_image_shape!
      assets = fetcher.fetch_assets(@ruby_version, @platform)
      puts "-- Building tebako runtime for ruby #{@ruby_version} " \
           "(tebako #{@tebako_version}, #{@platform.host_id}, " \
           "#{assets.map { |path,| File.basename(path) }.join(" + ")})"
      cmake_configure(assets)
      cmake_build
      finalize
      pack_image if @image
      write_abi_sidecar
      write_contract_sidecar(assets)
      @output
    end

    def default_output
      File.join(Dir.pwd, "runtime-packages",
                "tebako-runtime-#{@tebako_version}-#{@ruby_version}-#{@platform.host_id}#{@platform.exe_suffix}")
    end

    # The standalone runtime filesystem image published next to the runtime
    # executable (item 30): the assembled layout tree, DwarFS image form.
    def image_output
      "#{output.sub(/\.exe\z/, "")}.tfs"
    end

    # The era-2 contract card constants (spec 18 C2): what this factory
    # builds. Written into every package's .contract.yaml sidecar by
    # write_contract_sidecar (see below) and folded into the release
    # manifest entry by scripts/upload_release.rb.
    CONTRACT_CARD = { "contract_era" => 2, "image_layout" => 1 }.freeze

    private

    # A runtime with neither the embedded image (v1 shape) nor the
    # standalone .tfs (image era) cannot boot at all -- refuse to build it
    def check_image_shape!
      return if @image || @embed_image

      raise TebakoRuntimeBuilder::Error.new(
        "--no-image without --embed-image produces a runtime that carries no filesystem image " \
        "in any form (it would fail every boot naming TEBAKO_RUNTIME_IMAGE)", 105
      )
    end

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

    # The v2 link switch (image era): set TEBAKO_RUST_LIBDIR to the
    # directory holding the staged link unit (libtebako_driver.a +
    # libtfs.a + closure/*.a, scoped by tebako-arscope) and the build
    # links the scoped Rust staticlibs instead of the C++ tebako-main
    # driver and C++ libtfs.
    def rust_driver?
      ENV.fetch("TEBAKO_RUST_LIBDIR", nil) && !ENV["TEBAKO_RUST_LIBDIR"].empty?
    end

    # The memfs mount root the runtime is built against (spec 18 C1/S49).
    # The value FLOWS from the source tarball's tebako-mount-root manifest
    # (MountRoot; tamatebako/ruby's SourcePrep is the single owner). A
    # pre-manifest tarball (v0.2.12 and older) is refused by name with
    # exit 132 — never a fallback to the platform convention.
    def mount_root(tarball)
      @mount_root ||= TebakoRuntimeBuilder::MountRoot.new(tarball).read
    end

    # The tarball's override capability (spec 17 §1): the loadpath patch
    # presence, declared by SourcePrep's tebako-mount-root-override
    # manifest — the image layout's grant is emitted only when the
    # source carries it (the same single-owner flow as mount_root).
    def mount_root_override(tarball)
      @mount_root_override ||= TebakoRuntimeBuilder::MountRoot.new(tarball).override?
    end

    def cmake_configure(assets) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      (tarball, sha256) = assets[0]
      args = ["cmake",
              "-DCMAKE_BUILD_TYPE=Release",
              "-DRUBY_VER:STRING=#{@ruby_version}",
              "-DRUBY_HASH:STRING=#{sha256}",
              "-DRUBY_TARBALL:STRING=file://#{tarball}",
              "-DRUNTIME_NAME:STRING=#{File.basename(output).sub(/\.exe\z/, "")}",
              "-DDEPS:STRING=#{deps}",
              "-DTEBAKO_VERSION:STRING=#{@tebako_version}",
              "-DLOG_LEVEL:STRING=error",
              "-DFS_MOUNT_POINT:STRING=#{mount_root(tarball)}",
              "-DMOUNT_ROOT_OVERRIDE:BOOL=#{mount_root_override(tarball)}"]
      if assets.length == 2
        (tarball_p2, sha256_p2) = assets[1]
        args += ["-DRUBY_TARBALL_P2:STRING=file://#{tarball_p2}", "-DRUBY_HASH_P2:STRING=#{sha256_p2}"]
      end
      args << "-DREMOVE_GLIBC_PRIVATE=ON" if @patchelf && @platform.linux_gnu?
      args << "-DTEBAKO_EMBED_IMAGE:BOOL=ON" if @embed_image
      # The v2 link (image era): the Rust tebako-driver + scoped tfs
      # replace the C++ tebako-main driver and the C++ libtfs.
      args << "-DTEBAKO_RUST_DRIVER:BOOL=ON" if rust_driver?
      args += ["-G", @platform.m_files, "-B", output_folder, "-S", File.join(@repo_root, "build")]

      FileUtils.mkdir_p(output_folder)
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture(args, env: @platform.b_env)
    rescue TebakoRuntimeBuilder::Error => e
      # The mount-root refusals (131/132) keep their named exit codes —
      # wrapping them as a generic configure failure would hide the C1
      # contract verdict (spec 18 S49).
      raise if [131, 132].include?(e.error_code)

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
      TebakoRuntimeBuilder::BuildPasses.finalize(@platform.ostype, ruby_source_dir, output, @ruby_version,
                                                 File.join(deps, "lib"), patchelf)
    end

    # The layout tree the deploy pass assembled (the CMake project's
    # DATA_SRC_DIR) is packed as the standalone image AFTER the executable
    # is finalized: the tree is the exact content the embedded fs.bin was
    # written from, and the deploy pass leaves it in place.
    def pack_image
      TebakoRuntimeBuilder::ImagePackager.new(@platform, File.join(deps, "bin"), tfs: @tfs)
                                         .package(File.join(output_folder, "s"), image_output)
    end

    # The runtime's own platform string (spec 05 §5's abi line — ruby:
    # `Gem::Platform.local.to_s`, the RbConfig arch with the darwin segment
    # hyphenated) as `<output>.abi`. Native-extension payloads constrain
    # BOTH the version line and this line; the release flow folds it into
    # the manifest entry's additive `abi` key.
    def write_abi_sidecar
      tree = File.join(output_folder, "s")
      rbconfig = Dir[File.join(tree, "lib", "ruby", "*", "*", "rbconfig.rb")].first
      raise TebakoRuntimeBuilder::Error.new("no rbconfig.rb under #{tree} — the layout tree is incomplete", 105) unless rbconfig

      arch = File.basename(File.dirname(rbconfig))
      abi = arch.gsub(/darwin(\d+)/, 'darwin-\1')
      File.write("#{output.sub(/\.exe\z/, '')}.abi", "#{abi}\n")
    end

    # The era-2 contract provenance (spec 18 C2) as `<output>.contract.yaml`,
    # folded into the release manifest entry by scripts/upload_release.rb
    # (fail-closed there: a package without it is pre-era and refused).
    # mount_root is the SAME flow as -DFS_MOUNT_POINT (the tarball's
    # tebako-mount-root manifest — ONE source, memoized at configure);
    # built_from names the source release and every consumed tarball with
    # its verified sha256 (msys consumes two: pass1 + pass2).
    def write_contract_sidecar(assets)
      card = CONTRACT_CARD.merge(
        "mount_root" => @mount_root,
        "built_from" => {
          "release" => @release,
          "sources" => assets.map { |(path, sha256)| { "name" => File.basename(path), "sha256" => sha256 } }
        }
      )
      File.write("#{output.sub(/\.exe\z/, '')}.contract.yaml", YAML.dump(card))
    end
  end
end
