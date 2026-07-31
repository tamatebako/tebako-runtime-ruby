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

    private

    def linux_gnu_libraries(ruby_ver, with_compression)
      libraries = linux_libraries_base(rust_libdir ? LINUX_GNU_LIBRARIES : nil) ||
                  ["-Wl,--start-group"] + COMMON_LINUX_LIBRARIES + COMMON_ARCHIEVE_LIBRARIES +
                  ["-Wl,--end-group"] + LINUX_GNU_LIBRARIES
      linux_libraries(libraries, ruby_ver, with_compression)
    end

    def linux_musl_libraries(ruby_ver, with_compression)
      libraries = linux_libraries_base(rust_libdir ? LINUX_MUSL_LIBRARIES : nil) ||
                  ["-Wl,--start-group"] + COMMON_LINUX_LIBRARIES + COMMON_ARCHIEVE_LIBRARIES +
                  ["-Wl,--end-group"] + LINUX_MUSL_LIBRARIES
      linux_libraries(libraries, ruby_ver, with_compression)
    end

    # The v2 link (image era): whole-archive libtebako-fs.a (the incbin
    # TU) + the sealed Rust objects + the closure archives — the C++
    # libtfs and its dwarfs/codec closure ride in the sealed unit.
    # Returns nil for the v1 path.
    def linux_libraries_base(platform_libraries)
      return nil if platform_libraries.nil?

      ["-Wl,--start-group",
       "-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state"] +
        rust_link_libraries +
        ["-Wl,--end-group"] + platform_libraries
    end

    def linux_libraries(libraries, ruby_ver, _with_compression)
      libraries.map! do |lib|
        lib == "LIBYAML" ? yaml_reference(ruby_ver) : lib
      end
      libraries.join(" ")
    end

    def msys_libraries(ruby_ver, with_compression)
      if rust_libdir
        # The v2 link (image era), msys flavor: the scoped staticlibs +
        # the mingw closure inside a group (GNU ld's single-pass scan
        # needs it for the circular member refs), with the pacman-covered
        # deps deduped — ruby statically links openssl/zlib/lzma from
        # pacman, and the vcpkg closure's copies of those must not
        # collide with them (same ABI line; the group's own references
        # resolve against the pacman set that follows).
        libraries = with_compression ? ["-Wl,-Bstatic"] : []
        libraries += ["-Wl,--start-group"] +
                     rust_link_libraries_msys +
                     ["-Wl,--end-group"] +
                     MSYS_LIBRARIES +
                     # Rust std's Windows references the dwarfs closure
                     # does not cover (proven by the mingw-ld link probe):
                     # RtlNtStatusToDosError (ntdll) and
                     # GetUserProfileDirectoryW (userenv).
                     ["-lntdll", "-luserenv"]
        return linux_libraries(libraries, ruby_ver, with_compression)
      end

      libraries = with_compression ? ["-Wl,-Bstatic"] : []
      # The dwarfs reader set + codecs go inside a group: miniruby.exe links
      # with a bare $(MAINLIBS) rule (no group of its own), and GNU ld's
      # single-pass scan needs it to resolve the circular member refs
      # (decompressor_registry -> compression registrar in libdwarfs_common).
      # COMMON_ARCHIEVE_LIBRARIES adds bz2 (libzip) and the codec set; psapi
      # covers GetProcessMemoryInfo (libdwarfs_common util.cpp).
      libraries += ["-Wl,--start-group"] +
                   COMMON_LINUX_LIBRARIES.map { |lib| msys_boost_reference(lib) } +
                   COMMON_ARCHIEVE_LIBRARIES +
                   ["-Wl,--end-group"] +
                   MSYS_LIBRARIES
      linux_libraries(libraries, ruby_ver, with_compression)
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

    def darwin_libraries(ruby_ver)
      libs = String.new

      # The v2 link (image era): the sealed Rust driver + tfs objects
      # and the closure archives from the tebako-rs build (dwarfs-t,
      # squashfs, botan, rnp, codecs) — no C++ libtfs, no vcpkg closure.
      # The brew libs below stay: they are ruby's own dependencies (and
      # v1-proven to satisfy dwarfs-t's openssl references).
      libs << "#{rust_link_libraries.join(' ')} " if rust_libdir
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
      "-ltebako-fs #{libs}-lc++ -lc++abi"
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
    def rust_link_libraries
      libs = %w[libtebako_driver.a libtfs.a].map do |name|
        path = File.join(rust_libdir, name)
        raise TebakoRuntimeBuilder::Error.new(
          "missing v2 link input: #{path} — run tebako-arscope (tebako-rs) and stage the scoped staticlibs",
          112
        ) unless File.file?(path)

        path
      end
      closure = Dir.glob(File.join(rust_libdir, "closure", "*.a")).sort
      raise TebakoRuntimeBuilder::Error.new(
        "TEBAKO_RUST_LIBDIR (#{rust_libdir}) carries no closure/*.a — stage the scoped link unit first",
        112
      ) if closure.empty?

      libs + closure
    end

    # The v2 link switch (image era): TEBAKO_RUST_LIBDIR names the
    # directory holding the scoped link unit (libtebako_driver.a +
    # libtfs.a + closure/*.a).
    def rust_libdir
      dir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)
      dir unless dir.nil? || dir.empty?
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
