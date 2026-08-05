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

require "digest"
require "fileutils"

module TebakoRuntimeBuilder
  # The build passes invoked from the CMake project (build/CMakeLists.txt)
  # via build/tools/build_pass.rb -- the consumer-side steps the pre-patched
  # ruby source tree expects. They replace the gem's tebako-packager
  # pass1/pass1a/pass2 without carrying the gem's patch layer:
  #
  #   prepare       -- substitute @TEBAKO_MLIBS@ in template/Makefile.in with
  #                    the platform static library list and build the stub
  #                    libtebako-fs.a for the toolchain link; on msys also
  #                    guard the dir.c glob_opendir capacity hint and read
  #                    libtfs' struct stat fills through their wire layout
  #                    (the hot-patches below)
  #   postconfigure -- substitute S["MAINLIBS"] in the generated
  #                    config.status (the deferred patch of the canonical set)
  #   toolchain     -- make + make install, stash the pristine ruby
  #                    environment, drop the stub libtebako-fs.a
  #   deploy        -- assemble the runtime layout tree (and, for the v1
  #                    embedded shape, the fs.bin image incbin embeds)
  #   finalize      -- relink the ruby program against the real
  #                    libtebako-fs.a and strip it to the output package
  module BuildPasses # rubocop:disable Metrics/ModuleLength
    TEBAKO_MLIBS_PLACEHOLDER = "@TEBAKO_MLIBS@"

    # config.status MAINLIBS defaults per platform (gem PatchBuildsystem);
    # configure's LIBS env is appended to MAINLIBS after ruby's defaults,
    # which may or may not pad the value with a trailing space before the
    # closing quote (msys substitutes both variants)
    MSYS_MAINLIBS_LINE =
      "-lshell32 -lws2_32 -liphlpapi -limagehlp -lshlwapi -lbcrypt -lcrypt32 -ladvapi32 -luser32"

    # msys dir.c hot-patch (glob_opendir capacity hint) ----------------------
    #
    # ruby's dir.c on _WIN32 reads the win32 DIR emulation's internals
    # directly in glob_opendir():
    #     if ((capacity = dirp->nfiles) > 0) {
    # -- a pre-allocation hint for the sorted-glob entries array. The
    # pre-patched msys dir.c routes opendir/readdir into the memfs via the
    # libtfs c_api, whose tebako_fs_opendir() handle is a registry token
    # (a small integer cast to void*), NOT a win32 DIR; the nfiles read
    # dereferences it and segfaults the runtime at startup the first time
    # rubygems glob-scans the memfs (Dir[] -> Primitive.dir_s_glob ->
    # glob_opendir; every msys leg of the boot smoke). The guard skips the
    # hint for memfs handles; the sorted path then grows the entries array
    # by realloc, exactly like the POSIX build, which has no hint at all.
    # tebako_fs_dir_is_embedded() is declared by the shim block the msys
    # patch injects earlier into the same translation unit.
    # Removal: once tamatebako/ruby's dir_c_memfs_msys.patch carries the
    # guard in the released source tree the anchor below no longer matches
    # and the substitution raises -- drop it together with the pin bump.
    MSYS_GLOB_OPENDIR_ANCHOR = "if ((capacity = dirp->nfiles) > 0) {"
    MSYS_GLOB_OPENDIR_GUARDED =
      "if (!tebako_fs_dir_is_embedded((tebako_dir_t) dirp) /* tebako patch */ " \
      "&& (capacity = dirp->nfiles) > 0) {"

    TOOLCHAIN_STUB_C = File.expand_path("../../resources/toolchain_stub.c", __dir__).freeze

    # msys rb_w32_fd_is_text shim (libtfs token fds) --------------------------
    #
    # A length-capped read of a memfs file (File.binread(path, n), IO#read(n))
    # takes ruby's CRLF set_binary_mode_with_seek_cur path on mingw, which
    # calls rb_w32_fd_is_text(fd) -- _osfile(fd) & FTEXT, an index into the
    # CRT fd table. libtfs memfs fds carry TEBAKO_FD_FLAG (0x40000000), so
    # the index lands far out of bounds and the runtime segfaults. Full
    # reads never take that path (read_all), which is why only the capped
    # form crashes. The pre-patched io.c shim block dispatches
    # read/pread/lseek/close/fstat/fcntl through tebako_fd_is_embedded but
    # left rb_w32_fd_is_text to the CRT; the substitution adds the missing
    # dispatch (the memfs fd has no CRT entry: report binary, the truthful
    # mode for image content).
    # Removal: once tamatebako/ruby's io_c_shims_msys patch carries the
    # dispatch in the released source the anchor below no longer matches
    # and the substitution raises -- drop it together with the pin bump.
    MSYS_FD_IS_TEXT_ANCHOR = <<~C.chomp
      #define rb_w32_close(...) tfs_close(__VA_ARGS__)
      #define rb_w32_fstati128(...) tfs_fstati128(__VA_ARGS__)
      #define fcntl(...) tfs_fcntl(__VA_ARGS__)
    C

    MSYS_FD_IS_TEXT_REPLACEMENT = <<~C.chomp
      /* rb_w32_fd_is_text reads the CRT fd table (_osfile) indexed by a real CRT
         fd; a libtfs token (fd | TEBAKO_FD_FLAG) indexes it far out of bounds
         and segfaults -- the CRLF set_binary_mode_with_seek_cur path of a
         length-capped read (File.binread(path, n)) hits it. The memfs fd has
         no CRT entry: report binary, the truthful mode for image content. */
      static int
      tfs_fd_is_text(int fd)
      {
          if (tebako_fd_is_embedded(fd)) {
              return 0;
          }
          return rb_w32_fd_is_text(fd);
      }

      #define rb_w32_close(...) tfs_close(__VA_ARGS__)
      #define rb_w32_fstati128(...) tfs_fstati128(__VA_ARGS__)
      #define rb_w32_fd_is_text(...) tfs_fd_is_text(__VA_ARGS__)
      #define fcntl(...) tfs_fcntl(__VA_ARGS__)
    C

    MSYS_FD_IS_TEXT_MARKER = "tfs_fd_is_text"

    # msys shared build (issue #40) ------------------------------------------
    #
    # The ruby DLL's export surface: mkexports.rb generates
    # x64-ucrt-ruby<ABI>.def from libruby-static.a -- the ruby API only.
    # x64-ucrt-ruby<ABI>.dll also carries the libtfs closure (the SOLIBS
    # substitution, postconfigure), and the exe's driver binds its
    # tebako_fs_* calls to the DLL, so the closure's tebako_* definitions
    # must join the .def. The fragment is derived from the link unit's own
    # libtfs.a (nm) at prepare time -- never a hand-maintained symbol list.
    MSYS_DLL_EXPORTS_FRAGMENT = "tebako-dll-exports.def"
    MSYS_DLL_EXPORTS_ANCHOR = "\t$(Q) $(BOOTSTRAPRUBY_COMMAND) $(srcdir)/win32/mkexports.rb -output=$@ $(LIBRUBY_A)\n"
    MSYS_DLL_EXPORTS_PATCHED =
      "#{MSYS_DLL_EXPORTS_ANCHOR}\t$(Q) cat #{MSYS_DLL_EXPORTS_FRAGMENT} >> $@ # tebako patched (issue 40)\n"

    # miniruby resolves tebako_fs_* from the DLL's import library in the
    # shared build, so its link must wait for $(LIBRUBY) (the import
    # library is a byproduct of the DLL link). Upstream never needed the
    # dependency (a plain miniruby references nothing from the DLL).
    MSYS_MINIRUBY_DEP_ANCHOR = "miniruby$(EXEEXT): config.status $(ALLOBJS) $(ARCHFILE)\n"
    MSYS_MINIRUBY_DEP_PATCHED = "miniruby$(EXEEXT): config.status $(ALLOBJS) $(ARCHFILE) $(LIBRUBY) # tebako patched (issue 40)\n"

    class << self # rubocop:disable Metrics/ClassLength
      def prepare(ostype, ruby_source_dir, deps_lib_dir, ruby_ver, mount_point, cc = "cc") # rubocop:disable Metrics/ParameterLists
        puts "-- Running prepare script"

        platform = TebakoRuntimeBuilder::Platform.new(ostype)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        # The @TEBAKO_MLIBS@ template placeholder exists only in the
        # linux-gnu/darwin/musl scenario trees; the msys scenario delivers
        # MAINLIBS through the config.status substitution (postconfigure)
        # instead, so there is no template substitution to make there.
        unless platform.msys?
          mlibs = TebakoRuntimeBuilder::Mlibs.new(platform, deps_lib_dir).compute(rv, with_compression: true)
          substitute_tebako_mlibs!(File.join(ruby_source_dir, "template", "Makefile.in"), mlibs)
        end
        # msys only: guard the one direct win32-DIR access the io routing of
        # the pre-patched dir.c does not cover, read libtfs' struct stat
        # fills through the wire layout they were written in, and dispatch
        # rb_w32_fd_is_text for libtfs token fds (the constants above:
        # dir.c/file.c/io.c for the io layer, prism_compile.c for the ruby
        # 3.4+ parser, io.c for the CRLF fd-is-text probe). The shared
        # build (issue #40) adds its own set: the DLL export fragment, the
        # mkexports rule appending it, and the miniruby import-lib
        # dependency.
        hotfix_msys!(ruby_source_dir, deps_lib_dir) if platform.msys?
        build_toolchain_stub(platform, deps_lib_dir, mount_point, cc, rv)
      end

      def postconfigure(ostype, ruby_source_dir, deps_lib_dir, ruby_ver)
        puts "-- Running postconfigure script"

        platform = TebakoRuntimeBuilder::Platform.new(ostype)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        # The gem gates the config.status substitution to ruby 3.3+ off msys
        # (Pass2NonMSysPatch); msys always substitutes (Pass2MSysPatch)
        return unless platform.msys? || rv.ruby33?

        mlibs_model = TebakoRuntimeBuilder::Mlibs.new(platform, deps_lib_dir)
        mlibs = mlibs_model.compute(rv, with_compression: false)
        # The msys shared build (issue #40) substitutes a second list:
        # SOLIBS feeds the ruby DLL's link (core objects + the libtfs
        # closure), MAINLIBS the exe/miniruby side.
        solibs = mlibs_model.compute_solibs(rv) if platform.msys?
        substitute_config_status!(File.join(ruby_source_dir, "config.status"), platform, mlibs, solibs)
      end

      def toolchain(ruby_source_dir, data_src_dir, stash_dir, deps_lib_dir) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
        puts "-- Running toolchain script"

        platform = TebakoRuntimeBuilder::Platform.new
        rbconfig = File.join(ruby_source_dir, "rbconfig.rb")
        install_out = nil
        # make install populates the packaging prefix; it does not clean it
        # first. A reused prefix (local rebuilds sharing --prefix across
        # rubies, a cache-restored deps tree on CI) would leak the previous
        # content into the image -- a full 3.3.0 stdlib tree once ended up
        # inside the 4.0.6 runtime image this way.
        FileUtils.rm_rf(data_src_dir, secure: true)
        FileUtils.mkdir_p(data_src_dir)
        Dir.chdir(ruby_source_dir) do
          run_make_with_serial_fallback(["make", "-j#{platform.ncores}"])
          # The pre-patched tool/mkconfig.rb bakes the memfs mount point into
          # the generated rbconfig.rb (ungated), which would send
          # 'make install' into /__tfs__ on the host (EROFS) and
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
          # DESTDIR= override: ruby 4.0's configure.ac seeds DESTDIR=$prefix
          # when load_relative=yes (forced on msys), and rbinstall's
          # with_destdir then prepends it to the already-absolute install
          # dirs, landing the whole tree in a shadow path
          # (o/s/a/tebako-.../o/s/...). Forcing DESTDIR empty restores the
          # pass-through; it is a no-op where DESTDIR was already empty
          # (3.x everywhere, 4.0 POSIX).
          install_out = TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["make", "install", "-j1", "DESTDIR="])
        end

        puts "   ... saving pristine Ruby environment to #{stash_dir}"
        FileUtils.rm_rf(stash_dir, secure: true)
        FileUtils.mkdir_p(stash_dir)
        FileUtils.cp_r "#{data_src_dir}/.", stash_dir
        bin = File.join(data_src_dir, "bin")
        installed = Dir.exist?(bin) ? Dir.children(bin).first(8).join(", ") : "(no bin dir)"
        puts "   ... toolchain installed: #{installed}"
        unless Dir.exist?(bin)
          # make install exited 0 yet installed nothing -- dump the evidence
          puts "   ... #{data_src_dir} top level: #{Dir.children(data_src_dir).join(", ")}"
          puts "   ... captured 'make install' section headers:"
          puts install_out.lines.grep(/installing|Installed|skipping|skipped|unknown install|error|cannot/i).first(80)
          puts "   ... rewritten rbconfig prefix lines:"
          puts File.readlines(rbconfig).grep(/CONFIG\["prefix"\]|CONFIG\["RUBY_EXEC_PREFIX"\]|DESTDIR =/)
        end

        # The stub driver served the toolchain link; the final relink must
        # resolve -ltebako-fs to the real library in the CMake binary dir.
        # On msys the pass-2 overlay build still links against the stub, so
        # it is removed by the finalize pass there instead.
        FileUtils.rm_f(File.join(deps_lib_dir, "libtebako-fs.a")) unless platform.msys?
      end

      # msys two-pass flow: overlay the pass-2 source tree (carrying the
      # final-build GNUmakefile.in variant) onto the built pass-1 tree,
      # replicating the gem's "pass2 patches onto the same tree" semantics
      # without re-deriving the pass split. Only files whose content differs
      # (today: cygwin/GNUmakefile.in alone) are replaced -- fresh mtimes, so
      # make regenerates exactly what the pass change affects; pass-1 build
      # artifacts (objects, the generated implib/exp/def files) are left
      # alone. The tarball hash is re-verified before extraction.
      def overlay(pass2_tarball, pass2_sha256, ruby_source_dir, work_dir)
        puts "-- Running overlay script (msys pass-2 tree)"

        # RUBY_TARBALL_P2 arrives in ExternalProject URL form (file://...)
        path = pass2_tarball.sub(%r{\Afile://}, "")
        verify_tarball!(path, pass2_sha256)
        root = extract_overlay(path, work_dir)
        puts "   ... overlaid #{overlay_differing_files(root, ruby_source_dir)} pass-2 file(s) onto #{ruby_source_dir}"
      end

      def deploy(ruby_ver, stash_dir, data_src_dir, data_pre_dir, data_bin_file, stub_dir, deps_bin_dir, # rubocop:disable Metrics/ParameterLists
                 mount_point:, embed: true)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        platform = TebakoRuntimeBuilder::Platform.new
        TebakoRuntimeBuilder::ImageBuilder.new(platform, rv, stash_dir, data_src_dir, data_pre_dir,
                                               data_bin_file, deps_bin_dir, mount_point: mount_point,
                                               embed: embed).build(stub_dir)
      end

      def finalize(ostype, ruby_source_dir, output, ruby_ver, deps_lib_dir, patchelf = nil) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/ParameterLists
        puts "-- Running finalize script"

        platform = TebakoRuntimeBuilder::Platform.new(ostype)
        rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_ver)
        rbconfig = File.join(ruby_source_dir, "rbconfig.rb")
        # Drop the stub driver (the toolchain pass removed it already
        # everywhere except msys): the relink must resolve -ltebako-fs to the
        # real library in the CMake binary dir
        FileUtils.rm_f(File.join(deps_lib_dir, "libtebako-fs.a"))
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
        stage_ruby_dll(rv, ruby_source_dir, output) if platform.msys?
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

      # The msys hot-patch set the prepare pass applies (the constants
      # above): the dir.c glob_opendir guard, the io.c rb_w32_fd_is_text
      # dispatch, and the shared-build set (issue #40) -- the DLL export
      # fragment, the mkexports rule appending it, and the miniruby
      # import-lib dependency. (The struct stat wire-layout reads are GONE:
      # the released source carries the pinned tebako_stat ABI — stat64
      # layout — from tamatebako/ruby v0.2.13, so there is nothing left to
      # re-read.)
      def hotfix_msys!(ruby_source_dir, deps_lib_dir)
        hotfix_msys_glob_opendir!(File.join(ruby_source_dir, "dir.c"))
        hotfix_msys_fd_is_text!(File.join(ruby_source_dir, "io.c"))
        write_dll_exports_fragment!(ruby_source_dir, deps_lib_dir)
        hotfix_msys_dll_exports!(File.join(ruby_source_dir, "cygwin", "GNUmakefile.in"))
        hotfix_msys_miniruby_dep!(File.join(ruby_source_dir, "common.mk"))
      end

      # Guard the dir.c glob_opendir() capacity hint against libtfs dir
      # handles (MSYS_GLOB_OPENDIR_ANCHOR / MSYS_GLOB_OPENDIR_GUARDED above).
      # Idempotent like substitute_tebako_mlibs!: the msys pass-2 overlay
      # re-runs prepare over an already-guarded tree. Fails loudly when the
      # tree matches neither the guard nor exactly one anchor -- that is the
      # signal the released pre-patched source changed (the fix landed in
      # tamatebako/ruby, or the upstream line moved) and this hot-patch must
      # be revisited.
      def hotfix_msys_glob_opendir!(dir_c) # rubocop:disable Metrics/MethodLength
        unless File.exist?(dir_c)
          raise TebakoRuntimeBuilder::Error.new("Could not patch #{dir_c} because it does not exist.", 107)
        end

        contents = File.read(dir_c)
        return if contents.include?(MSYS_GLOB_OPENDIR_GUARDED)

        anchor_count = contents.scan(MSYS_GLOB_OPENDIR_ANCHOR).length
        unless anchor_count == 1
          raise TebakoRuntimeBuilder::Error.new(
            "#{dir_c}: expected exactly one glob_opendir capacity-hint anchor, found #{anchor_count} -- " \
            "the pre-patched dir.c changed; revisit the msys glob_opendir hot-patch", 130
          )
        end

        puts "   ... guarding dir.c glob_opendir capacity hint against libtfs dir handles (msys)"
        File.write(dir_c, contents.sub(MSYS_GLOB_OPENDIR_ANCHOR, MSYS_GLOB_OPENDIR_GUARDED))
      end

      # Dispatch rb_w32_fd_is_text for libtfs token fds through
      # tebako_fd_is_embedded (MSYS_FD_IS_TEXT_* above). Same shape as the
      # other msys hot-patches: idempotent on re-run (the msys pass-2
      # overlay re-runs prepare), loud when the anchor drifts (the
      # pre-patched source changed -- the fix landed in tamatebako/ruby, or
      # the macro block moved). Every msys scenario tree carries the io.c
      # shim block the anchor lives in.
      def hotfix_msys_fd_is_text!(io_c) # rubocop:disable Metrics/MethodLength
        unless File.exist?(io_c)
          raise TebakoRuntimeBuilder::Error.new("Could not patch #{io_c} because it does not exist.", 107)
        end

        contents = File.read(io_c)
        return if contents.include?(MSYS_FD_IS_TEXT_MARKER)
        return unless contents.include?("tfs_close")

        anchor_count = contents.scan(MSYS_FD_IS_TEXT_ANCHOR).length
        unless anchor_count == 1
          raise TebakoRuntimeBuilder::Error.new(
            "#{io_c}: expected exactly one fd dispatch macro anchor, found #{anchor_count} -- " \
            "the pre-patched io.c changed; revisit the msys rb_w32_fd_is_text hot-patch", 130
          )
        end

        puts "   ... dispatching rb_w32_fd_is_text through tebako_fd_is_embedded in io.c (msys)"
        File.write(io_c, contents.sub(MSYS_FD_IS_TEXT_ANCHOR, MSYS_FD_IS_TEXT_REPLACEMENT))
      end

      # The DLL export fragment (issue #40): the tebako_* definitions of the
      # libtfs archive the DLL links (the scoped Rust libtfs.a of the staged
      # link unit, else the C++ libtfs of the deps provisioning), written as
      # a .def fragment the mkexports rule appends to the generated
      # x64-ucrt-ruby<ABI>.def. Derived by nm at prepare time -- a hand list
      # would drift against the link unit silently. Functions go bare, data
      # symbols with the DATA keyword (PE imports of data need it).
      def write_dll_exports_fragment!(ruby_source_dir, deps_lib_dir) # rubocop:disable Metrics/MethodLength
        archive = dll_export_source_archive(deps_lib_dir)
        out = TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["nm", "-g", "--defined-only", archive])
        lines = out.lines.filter_map do |line|
          fields = line.split
          next unless fields.length >= 3

          type = fields[-2]
          # COFF x64 names carry no prefix; the leading underscore is the
          # i386 PE (and mach-O) decoration -- normalize before matching
          name = fields[-1].delete_prefix("_")
          next unless name.start_with?("tebako_")

          case type.upcase
          when "T", "W" then name
          when "D", "B", "C", "R", "S", "V" then "#{name} DATA"
          end
        end.uniq.sort
        if lines.empty?
          raise TebakoRuntimeBuilder::Error.new(
            "#{archive} defines no tebako_* symbols -- the link unit drifted; " \
            "the ruby DLL would export no tebako_fs_* surface (issue 40)", 130
          )
        end

        path = File.join(ruby_source_dir, MSYS_DLL_EXPORTS_FRAGMENT)
        puts "   ... writing the DLL export fragment (#{lines.length} tebako_* symbols from #{File.basename(archive)})"
        File.write(path, "#{lines.join("\n")}\n")
      end

      # The libtfs archive whose tebako_* surface the DLL exports: the
      # staged Rust link unit's (TEBAKO_RUST_LIBDIR, normalized like
      # Mlibs#rust_libdir -- the workflow passes a Windows-form path), else
      # the deps provisioning's C++ libtfs.a (the v1 link).
      def dll_export_source_archive(deps_lib_dir)
        rust_libdir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)&.tr('\\', "/")
        candidates = []
        candidates << File.join(rust_libdir, "libtfs.a") if rust_libdir && !rust_libdir.empty?
        candidates << File.join(deps_lib_dir, "libtfs.a")
        archive = candidates.find { |path| File.file?(path) }
        return archive if archive

        raise TebakoRuntimeBuilder::Error.new(
          "no libtfs.a to derive the DLL export fragment from (tried: #{candidates.join(", ")}) -- " \
          "stage the link unit (TEBAKO_RUST_LIBDIR) or let the libtfs provisioning deploy", 112
        )
      end

      # Append the fragment to the mkexports .def generation rule in
      # cygwin/GNUmakefile.in (MSYS_DLL_EXPORTS_* above). Same shape as the
      # other msys hot-patches: idempotent on re-run (the pass-2 overlay
      # replaces GNUmakefile.in and prepare re-runs), loud when the anchor
      # drifts (the released pre-patched source changed).
      def hotfix_msys_dll_exports!(gnu_makefile_in) # rubocop:disable Metrics/MethodLength
        unless File.exist?(gnu_makefile_in)
          raise TebakoRuntimeBuilder::Error.new("Could not patch #{gnu_makefile_in} because it does not exist.", 107)
        end

        contents = File.read(gnu_makefile_in)
        return if contents.include?(MSYS_DLL_EXPORTS_FRAGMENT)

        anchor_count = contents.scan(MSYS_DLL_EXPORTS_ANCHOR).length
        unless anchor_count == 1
          raise TebakoRuntimeBuilder::Error.new(
            "#{gnu_makefile_in}: expected exactly one mkexports rule anchor, found #{anchor_count} -- " \
            "the pre-patched GNUmakefile.in changed; revisit the msys DLL exports hot-patch (issue 40)", 130
          )
        end

        puts "   ... appending the tebako_* export fragment to the mkexports rule (msys, issue 40)"
        File.write(gnu_makefile_in, contents.sub(MSYS_DLL_EXPORTS_ANCHOR, MSYS_DLL_EXPORTS_PATCHED))
      end

      # Make miniruby's link depend on $(LIBRUBY) (MSYS_MINIRUBY_DEP_*
      # above): in the shared build miniruby binds tebako_fs_* from the
      # DLL's import library, a byproduct of the DLL link -- without the
      # dependency a parallel make can link miniruby first. Idempotent,
      # anchored, loud on drift (same contract as the other hot-patches;
      # common.mk is identical in both pass trees, so the pass-2 overlay
      # leaves the patch in place and the re-run is a no-op).
      def hotfix_msys_miniruby_dep!(common_mk) # rubocop:disable Metrics/MethodLength
        unless File.exist?(common_mk)
          raise TebakoRuntimeBuilder::Error.new("Could not patch #{common_mk} because it does not exist.", 107)
        end

        contents = File.read(common_mk)
        return if contents.include?(MSYS_MINIRUBY_DEP_PATCHED)

        anchor_count = contents.scan(MSYS_MINIRUBY_DEP_ANCHOR).length
        unless anchor_count == 1
          raise TebakoRuntimeBuilder::Error.new(
            "#{common_mk}: expected exactly one miniruby dependency anchor, found #{anchor_count} -- " \
            "the pre-patched common.mk changed; revisit the msys miniruby dependency hot-patch (issue 40)", 130
          )
        end

        puts "   ... making miniruby depend on the ruby DLL import library (msys, issue 40)"
        File.write(common_mk, contents.sub(MSYS_MINIRUBY_DEP_ANCHOR, MSYS_MINIRUBY_DEP_PATCHED))
      end

      def substitute_config_status!(config_status, platform, mlibs, solibs = nil) # rubocop:disable Metrics/MethodLength
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
        puts "Warning: no config.status MAINLIBS pattern matched; the substitution did not happen" unless substituted

        # The msys shared build (issue #40): SOLIBS feeds the ruby DLL's
        # link. configure writes S["SOLIBS"]="$(MAINLIBS)"; the substitution
        # rewrites the line wholesale (key-anchored, idempotent) so the
        # closure never lands in the exe side's MAINLIBS by reference.
        substitute_solibs!(contents, solibs) if solibs
        File.write(config_status, contents)
        nil
      end

      def substitute_solibs!(contents, solibs)
        puts "   ... substituting SOLIBS (the ruby DLL closure, issue 40)"
        subst = "S[\"SOLIBS\"]=\"#{solibs}\""
        done = contents.include?(subst) || !contents.sub!(%r{^S\["SOLIBS"\]=.*$}, subst).nil?
        puts "Warning: no config.status SOLIBS line matched; the DLL closure substitution did not happen" unless done
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
      def build_toolchain_stub(platform, deps_lib_dir, mount_point, cc, ruby_ver) # rubocop:disable Metrics/MethodLength
        puts "   ... building the toolchain stub libtebako-fs.a"
        FileUtils.mkdir_p(deps_lib_dir)
        obj = File.join(deps_lib_dir, "tebako-toolchain-stub.o")
        lib = File.join(deps_lib_dir, "libtebako-fs.a")
        defines = ["-DTEBAKO_STUB_MOUNT_POINT=\"#{mount_point}\""]
        # ruby >= 3.3 defines rb_w32_pread in win32.c; only the older msys
        # lines need the stub's fallback
        defines << "-DRB_W32_PRE_33" if platform.msys? && !ruby_ver.ruby33?
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(
          [cc, "-c", TOOLCHAIN_STUB_C, *defines, "-o", obj]
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

      def verify_tarball!(tarball, sha256)
        actual = Digest::SHA256.file(tarball).hexdigest
        return if actual == sha256

        raise TebakoRuntimeBuilder::Error.new(
          "#{File.basename(tarball)}: expected SHA256 #{sha256}, got #{actual}", 121
        )
      end

      def extract_overlay(pass2_tarball, work_dir)
        overlay_src = File.join(work_dir, "overlay-src")
        FileUtils.rm_rf(overlay_src, secure: true)
        FileUtils.mkdir_p(overlay_src)
        # GNU tar parses 'D:/...' as a remote host on msys; use the /d/...
        # form there
        args = ["tar", "-xzf", msys_tar_path(pass2_tarball), "-C", msys_tar_path(overlay_src)]
        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(args)
        root = Dir.children(overlay_src).map { |child| File.join(overlay_src, child) }
                                        .find { |path| File.directory?(path) }
        raise TebakoRuntimeBuilder::Error.new("overlay tarball carries no source tree", 130) if root.nil?

        root
      end

      def msys_tar_path(path)
        return path unless TebakoRuntimeBuilder::Platform.new.msys?

        TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["cygpath", "-u", path]).strip
      end

      def overlay_differing_files(root, ruby_source_dir)
        replaced = 0
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |src|
          next unless File.file?(src)

          dest = File.join(ruby_source_dir, src.delete_prefix("#{root}/"))
          next if File.file?(dest) && FileUtils.compare_file(src, dest)

          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(src, dest)
          replaced += 1
        end
        replaced
      end

      # msys only (issue #40): stage the ruby DLL the shared build just
      # linked next to the runtime executable, under the PACKAGE's name
      # (<runtime>.dll -- unique per leg: two same-ABI legs share the PE
      # name x64-ucrt-ruby<ABI>.dll and would collide in the merged release
      # workspace). The PE-named file the exe's imports resolve is
      # materialized next to the exe by whoever runs it (the boot smoke
      # does it in-leg; the store entry does it at install time -- the
      # manifest's dll.install_as flows the name). Exactly one DLL must
      # exist in the build tree -- none means the --enable-shared build
      # regressed, several means a stale tree; a differently named one
      # means ruby configure's RUBY_SO_NAME moved (update
      # RubyVersion#msys_dll_name, its single owner in the factory).
      def stage_ruby_dll(ruby_ver, ruby_source_dir, output) # rubocop:disable Metrics/MethodLength
        candidates = Dir.glob(File.join(ruby_source_dir, "x64-*-ruby*.dll"))
        expected = ruby_ver.msys_dll_name
        unless candidates.length == 1 && File.basename(candidates.first) == expected
          raise TebakoRuntimeBuilder::Error.new(
            "expected the shared build's #{expected} under #{ruby_source_dir}, found " \
            "#{candidates.map { |p| File.basename(p) }.join(", ").then { |s| s.empty? ? "no ruby DLL" : s }} " \
            "(issue 40)", 130
          )
        end

        dest = "#{output.sub(/\.exe\z/, "")}.dll"
        TebakoRuntimeBuilder::Stripper.strip_file(candidates.first, dest)
        puts "Created tebako runtime ruby DLL at \"#{dest}\" (installs as #{expected})"
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
