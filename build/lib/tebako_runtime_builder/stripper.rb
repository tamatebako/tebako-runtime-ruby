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
require "find"
require "open3"

module TebakoRuntimeBuilder
  # Tebako packaging support (stripper) -- gem Tebako::Stripper
  module Stripper
    DELETE_EXTENSIONS = %w[o lo obj a la lib].freeze

    # The build-log basenames the extension compiles leave next to each
    # ext/ (the audit of the shipped images, tebako-runtime-ruby#384:
    # every leg carries ~7 mkmf.log — bigdecimal, debug, fiddle, nkf,
    # racc, rbs, win32ole/syslog; the autoconf-flavored pair rides the
    # same glob class for the exts that produce them).
    BUILD_LOG_BASENAMES = %w[mkmf.log extconf.log config.log].freeze

    class << self
      # Strip
      # Removes build artefacts, strip shared objects
      def strip(platform, src_dir)
        puts "   ... stripping the output"
        strip_bl(src_dir)
        strip_ds(src_dir)
        strip_bs(src_dir)
        strip_fi(platform, src_dir)
        strip_li(platform, src_dir)
      end

      def strip_file(file_in, file_out = nil)
        params = ["strip", "-S", file_in]
        params << "-o" << file_out unless file_out.nil?
        out, st = Open3.capture2e(*params)

        # Some gems (well, libmspack) has bundled extensions for several architectures)
        # Getting something like:
        # strip: Unable to recognise the format of the input file
        # `/tmp/cirrus-ci-build/o/s/lib/ruby/gems/3.1.0/gems/libmspack-0.11.0/ext/x86_64-linux/libmspack.so'
        # on aarch64

        puts "Warning: could not strip #{file_in}:\n #{out}" unless st.exitstatus.zero?
      end

      private

      # The extension-compile build logs (BUILD_LOG_BASENAMES): build-time
      # diagnostics nothing reads at runtime — mkmf's Logging writes the
      # file during extconf, the extension loader loads the built
      # .so/.bundle, and a rebuild re-runs extconf rather than reading the
      # log. Shipping them leaks the compile's temp names into the image
      # bytes: mkmf's ccXXXXXX.o object names are random per run (the E4
      # twin-run image diff, tebako-runtime-ruby#384 — the two mkmf.log
      # files were the whole windows diff set beside the manifest hash
      # they moved). Same sweep class as the dSYM debris below. The glob
      # simply misses on trees that carry none.
      def strip_bl(src_dir)
        BUILD_LOG_BASENAMES.each do |basename|
          Dir.glob(File.join(src_dir, "**", basename)).each do |log|
            puts "   ... removing build log #{log.sub("#{src_dir}/", "")}"
            FileUtils.rm(log)
          end
        end
      end

      # The dSYM debug-info trees (macOS dsymutil output next to each
      # extension bundle: *.bundle.dSYM/) — directories, so they ride their
      # own sweep (strip_li walks files). Pure debug companions nothing
      # loads at runtime; shipping them leaks the build host's paths into
      # the image bytes and bloats every env image. The glob simply misses
      # on platforms that never produce them.
      def strip_ds(src_dir)
        Dir.glob(File.join(src_dir, "**", "*.dSYM")).each do |dsym|
          puts "   ... removing debug-info tree #{dsym.sub("#{src_dir}/", "")}"
          FileUtils.rm_rf(dsym, secure: true)
        end
      end

      def get_files(platform)
        exe_suffix = platform.exe_suffix
        ["ruby#{exe_suffix}", "rubyw#{exe_suffix}"]
      end

      def strip_bs(src_dir)
        FileUtils.rm_rf([
                          File.join(src_dir, "share"),
                          File.join(src_dir, "include"),
                          File.join(src_dir, "lib", "pkgconfig")
                        ])
      end

      # The bin/ scripts now SHIP (the spec 30 §2 spawn surface): Entrypoints
      # declares the interpreter install's command scripts in the image
      # manifest and the driver runs the interpreter on them, so the v1
      # era's wholesale deletion (BIN_FILES) would leave every declaration
      # lying ("the env image's declaration lies", exit 65). What still
      # goes:
      #   * the installed interpreter itself — the runtime EXECUTABLE is
      #     the interpreter (spec 17 §7); bin/ruby is a second copy nothing
      #     compiled against the memfs, and a false spawn-surface candidate;
      #   * the msys shared build's ABI DLL (issue #40) — dead weight in
      #     the env image: PE imports resolve against the runtime exe's
      #     host directory (the store entry holds the DLL next to the exe),
      #     never against the memfs. The name is <cpu>-ucrt-ruby<ABI>.dll
      #     (x64-…, aarch64-… — the arm64 leg's spelling was missed by the
      #     old x64-only glob until the trr#291 read-back gate named it).
      def strip_fi(platform, src_dir)
        files = get_files(platform).map { |f| "#{src_dir}/bin/#{f}" }
        files += Dir.glob("#{src_dir}/bin/*-ucrt-ruby*.dll") if platform.msys?
        FileUtils.rm(files, force: true)
      end

      def strip_li(platform, src_dir)
        sext = strip_extensions(platform)
        Find.find(src_dir) do |file|
          next if File.directory?(file)

          extension = File.extname(file).delete_prefix(".").downcase
          if DELETE_EXTENSIONS.include?(extension)
            FileUtils.rm(file)
          elsif sext.include?(extension)
            strip_file(file)
          end
        end
      end

      def strip_extensions(platform)
        sext = ["so"]
        sext << "dll" if platform.msys?
        sext << "dylib" << "bundle" if platform.macos?
        sext
      end
    end
  end
end
