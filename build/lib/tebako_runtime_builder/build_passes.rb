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
  # The build passes invoked from the CMake project (build/CMakeLists.txt)
  # via build/tools/build_pass.rb -- the consumer-side steps the pre-patched
  # ruby source tree expects. They replace the gem's tebako-packager
  # pass1/pass1a/pass2 without carrying the gem's patch layer:
  #
  #   prepare       -- substitute @TEBAKO_MLIBS@ in template/Makefile.in with
  #                    the platform static library list and build the stub
  #                    libtebako-fs.a for the toolchain link
  #   postconfigure -- substitute S["MAINLIBS"] in the generated
  #                    config.status (the deferred patch of the canonical set)
  #   toolchain     -- make + make install, stash the pristine ruby
  #                    environment, drop the stub libtebako-fs.a
  #   deploy        -- assemble the runtime filesystem image (fs.bin)
  #   finalize      -- relink the ruby program against the real
  #                    libtebako-fs.a and strip it to the output package
  module BuildPasses
    TEBAKO_MLIBS_PLACEHOLDER = "@TEBAKO_MLIBS@"

    # config.status MAINLIBS defaults per platform (gem PatchBuildsystem);
    # configure's LIBS env is appended to MAINLIBS after ruby's defaults,
    # which may or may not pad the value with a trailing space before the
    # closing quote (msys substitutes both variants)
    MSYS_MAINLIBS_LINE =
      "-lshell32 -lws2_32 -liphlpapi -limagehlp -lshlwapi -lbcrypt -lcrypt32 -ladvapi32 -luser32"

    TOOLCHAIN_STUB_C = File.expand_path("../../resources/toolchain_stub.c", __dir__).freeze

    class << self # rubocop:disable Metrics/ClassLength
      def prepare(ostype, ruby_source_dir, deps_lib_dir, ruby_ver, mount_point, cc = "cc") # rubocop:disable Metrics/ParameterLists
        puts "-- Running prepare script"

        platform = TebakoRuntimeBuilder::Platform.new(ostype)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        mlibs = TebakoRuntimeBuilder::Mlibs.new(platform, deps_lib_dir).compute(rv, with_compression: true)
        substitute_tebako_mlibs!(File.join(ruby_source_dir, "template", "Makefile.in"), mlibs)
        build_toolchain_stub(platform, deps_lib_dir, mount_point, cc)
      end

      def postconfigure(ostype, ruby_source_dir, deps_lib_dir, ruby_ver)
        puts "-- Running postconfigure script"

        platform = TebakoRuntimeBuilder::Platform.new(ostype)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        # The gem gates the config.status substitution to ruby 3.3+ off msys
        # (Pass2NonMSysPatch); msys always substitutes (Pass2MSysPatch)
        return unless platform.msys? || rv.ruby33?

        mlibs = TebakoRuntimeBuilder::Mlibs.new(platform, deps_lib_dir).compute(rv, with_compression: false)
        substitute_config_status!(File.join(ruby_source_dir, "config.status"), platform, mlibs)
      end

      def toolchain(ruby_source_dir, data_src_dir, stash_dir, deps_lib_dir) # rubocop:disable Metrics/MethodLength
        puts "-- Running toolchain script"

        platform = TebakoRuntimeBuilder::Platform.new
        rbconfig = File.join(ruby_source_dir, "rbconfig.rb")
        Dir.chdir(ruby_source_dir) do
          run_make_with_serial_fallback(["make", "-j#{platform.ncores}"])
          # The pre-patched tool/mkconfig.rb bakes the memfs mount point into
          # the generated rbconfig.rb (ungated), which would send
          # 'make install' into /__tebako_memfs__ on the host (EROFS) and
          # ship a memfs-prefix rbconfig in the image. Point the generated
          # rbconfig.rb (a build artifact, not the patched source) at the
          # packaging prefix instead, then force verconf.h/loadpath.o to
          # regenerate from it: their make chain keys on the .rbconfig.time
          # stamp (unchanged here -- mkconfig.rb is NOT re-run), so the files
          # are removed to make the next make rebuild them from the rewritten
          # rbconfig.rb and relink the toolchain ruby with the packaging
          # prefix compiled in -- the same content the gem's two-pass order
          # produced (it patched mkconfig.rb only after the toolchain
          # install).
          rewrite_rbconfig_prefix!(rbconfig, data_src_dir)
          FileUtils.rm_f(["verconf.h", "loadpath.o", "loadpath.obj"])
          # Serialized from here: with the common.mk exts.mk/extinit.c
          # dependency present from the start, the rbconfig change cascades
          # (configure-ext.mk -> exts.mk -> extinit.c -> extinit.o) and a
          # parallel link can race the regenerated extinit.o away
          # ('no such file or directory: ext/extinit.o'). The gem never saw
          # this -- that patch landed only for its final, stable build.
          TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["make", "-j1"])
          TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["make", "install", "-j1"])
        end

        puts "   ... saving pristine Ruby environment to #{stash_dir}"
        FileUtils.rm_rf(stash_dir, secure: true)
        FileUtils.mkdir_p(stash_dir)
        FileUtils.cp_r "#{data_src_dir}/.", stash_dir

        # The stub driver served the toolchain link; the final relink must
        # resolve -ltebako-fs to the real library in the CMake binary dir
        FileUtils.rm_f(File.join(deps_lib_dir, "libtebako-fs.a"))
      end

      def deploy(ruby_ver, stash_dir, data_src_dir, data_pre_dir, data_bin_file, stub_dir, deps_bin_dir) # rubocop:disable Metrics/ParameterLists
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        platform = TebakoRuntimeBuilder::Platform.new
        TebakoRuntimeBuilder::ImageBuilder.new(platform, rv, stash_dir, data_src_dir, data_pre_dir,
                                               data_bin_file, deps_bin_dir).build(stub_dir)
      end

      def finalize(ostype, ruby_source_dir, output, ruby_ver, patchelf = nil) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        puts "-- Running finalize script"

        platform = TebakoRuntimeBuilder::Platform.new(ostype)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        rbconfig = File.join(ruby_source_dir, "rbconfig.rb")
        Dir.chdir(ruby_source_dir) do
          # Flip the generated rbconfig.rb back to the memfs mount point so
          # the final ruby program links with the packaged load paths
          # compiled in (verconf.h/loadpath.o are forced to regenerate from
          # the rewritten rbconfig.rb); drop the program so the link re-runs
          # against the real libtebako-fs.a
          rewrite_rbconfig_prefix!(rbconfig, platform.fs_mount_point)
          FileUtils.rm_f(["verconf.h", "loadpath.o", "loadpath.obj", "ruby#{platform.exe_suffix}"])
          # Serialized (see the toolchain pass): the rbconfig flip re-triggers
          # the exts.mk/extinit.c cascade; the link must not race it
          TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["make", "ruby", "-j1"]) if rv.ruby3x?
          TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["make", "-j1"])
        end

        src_name = File.join(ruby_source_dir, "ruby#{platform.exe_suffix}")
        run_patchelf(src_name, patchelf)
        TebakoRuntimeBuilder::Stripper.strip_file(src_name, output)
        puts "Created tebako runtime package at \"#{output}\""
      end

      private

      # The one substitution the pre-patched tree cannot carry: the static
      # library list is computed per packaging host. A missing placeholder
      # means the source is NOT a tebako pre-patched tree (e.g. a pristine
      # upstream ruby) -- fail loudly instead of linking a plain ruby.
      # Idempotent like the gem's restore_and_save: the untouched template is
      # kept next to it (.tebako-orig) and every run substitutes from that
      # copy, so ExternalProject rebuilds re-running this pass are safe.
      def substitute_tebako_mlibs!(makefile_in, mlibs) # rubocop:disable Metrics/MethodLength
        orig = "#{makefile_in}.tebako-orig"
        unless File.exist?(orig)
          unless File.exist?(makefile_in)
            raise TebakoRuntimeBuilder::Error.new("Could not patch #{makefile_in} because it does not exist.", 107)
          end

          contents = File.read(makefile_in)
          unless contents.include?(TEBAKO_MLIBS_PLACEHOLDER)
            raise TebakoRuntimeBuilder::Error.new(
              "#{makefile_in} carries no #{TEBAKO_MLIBS_PLACEHOLDER} placeholder -- " \
              "this is not a tebako pre-patched ruby source tree " \
              "(expected tfs-ruby-<version>-src from tamatebako/ruby releases)", 130
            )
          end
          FileUtils.cp(makefile_in, orig)
        end

        puts "   ... substituting #{TEBAKO_MLIBS_PLACEHOLDER} in #{makefile_in}"
        File.write(makefile_in, File.read(orig).gsub(TEBAKO_MLIBS_PLACEHOLDER, mlibs))
      end

      def substitute_config_status!(config_status, platform, mlibs) # rubocop:disable Metrics/MethodLength
        unless File.exist?(config_status)
          raise TebakoRuntimeBuilder::Error.new("Could not patch #{config_status} because it does not exist.",
                                                107)
        end

        puts "   ... substituting MAINLIBS in #{config_status}"
        subst = "S[\"MAINLIBS\"]=\"#{mlibs}\""
        contents = File.read(config_status)
        # Idempotent: a rebuild re-runs this pass over an already-substituted
        # config.status; the msys pair covers the two padding variants of the
        # MAINLIBS line, only one of which can match. A miss on every
        # candidate in a file that was never substituted is the silent-failure
        # mode the gem's sub! hid, so it earns a warning.
        substituted = contents.include?(subst) || config_status_patterns(platform).any? do |pattern|
          !contents.sub!(pattern, subst).nil?
        end
        File.write(config_status, contents)
        return if substituted

        puts "Warning: no config.status MAINLIBS pattern matched; the substitution did not happen"
      end

      def config_status_patterns(platform)
        if platform.macos?
          ["S[\"MAINLIBS\"]=\"-ldl -lobjc -lpthread \""]
        elsif platform.msys?
          ["S[\"MAINLIBS\"]=\"#{MSYS_MAINLIBS_LINE} \"", "S[\"MAINLIBS\"]=\"#{MSYS_MAINLIBS_LINE}\""]
        else
          ["S[\"MAINLIBS\"]=\"-lz -lrt -lrt -ldl -lcrypt -lm -lpthread \""]
        end
      end

      # Compile and archive the toolchain stub driver as
      # <deps_lib_dir>/libtebako-fs.a (the deps lib dir precedes the CMake
      # binary dir in the ruby link flags, so the stub wins the toolchain
      # link; it is removed by the toolchain pass)
      def build_toolchain_stub(platform, deps_lib_dir, mount_point, cc) # rubocop:disable Metrics/MethodLength
        puts "   ... building the toolchain stub libtebako-fs.a"
        FileUtils.mkdir_p(deps_lib_dir)
        obj = File.join(deps_lib_dir, "tebako-toolchain-stub.o")
        lib = File.join(deps_lib_dir, "libtebako-fs.a")
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(
          [cc, "-c", TOOLCHAIN_STUB_C, "-DTEBAKO_STUB_MOUNT_POINT=\"#{mount_point}\"", "-o", obj]
        )
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["ar", "rcs", lib, obj])
        if platform.macos?
          TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["ranlib", "-no_warning_for_no_symbols", "-c", lib])
        end
        FileUtils.rm_f(obj)
      end

      def run_patchelf(src_name, patchelf)
        return if patchelf.nil?

        params = [patchelf, "--remove-needed-version", "libpthread.so.0", "GLIBC_PRIVATE", src_name]
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(params)
      end

      # With the common.mk exts.mk/extinit.c dependency present from the
      # start (the gem applied it only for the final, stable build), the
      # first full make can race the regenerated extinit.o away from a
      # parallel ruby link ('no such file or directory: ext/extinit.o' --
      # timing-dependent; observed on the 3-core CI runners). A failed
      # parallel make leaves clean target state, so a serial re-run
      # completes deterministically; keep the parallel fast path and fall
      # back only on failure.
      def run_make_with_serial_fallback(args)
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(args)
      rescue TebakoRuntimeBuilder::Error
        puts "   ... parallel make failed (possible exts.mk/extinit.c cascade race); retrying serially"
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(args[0..-2] + ["-j1"])
      end

      # Rewrite the two prefix lines of the GENERATED rbconfig.rb (every
      # derived path is a $(...) expression evaluated from prefix at load
      # time, so the two lines fully determine the tree). rbconfig.rb is a
      # build artifact produced by the patched tool/mkconfig.rb -- rewriting
      # it is the consumer-side equivalent of the gem's "patch mkconfig.rb
      # after the toolchain install" ordering, not a source patch. Callers
      # remove verconf.h/loadpath.o afterwards so the next make regenerates
      # them from the rewritten rbconfig.rb (their make chain keys on the
      # .rbconfig.time stamp, which does not fire here).
      def rewrite_rbconfig_prefix!(rbconfig, dir) # rubocop:disable Metrics/MethodLength
        unless File.exist?(rbconfig)
          raise TebakoRuntimeBuilder::Error.new("Could not rewrite #{rbconfig} because it does not exist.",
                                                107)
        end

        lines = {
          'CONFIG["prefix"]' => "  CONFIG[\"prefix\"] = (TOPDIR || DESTDIR + \"#{dir}\")",
          'CONFIG["RUBY_EXEC_PREFIX"]' => "  CONFIG[\"RUBY_EXEC_PREFIX\"] = \"#{dir}\""
        }
        contents = File.read(rbconfig)
        lines.each do |key, line|
          next if contents.gsub!(/^ *#{Regexp.escape(key)} = .*$/, line)

          raise TebakoRuntimeBuilder::Error.new("#{rbconfig} carries no #{key} line to rewrite", 130)
        end
        File.write(rbconfig, contents)
      end
    end
  end
end
