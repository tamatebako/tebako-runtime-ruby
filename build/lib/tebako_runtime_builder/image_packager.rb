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
  # into the standalone image published next to the runtime executable:
  # tebako-runtime-<tebako>-<ruby>-<platform>.tfs. The lean flow's driver
  # mounts this image directly instead of extracting a runtime layout.
  #
  # The image is limnifs on EVERY host (spec 20 §6: the only first-class
  # image format; the dwarfs backend stays a read path for existing
  # payloads and nothing new is written in it). Every link unit in the
  # pinned closure mounts limnifs: the unix and windows-x64 units carry
  # backend-limnifs alongside the read backends, the windows-arm64 unit is
  # limnifs-only by design (dwarfs-t #100). The boot smoke proves the
  # mount on every leg.
  #
  # One tool only (mirrored from the python factory): the tfs CLI the
  # Builder resolved (--tfs / TEBAKO_TFS, else the pin-verified TfsTool
  # fetch off contract.yml's link_unit_release), `tfs mkimage` WITHOUT a
  # --format flag — the CLI default is limnifs (spec 20 §6), and pinning a
  # flag here would drift from it. There is deliberately no mkdwarfs
  # fallback: that binary writes dwarfs-t, a format nothing new ships in
  # (and on arm64 it is the x64 binary under Prism — SIGSEGV, run
  # 35608648436).
  class ImagePackager
    def initialize(platform, tfs:)
      @platform = platform
      @tfs = tfs
    end

    def package(layout_dir, image_path)
      check_layout!(layout_dir)
      FileUtils.mkdir_p(File.dirname(image_path))
      FileUtils.rm_f(image_path)
      puts "-- Packing the runtime layout as #{image_path} (tfs mkimage, the default limnifs format)"
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture_v([@tfs, "mkimage", layout_dir, "-o", image_path])
      image_path
    rescue TebakoRuntimeBuilder::Error => e
      raise e if e.error_code == 131 && e.message.include?("layout tree")

      raise TebakoRuntimeBuilder::Error.new("runtime image packaging failed: #{e.message}", 131)
    end

    private

    def check_layout!(layout_dir)
      return if File.directory?(layout_dir)

      raise TebakoRuntimeBuilder::Error.new(
        "runtime layout tree #{layout_dir} does not exist (the deploy pass did not assemble it)", 131
      )
    end
  end
end
