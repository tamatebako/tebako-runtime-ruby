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
  # Packs the assembled runtime layout tree (the deploy pass's DATA_SRC_DIR)
  # into the standalone DwarFS image published next to the runtime
  # executable: tebako-runtime-<tebako>-<ruby>-<platform>.tfs (item 30,
  # producer side). The lean flow's driver mounts this image directly
  # instead of extracting a runtime layout.
  #
  # Tool choice (documented per the owner rule): the image is written by
  # our own factory toolchain, never by a random system binary:
  #   1. the tfs binary (tebako-rs tfs-cli, `tfs mkimage --format dwarfs`)
  #      when one is resolvable (--tfs / TEBAKO_TFS / PATH) -- the
  #      documented tool; mkimage binds the libdwarfs-t writer
  #      IN-PROCESS (no mkdwarfs shell-out);
  #   2. otherwise the build's own deps/bin/mkdwarfs directly (the same
  #      prebuilt binary the deploy pass already shelled to for fs.bin).
  # Both are build-time factory tools; nothing here becomes a runtime
  # dependency of the shipped packages.
  class ImagePackager
    def initialize(platform, deps_bin_dir, tfs: nil)
      @platform = platform
      @deps_bin_dir = deps_bin_dir
      @tfs = tfs
    end

    def package(layout_dir, image_path)
      check_layout!(layout_dir)
      FileUtils.mkdir_p(File.dirname(image_path))
      FileUtils.rm_f(image_path)
      pack(layout_dir, image_path)
      image_path
    rescue TebakoRuntimeBuilder::Error => e
      raise e if e.error_code == 131

      raise TebakoRuntimeBuilder::Error.new("runtime image packaging failed: #{e.message}", 131)
    end

    private

    def pack(layout_dir, image_path)
      if (tfs = tfs_path)
        pack_with_tfs(tfs, layout_dir, image_path)
      elsif (mkdwarfs = mkdwarfs_path)
        pack_with_mkdwarfs(mkdwarfs, layout_dir, image_path)
      else
        raise TebakoRuntimeBuilder::Error.new(
          "no image tool available: tfs not found (set --tfs or TEBAKO_TFS) and no deps mkdwarfs at " \
          "#{File.join(@deps_bin_dir, "mkdwarfs#{@platform.exe_suffix}")}", 131
        )
      end
    end

    def check_layout!(layout_dir)
      return if File.directory?(layout_dir)

      raise TebakoRuntimeBuilder::Error.new(
        "runtime layout tree #{layout_dir} does not exist (the deploy pass did not assemble it)", 131
      )
    end

    def pack_with_tfs(tfs, layout_dir, image_path)
      puts "-- Packing the runtime layout as #{image_path} (tfs mkimage)"
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture_v(
        [tfs, "mkimage", "--format", "dwarfs", layout_dir, "-o", image_path]
      )
    end

    def pack_with_mkdwarfs(mkdwarfs, layout_dir, image_path)
      puts "-- Packing the runtime layout as #{image_path} (deps mkdwarfs; tfs not found -- " \
           "set --tfs or TEBAKO_TFS to use the documented tool)"
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture_v(
        [mkdwarfs, "-i", layout_dir, "-o", image_path, "--no-progress", "--force"]
      )
    end

    # An explicitly requested tfs (--tfs / TEBAKO_TFS) that does not resolve
    # is a hard error -- silently falling back would hide a misconfigured
    # toolchain. With nothing requested, tfs on PATH is used when present.
    def tfs_path
      requested = @tfs || ENV.fetch("TEBAKO_TFS", nil)
      return which(requested) || missing_tfs!(requested) if requested

      which("tfs#{@platform.exe_suffix}")
    end

    def missing_tfs!(requested)
      raise TebakoRuntimeBuilder::Error.new(
        "requested tfs binary '#{requested}' was not found (not a file, not on PATH)", 131
      )
    end

    def mkdwarfs_path
      path = File.join(@deps_bin_dir, "mkdwarfs#{@platform.exe_suffix}")
      return path if File.file?(path)

      # No deps mkdwarfs (e.g. a caller that only wants the image): let tfs
      # resolve mkdwarfs itself (TEBAKO_MKDWARFS / PATH); direct fallback
      # cannot run without it.
      nil
    end

    def which(executable)
      return executable if File.file?(executable) && File.executable?(executable)

      path_candidates(executable).each do |path|
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def path_candidates(executable)
      exts = @platform.msys? ? [".exe", ""] : [""]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).product(exts).map do |dir, ext|
        File.join(dir, "#{executable}#{ext}")
      end
    end
  end
end
