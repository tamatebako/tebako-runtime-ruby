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

module TebakoRuntimeBuilder
  # The tebako static library list substituted into the ruby build
  # (MAINLIBS) -- a faithful port of the gem's PatchLibraries.mlibs.
  #
  # The pre-patched ruby source carries the literal placeholder
  # '@TEBAKO_MLIBS@' in template/Makefile.in (and the deferred config.status
  # MAINLIBS patch); the list is computed dynamically per packaging host,
  # which is exactly why it stays a consumer-side substitution.
  #
  # msys is the shared build (issue #40): TWO lists, one per PE module.
  # MAINLIBS (the exe/miniruby side) carries the driver, the import library
  # of x64-ucrt-ruby<ABI>.dll and the static-ext/system deps -- never the
  # libtfs closure. compute_solibs (the DLL side, substituted into SOLIBS)
  # carries the closure: the memfs mount table exists exactly once per
  # process, in the DLL, and the exe's driver reaches it through the DLL's
  # exports (two static copies would hand driver and ruby separate mount
  # tables -- mounts invisible to the interpreter).
  class Mlibs # rubocop:disable Metrics/ClassLength
    # rubocop:disable Style/WordArray
    DARWIN_BREW_LIBS = [
      ["zlib", "z"],              ["gdbm", "gdbm"],           ["readline", "readline"], ["libffi", "ffi"],
      ["ncurses", "ncurses"],     ["lz4", "lz4"],             ["xz", "lzma"],           ["libyaml", "yaml"]
    ].freeze

    DARWIN_BREW_LIBS_PRE_31 = [["openssl@1.1", "ssl"], ["openssl@1.1", "crypto"]].freeze

    DARWIN_BREW_LIBS_31 = [["openssl@3", "ssl"], ["openssl@3", "crypto"]].freeze

    DARWIN_DEP_LIBS_1 = ["tfs"].freeze
    # Referenced by full path from the vcpkg triplet lib dir (see
    # darwin_libraries): Apple ld does not implement the GNU-style
    # -l:<filename> library search, so -l:libX.a refs do not resolve.
    DARWIN_DEP_LIBS_2 = ["dwarfs_reader", "dwarfs_common", "dwarfs_metadata_legacy",
                         "dwarfs_decompressor", "flatbuffers", "zip",
                         "fmt", "xxhash", "zstd",
                         "brotlidec", "brotlienc", "brotlicommon",
                         "bz2", "boost_filesystem", "boost_chrono"].freeze
    # rubocop:enable Style/WordArray

    # --start-group/--end-group around the libtfs + transitive static archives:
    # the dwarfs reader set has circular member-level references that trip GNU
    # ld's single-pass scanning when built with clang (compression registrar).
    # libtfs.a (v0.13.0: the legacy API is removed and the former pure-C
    # dirent helper is merged in) and the transitive static set resolved by
    # vcpkg into deps/vcpkg_installed/<triplet>/lib: the dwarfs reader side,
    # flatbuffers, zip and the C++ support libs.
    # Compression codecs register explicitly (compression_registry ctor),
    # so no --whole-archive compression lib is needed anymore.
    COMMON_LINUX_LIBRARIES = [
      "-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state",
      "-l:libtfs.a",
      "-l:libdwarfs_reader.a", "-l:libdwarfs_common.a", "-l:libdwarfs_metadata_legacy.a",
      "-l:libdwarfs_decompressor.a", "-l:libflatbuffers.a", "-l:libzip.a",
      "-l:libfmt.a", "-l:libxxhash.a", "-l:libboost_filesystem.a",
      "-l:libboost_chrono.a"
    ].freeze

    COMMON_ARCHIEVE_LIBRARIES = [
      "-l:liblz4.a",           "-l:libz.a",         "-l:libzstd.a",
      "-l:libbrotlienc.a",     "-l:libbrotlidec.a", "-l:libbrotlicommon.a",
      "-l:liblzma.a",          "-l:libbz2.a"
    ].freeze

    LINUX_GNU_LIBRARIES = [
      "-l:libacl.a", "-l:libssl.a", "-l:libcrypto.a",
      "-l:libgdbm.a",        "-l:libreadline.a",     "-l:libtinfo.a",         "-l:libffi.a",
      "-l:libncurses.a",     "-l:libjemalloc.a",     "-l:libcrypt.a",         "-l:libanl.a",
      "LIBYAML",             "-l:libutil.a",
      "-l:libstdc++.a",      "-lgcc_eh",             "-l:liblzma.a",
      "-l:librt.a",          "-ldl",                 "-lpthread", "-lm"
    ].freeze

    LINUX_MUSL_LIBRARIES = [
      "-l:libacl.a",          "-l:libssl.a",          "-l:libcrypto.a",
      "-l:libreadline.a",     "-l:libgdbm.a",         "-l:libffi.a", "-l:libncurses.a",
      "-l:libjemalloc.a",     "-l:libcrypt.a",        "LIBYAML",
      "-l:librt.a",           "-l:libstdc++.a",       "-lgcc_eh",
      "-l:liblzma.a",         "-ldl", "-lpthread"
    ].freeze

    MSYS_LIBRARIES = [
      "-l:liblz4.a",             "-l:libz.a",               "-l:libzstd.a",            "-l:liblzma.a",
      "-l:libncurses.a",         "-l:liblzma.a",            "-l:libiberty.a",          "LIBYAML",
      "-l:libffi.a",             "-l:libstdc++.a",          "-l:libdl.a",
      "-static-libgcc",          "-static-libstdc++",       "-l:libssl.a",             "-l:libcrypto.a",
      "-l:libz.a",               "-l:libwinpthread.a",      "-lcrypt32",               "-lshlwapi",
      "-lwsock32",               "-liphlpapi",              "-limagehlp",              "-lbcrypt",
      "-lwsock32",               "-liphlpapi",              "-limagehlp",              "-lbcrypt",
      "-lole32",                 "-loleaut32",              "-luuid",                  "-lws2_32",
      "-lpsapi"
    ].freeze

    # The libtfs-deps windows package ships the boost static libs under
    # toolset/version-tagged names (libboost_filesystem-gcc16-mt-x64-1_90.a),
    # so the plain -l:libboost_*.a references in COMMON_LINUX_LIBRARIES do
    # not resolve on msys; they are globbed by full path instead (darwin
    # style) to stay independent of the tag drift
    MSYS_BOOST_LIBS = %w[boost_filesystem boost_chrono].freeze

    # The DLL side's system libraries and runtimes (msys shared build,
    # issue #40): ruby's win32 layer (the win32 default library set) plus
    # the Rust/dwarfs closure's references (proven by
    # the mingw-ld link probes: RtlNtStatusToDosError → ntdll,
    # GetUserProfileDirectoryW → userenv, GetProcessMemoryInfo → psapi) and
    # the C++ runtime, statically — several mingw installs on a runner make
    # DLL resolution nondeterministic otherwise.
    MSYS_DLL_LIBRARIES = [
      "-l:libstdc++.a",          "-static-libgcc",            "-static-libstdc++",       "-l:libwinpthread.a",
      "-lshell32",               "-lws2_32",                  "-lwsock32",               "-liphlpapi",
      "-limagehlp",              "-lshlwapi",                 "-lbcrypt",                "-lcrypt32",
      "-ladvapi32",              "-luser32",                  "-lole32",                 "-loleaut32",
      "-luuid",                  "-lpsapi",                   "-lntdll",                 "-luserenv"
    ].freeze

    # The pacman-provided archives rust_link_libraries_msys dedupes OUT of
    # the closure (they ride the exe's MSYS_LIBRARIES): the DLL link shares
    # no libraries with the exe link, so the closure's own zlib/lzma/openssl
    # references need the pacman copies here. The extension deps ride too —
    # fiddle's libffi, dl's dlfcn, psych's libyaml — STATICALLY: a dynamic
    # reference makes the DLL unloadable on a bare windows machine (the
    # 0.16.3 defect: libdl.dll/libffi-8.dll/libyaml-0-2.dll imports → exit
    # 127 everywhere outside an msys2 install). Static archives cost
    # nothing when unreferenced (no members get pulled).
    MSYS_DLL_PACMAN_PROVIDERS = ["-l:libz.a", "-l:liblzma.a", "-l:libssl.a", "-l:libcrypto.a",
                                 "-l:libffi.a", "-l:libdl.a", "LIBYAML"].freeze

    # prefix_resolver maps a Homebrew package name to its prefix (darwin);
    # injectable so the list computation is spec-able off macOS
    def initialize(platform, deps_lib_dir, prefix_resolver: nil)
      @platform = platform
      @deps_lib_dir = deps_lib_dir
      @prefix_resolver = prefix_resolver || platform.method(:brew_prefix)
    end

    # with_compression mirrors the gem's mlibs flag (only the msys list
    # reacts to it): true for the template/Makefile.in substitution, false
    # for the config.status one
    def compute(ruby_ver, with_compression: true)
      if @platform.msys?
        msys_libraries(ruby_ver, with_compression)
      elsif @platform.macos?
        darwin_libraries(ruby_ver)
      elsif @platform.musl?
        linux_musl_libraries(ruby_ver, with_compression)
      else
        linux_gnu_libraries(ruby_ver, with_compression)
      end
    end

    # SOLIBS of the msys shared build (issue #40): the DLL side, substituted
    # into config.status by build_pass.rb postconfigure. x64-ucrt-ruby<ABI>.dll
    # links the ruby core objects + the scoped DRIVER + libtfs.a + the
    # closure: the driver mounts through its bundled tfs instance, and the
    # c_api's context unifies with it only inside ONE link -- so the whole
    # tebako side (driver + tfs + closure) lives in the DLL and the process
    # holds exactly one mount table, the static exe's semantics preserved.
    # The exe keeps only the fs TU shim (MAINLIBS). The export surface is
    # the mkexports .def plus the tebako_* fragment build_pass.rb prepare
    # appends (libtfs.a and libtebako_driver.a both feed it).
    def compute_solibs(ruby_ver)
      libraries = ["-Wl,--start-group"] +
                  msys_driver_libraries +
                  msys_closure_libraries +
                  ["-Wl,--end-group"] +
                  MSYS_DLL_PACMAN_PROVIDERS +
                  MSYS_DLL_LIBRARIES
      linux_libraries(libraries, ruby_ver, false)
    end

    # MINILIBS of the msys shared build (issue #40): miniruby's FULL static
    # library set (driver + closure + system deps, exactly the pre-shared
    # MAINLIBS composition), substituted into template/Makefile.in by
    # build_pass.rb prepare as TEBAKO_MINILIBS. miniruby carries its own
    # private closure copy -- a separate build-tool process, never mounted,
    # and acyclic by construction (builtin_binary.inc is generated BY
    # miniruby and feeds the DLL's objects: a miniruby -> DLL edge would be
    # a dependency cycle).
    # MINILIBS of the msys shared build (issue #40): miniruby's FULL static
    # library set, substituted into template/Makefile.in by build_pass.rb
    # prepare as TEBAKO_MINILIBS. miniruby carries its own private closure
    # copy -- a separate build-tool process, never mounted, and acyclic by
    # construction (builtin_binary.inc is generated BY miniruby and feeds
    # the DLL's objects: a miniruby -> DLL edge would be a dependency
    # cycle).
    #
    # The v2 (Rust driver) stub entry is the whole-archive MINIMAL stub:
    # main.c references tebako_main and the driver's own tebako_main is NOT
    # a C export (ffi.rs: no #[no_mangle] -- "NOT a C export ... the symbol
    # belongs to the runtime factory's generated fs TU", so the archive
    # holds only the mangled name and C code cannot bind it). The minimal
    # stub provides exactly that one symbol and nothing else, so nothing in
    # it can collide with the driver archive (the ld multiple-definition
    # failures: first the compat getters, then tebako_mount_point). The v1
    # (C++ driver) list's whole-archive stub is the FULL (weak) one -- the
    # only tebako definitions in that link.
    def compute_minilibs(ruby_ver)
      libraries = ["-Wl,--start-group"] +
                  msys_miniruby_stub +
                  msys_driver_libraries +
                  msys_closure_libraries +
                  ["-Wl,--end-group"] +
                  MSYS_LIBRARIES +
                  ["-lntdll", "-luserenv"]
      linux_libraries(libraries, ruby_ver, false)
    end

    private

    def linux_gnu_libraries(ruby_ver, with_compression)
      libraries = linux_libraries_base(rust_libdir ? LINUX_GNU_LIBRARIES : nil) ||
                  (["-Wl,--start-group"] + COMMON_LINUX_LIBRARIES + COMMON_ARCHIEVE_LIBRARIES +
                  ["-Wl,--end-group"] + LINUX_GNU_LIBRARIES)
      linux_libraries(libraries, ruby_ver, with_compression)
    end

    def linux_musl_libraries(ruby_ver, with_compression)
      libraries = linux_libraries_base(rust_libdir ? LINUX_MUSL_LIBRARIES : nil) ||
                  (["-Wl,--start-group"] + COMMON_LINUX_LIBRARIES + COMMON_ARCHIEVE_LIBRARIES +
                  ["-Wl,--end-group"] + LINUX_MUSL_LIBRARIES)
      linux_libraries(libraries, ruby_ver, with_compression)
    end

    # The v2 link (image era): whole-archive libtebako-fs.a (the incbin
    # TU) + the sealed Rust objects + the closure archives — the C++
    # libtfs and its dwarfs/codec closure ride in the sealed unit.
    # Returns nil for the v1 path.
    # The trailing -l:libz.a: ruby's own zlib need (addr2line's
    # uncompress, the zlib ext) plus librnp's pgp compression refs at
    # the exe link. v1 covered it via COMMON_ARCHIEVE_LIBRARIES; the
    # gated dwarfs manifest ships no zlib at all (tebako-rs 1411fc2),
    # so the platform tail adds it back — focal's zlib1g-dev and
    # alpine's zlib-static, both already carried by the build images
    # (gnu slice 30736892551: miniruby's link died on 'uncompress').
    def linux_libraries_base(platform_libraries)
      return nil if platform_libraries.nil?

      covered = linux_covered(platform_libraries)
      libs = rust_link_libraries.reject { |path| covered.include?(File.basename(path)) }
      ["-Wl,--start-group",
       "-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state"] +
        libs +
        ["-Wl,--end-group"] + platform_libraries + ["-l:libz.a"]
    end

    # The closure archives the platform set already covers, by basename
    # (the msys pacman_covered class): two copies of one library in one
    # link is a duplicate-definition failure whenever both get pulled —
    # the closure's libjemalloc.a vs the image's own (gnu slice
    # 30738214135); libssl/libcrypto/liblzma are the same latent pair
    # (the libtfs-deps provisioning puts them in the deps lib dir, and
    # ruby's ext/openssl compiles against exactly those headers, so the
    # platform copy is also the better-matched one).
    def linux_covered(platform_libraries)
      platform_libraries.filter_map { |lib| lib[/^-l:(lib.+\.a)$/, 1] } + ["libz.a"]
    end

    def linux_libraries(libraries, ruby_ver, _with_compression)
      libraries.map! do |lib|
        lib == "LIBYAML" ? yaml_reference(ruby_ver) : lib
      end
      libraries.join(" ")
    end

    # MAINLIBS of the msys shared build (issue #40): the exe side. The fs
    # TU (PLAIN -l:libtebako-fs.a, never --whole-archive: the exe
    # references only the archive's tebako_main shim, and a whole-archive
    # pull drags the toolchain stub's compat getters (tebako_original_pwd,
    # tebako_is_running_miniruby) into the link on top of the same symbols
    # the DLL's import archive already bound -- the ld multiple-definition
    # failure on the 3.3.12/4.0.6 legs) + the static-ext/system deps. NO
    # import-library literal: the exe recipes name it via LIBRUBYARG
    # already, and a bare libx64-ucrt-ruby<ABI>.dll.a in MAINLIBS lands in
    # every mkmf conftest link -- the import library is deleted-and-rewritten
    # on each DLL relink (the rbconfig rewrites relink it three times a
    # build), and a probe reading it in that window fails and marks the ext
    # broken for good (the 4.0.6 ext/openssl 'cannot find
    # libx64-ucrt-ruby400.dll.a' class). The driver is NOT here -- it rides
    # the DLL (compute_solibs): the driver mounts through its OWN bundled
    # tfs instance, which unifies with the c_api's context only when driver
    # and libtfs.a share one link (the static exe's shape); split across
    # two PE modules the driver mounts into the exe-side context while
    # ruby's io routing reads the DLL's empty one -- A:/__tfs__ falls
    # through to the host and touching the unmapped A: drive hangs the
    # process silently (proven on the 3.3.12/4.0.6 legs).
    def msys_libraries(ruby_ver, with_compression)
      libraries = with_compression ? ["-Wl,-Bstatic"] : []
      libraries += ["-Wl,--start-group",
                    "-l:libtebako-fs.a"] +
                   ["-Wl,--end-group"] +
                   MSYS_LIBRARIES +
                   # Rust std's Windows references the dwarfs closure
                   # does not cover (proven by the mingw-ld link probe):
                   # RtlNtStatusToDosError (ntdll) and
                   # GetUserProfileDirectoryW (userenv).
                   ["-lntdll", "-luserenv"]
      linux_libraries(libraries, ruby_ver, with_compression)
    end

    # The scoped libtebako_driver.a of the v2 (Rust driver) link, for the
    # DLL (compute_solibs) and for miniruby (compute_minilibs); the v1
    # (C++ driver) link has no such archive.
    def msys_driver_libraries
      return [] unless rust_libdir

      [File.join(rust_libdir, "libtebako_driver.a")].tap do |libs|
        libs.each do |path|
          next if File.file?(path)

          raise TebakoRuntimeBuilder::Error.new(
            "missing v2 link input: #{path} — run tebako-arscope (tebako-rs) and stage the scoped staticlibs",
            112
          )
        end
      end
    end

    # miniruby's stub entry: the whole-archive stub in BOTH links -- the
    # FULL (weak) one in the v1 (C++ driver) link, the MINIMAL one
    # (tebako_main only) in the v2 (Rust driver) link. The driver's own
    # tebako_main is not a C export (no #[no_mangle] in ffi.rs), so the
    # stub is the only C-visible provider of it; the minimal content (v2)
    # is what keeps the stub's pull collision-free against the driver
    # archive.
    def msys_miniruby_stub
      ["-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state"]
    end

    # The closure archives that ride the DLL: the v2 scoped libtfs.a +
    # closure/*.a minus the exe's driver and minus the pacman-covered set
    # (re-added from pacman below); the v1 C++ libtfs + vcpkg set when no
    # Rust link unit is staged.
    def msys_closure_libraries
      return msys_solibs_rust if rust_libdir

      COMMON_LINUX_LIBRARIES.drop(1).map { |lib| msys_boost_reference(lib) } +
        COMMON_ARCHIEVE_LIBRARIES
    end

    def msys_solibs_rust
      rust_link_libraries_msys.reject { |lib| File.basename(lib) == "libtebako_driver.a" }
    end

    # The link unit minus the libraries pacman already covers for ruby:
    # openssl (ssl/crypto), zlib, and lzma all come statically from the
    # msys system set (MSYS_LIBRARIES), and two copies in one link is a
    # duplicate-definition failure. Everything else (the scoped
    # staticlibs, boost, codecs, jemalloc, flatbuffers, archive) rides.
    def rust_link_libraries_msys
      pacman_covered = %w[libssl.a libcrypto.a libz.a libzlib.a liblzma.a]
      rust_link_libraries.reject { |lib| pacman_covered.include?(File.basename(lib)) }
    end

    # Resolve the boost archive references in COMMON_LINUX_LIBRARIES to the
    # actual (tagged) file in the vcpkg triplet lib dir on msys; anything
    # else passes through unchanged. An unresolved boost ref falls back to
    # the plain -l: form so a genuine absence fails loudly at link time.
    def msys_boost_reference(lib)
      name = MSYS_BOOST_LIBS.find { |boost| lib == "-l:lib#{boost}.a" }
      return lib if name.nil?

      vcpkg_lib_dir = Dir.glob(File.join(@deps_lib_dir, "..", "vcpkg_installed", "*", "lib")).min
      candidate = Dir.glob(File.join(vcpkg_lib_dir.to_s, "lib#{name}*.a")).min
      candidate ? File.expand_path(candidate) : lib
    end

    def process_brew_libs!(libs, brew_libs)
      brew_libs.each { |lib| libs << "#{@prefix_resolver.call(lib[0])}/lib/lib#{lib[1]}.a " }
    end

    def darwin_libraries(ruby_ver) # rubocop:disable Metrics/AbcSize
      libs = String.new

      # The v2 link (image era): the sealed Rust driver + tfs objects
      # and the closure archives from the tebako-rs build (dwarfs-t,
      # squashfs, botan, rnp, codecs) — no C++ libtfs, no vcpkg closure.
      # The brew libs below stay: they are ruby's own dependencies (and
      # v1-proven to satisfy dwarfs-t's openssl references).
      libs << "#{rust_link_libraries.join(" ")} " if rust_libdir
      DARWIN_DEP_LIBS_1.each { |lib| libs << "#{@deps_lib_dir}/lib#{lib}.a " } unless rust_libdir
      process_brew_libs!(libs, ruby_ver.ruby31? ? DARWIN_BREW_LIBS_31 : DARWIN_BREW_LIBS_PRE_31)
      process_brew_libs!(libs, DARWIN_BREW_LIBS)

      unless rust_libdir
        # The vcpkg set by full path: Apple ld does not implement -l:<filename>
        vcpkg_lib_dir = Dir.glob(File.join(@deps_lib_dir, "..", "vcpkg_installed", "*", "lib")).min
        DARWIN_DEP_LIBS_2.each { |lib| libs << "#{vcpkg_lib_dir}/lib#{lib}.a " }
      end
      # No allocator link: brew's static libjemalloc.a crashes tebako
      # binaries at startup on the XCode 15.4 runners (je_arena_ralloc
      # SEGV at builtin init), and the dylib fails the test_101
      # no-shared-libs assertion. System malloc until a properly built
      # static jemalloc ships with libtfs-deps.
      # ld_classic: the cargo-bundled natives land in each staticlib
      # more than once (the same vcpkg objects ride several sys crates),
      # and Xcode 15+'s ld_prime asserts on the same-name atoms
      # ("malformed atom files with duplicate names",
      # atomShouldReplaceExisting) resolving the vague-linkage C++
      # template duplicates. GNU ld merges them first-wins and
      # ld_classic resolves them by the same ODR rule; only ld_prime
      # treats it as fatal. Proven locally against the staged unit
      # (pristine link-unit-macos-x86_64 + probe: ld_prime asserts,
      # ld_classic links). Keep until the staticlibs dedupe at the
      # source (arscope/cargo bundling).
      "-Wl,-ld_classic -ltebako-fs #{libs}-lc++ -lc++abi"
    end

    # The v2 link unit (image era): the two Rust staticlibs SCOPED to
    # the tebako_* surface by tebako-arscope (tebako-rs) plus the
    # closure archives. Scoping is mandatory: ruby's YJIT carries its
    # own rustc std into the same link, and two rustc stds collide on
    # rust_eh_personality/compiler-rt/mangled names — after scoping,
    # nothing but tebako_* is visible from our side. The factory never
    # invokes a linker on the archives itself: the scoped unit is
    # staged by tebako-rs (a release artifact, or a local
    # TEBAKO_RUST_LIBDIR with libtebako_driver.a + libtfs.a +
    # closure/*.a).
    def rust_link_libraries # rubocop:disable Metrics/MethodLength
      libs = %w[libtebako_driver.a libtfs.a].map do |name|
        path = File.join(rust_libdir, name)
        unless File.file?(path)
          raise TebakoRuntimeBuilder::Error.new(
            "missing v2 link input: #{path} — run tebako-arscope (tebako-rs) and stage the scoped staticlibs",
            112
          )
        end

        path
      end
      closure = Dir.glob(File.join(rust_libdir, "closure", "*.a"))
      if closure.empty?
        raise TebakoRuntimeBuilder::Error.new(
          "TEBAKO_RUST_LIBDIR (#{rust_libdir}) carries no closure/*.a — stage the scoped link unit first",
          112
        )
      end

      libs + closure
    end

    # The v2 link switch (image era): TEBAKO_RUST_LIBDIR names the
    # directory holding the scoped link unit (libtebako_driver.a +
    # libtfs.a + closure/*.a). Normalize separators: the workflow passes
    # a Windows-form path (D:\a\...), and Dir.glob treats '\' as an
    # escape character — the backslash form silently matches nothing
    # (proven on the windows 3.1.6 leg: 36 staged archives invisible).
    def rust_libdir
      dir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)
      dir&.tr("\\", "/") unless dir.to_s.empty?
    end

    # .....................................................
    #  Notes re linux libraries
    #   1) -lgcc_eh assumes -static-libgcc (applied in CMakeLists.ext, RUBY_C_FLAGS)
    #   2) -static-libstdc++ did not work, not sure why  [TODO ?]
    #   3) When clang is used linker links libraries specified in exensions in such way that they are linked shared
    #      (libz, libffi, libreadline, libncurses, libtinfo, ... )
    #      Using stuff like -l:libz.a  does not help; there is a reference to libz.so anyway.
    #      This is fixed by ext/extmk.rb patch [TODO ?]
    # .....................................................

    def yaml_reference(ruby_ver)
      ruby_ver.ruby32? ? "-l:libyaml.a" : ""
    end
  end
end
