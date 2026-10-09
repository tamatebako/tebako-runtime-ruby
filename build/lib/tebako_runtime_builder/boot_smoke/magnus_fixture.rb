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
require "open3"
require "tmpdir"

module TebakoRuntimeBuilder
  class BootSmoke
    # The issue-#192 boot-smoke fixture: a magnus-built extension (the
    # crate under fixtures/magnus) compiled IN-LEG against the freshly
    # built runtime and handed to the magnus_ext scenario, which loads it
    # inside the packaged context and calls through to
    # ruby_thread_has_gvl_p — the internal CRuby declaration the ruby-rust
    # gem family binds (internal/thread.h through 3.4, public on master).
    # The gate proves, per leg: the symbol's presence in the exe/dll
    # export surface, the magnus/rb-sys build path against the static
    # runtime, and the load-time resolution contract (linux
    # dlopen-from-exe, macOS dynamic lookup, windows import-lib link).
    #
    # The build replays the rb-sys gem's contract: rbconfig flows to
    # rb-sys's build script as RBCONFIG_<key> env (env wins over rb-sys's
    # own $RUBY dump), the header dirs point at the leg's stashed headers
    # narrowed to the runtime's ABI line, windows adds libdir -> the
    # build tree's import lib, and the platform link flags the gem's
    # CargoBuilder computes ride `cargo rustc --` (macOS dynamic_lookup —
    # rb-sys's own emitted link-arg never propagates to a dependent
    # cdylib, cargo#9554) resp. RUSTFLAGS (musl's crt-static-off, which a
    # trailing -C never applies at target-evaluation level).
    class MagnusFixture # rubocop:disable Metrics/ClassLength
      CRATE_DIR = File.expand_path("fixtures/magnus", __dir__).freeze
      CRATE_NAME = "magnus_fixture"
      # The bindgen-time C23 <stdckdint.h> fallback (see cargo_env).
      BINDGEN_SHIM_DIR = File.expand_path("fixtures/magnus/bindgen-shim", __dir__).freeze
      # The legs provision rust per the JIT pattern (the rustup pin lives
      # at /opt/cargo; hosted runners carry cargo on PATH).
      # TEBAKO_SMOKE_CARGO overrides.
      CARGO_CANDIDATES = ["/opt/cargo/bin/cargo"].freeze
      # The msys host id -> the rust target whose linker model matches the
      # runtime's (gnu import-lib link). windows/arm64 (clangarm64) is not
      # wired — its rust target and import-lib naming are unverified, so
      # the gate fails closed there rather than guessing.
      MSYS_RUST_TARGETS = { "windows-ucrt64" => "x86_64-pc-windows-gnu" }.freeze

      def initialize(executable:, platform: Platform.new, image: nil, toolchain: nil)
        @platform = platform
        @executable = executable
        @image = image
        @toolchain = toolchain
      end

      attr_reader :platform

      # Build the crate once per process; returns the host path of the
      # artifact renamed to the runtime's DLEXT spelling (require-ready).
      def library_path
        @library_path ||= build
      end

      private

      def build
        Dir.mktmpdir("tebako-magnus-fixture") { |dir| keep_library(build_in(dir)) }
      end

      def build_in(dir)
        cargo_bin = resolve_cargo
        rust_target if platform.msys? # fail closed on unwired hosts before any work
        config = dump_rbconfig(dir)
        run_cargo(cargo_bin, dir, config)
        artifact = find_artifact(dir)
        dlext = config.fetch("DLEXT") { raise TebakoRuntimeBuilder::Error.new("rbconfig carries no DLEXT", 149) }
        staged = File.join(dir, "#{CRATE_NAME}.#{dlext}")
        FileUtils.cp(artifact, staged)
        staged
      end

      def keep_library(staged)
        keep = File.join(Dir.tmpdir, "tebako-magnus-fixture-#{Process.pid}", File.basename(staged))
        FileUtils.mkdir_p(File.dirname(keep))
        FileUtils.cp(staged, keep)
        keep
      end

      # The runtime's own RbConfig::CONFIG, dumped by booting it (the
      # rb-sys record separator protocol), scrubbed of the host's
      # bundler/rubygems leaks exactly like a probe boot.
      def dump_rbconfig(dir)
        env = BootSmoke::ENV_SCRUBBED.to_h { |key| [key, nil] }
        env["TEBAKO_RUNTIME_IMAGE"] = @image if @image
        out, err, status = Open3.capture3(env, @executable, "--disable-gems", "-rrbconfig", "-e",
                                          'print RbConfig::CONFIG.map { |kv| kv.join("\x1F") }.join("\x1E")',
                                          chdir: dir)
        unless status&.success?
          raise TebakoRuntimeBuilder::Error.new("rbconfig dump failed (#{status}): #{err.to_s.strip[0, 400]}", 149)
        end

        parse_dump(out)
      end

      def parse_dump(out)
        # rb-sys's own parse keeps only key+value records — an empty-valued
        # CONFIG key splits to a lone key and is absent downstream either
        # way.
        config = out.split("\x1E")
                    .map { |pair| pair.split("\x1F", 2) }
                    .select { |parts| parts.length == 2 }
                    .to_h
        if config.empty?
          raise TebakoRuntimeBuilder::Error.new(
            "rbconfig of the booted runtime did not parse (#{out.length} bytes)", 149
          )
        end

        config
      end

      # cargo rustc with the runtime's rbconfig overlaid as RBCONFIG_* env
      # (the rb-sys gem's contract) + the leg's header/import-lib bridges.
      def run_cargo(cargo_bin, dir, config)
        args = [cargo_bin, "rustc", "--release", "--manifest-path", File.join(CRATE_DIR, "Cargo.toml")]
        args += ["--target", rust_target] if platform.msys?
        args << "--"
        args += ["-C", "link-arg=-Wl,-undefined,dynamic_lookup"] if platform.macos?
        BuildHelpers.run_with_capture(args, env: cargo_env(dir, config))
      rescue TebakoRuntimeBuilder::Error => e
        raise TebakoRuntimeBuilder::Error.new("the magnus boot-smoke fixture did not build: #{e.message}", 149)
      end

      def cargo_env(dir, config)
        env = config.merge(header_overrides(config))
                    .transform_keys { |key| "RBCONFIG_#{key}" }
                    .merge("RUBY" => @executable, "CARGO_TARGET_DIR" => File.join(dir, "target"))
        env["TEBAKO_RUNTIME_IMAGE"] = @image if @image
        env["RUSTFLAGS"] = rustflags if platform.linux_musl?
        env["BINDGEN_EXTRA_CLANG_ARGS"] = bindgen_extra_clang_args
        env
      end

      # Ruby 4.0's headers angle-include <stdckdint.h> when the leg's
      # configure found it (HAVE_STDCKDINT_H rides the stashed
      # ruby/config.h), but bindgen replays them against the SMOKE host's
      # libclang — a different generation than the leg's build compiler,
      # whose resource dir may lack the C23 header (the linux-gnu legs).
      # The fixture's shim dir rides -idirafter: searched strictly last,
      # so a toolchain shipping the real header never sees the shim.
      def bindgen_extra_clang_args
        parts = [ENV.fetch("BINDGEN_EXTRA_CLANG_ARGS", nil)]
        if (dir = msys_clang_resource_dir)
          parts << "-resource-dir" << dir
        end
        parts << "-idirafter" << BINDGEN_SHIM_DIR
        parts.compact.join(" ")
      end

      # The msys legs' bindgen libclang resolves headers without any
      # resource include — the freestanding set (stdbool, stdalign,
      # stdckdint, mm_malloc, the *intrin family) all surface as
      # "file not found" inside ruby's and mingw's headers. Pointing the
      # parse at the leg's OWN clang resource dir restores the whole set
      # at once; the shim dir stays as the strictly-last fallback.
      def msys_clang_resource_dir
        return nil unless platform.msys?

        clang = path_candidates("clang").find { |p| File.executable?(p) && !File.directory?(p) }
        return nil unless clang

        out, _, status = Open3.capture3(clang, "-print-resource-dir")
        dir = out.to_s.strip
        return nil if !status.success? || dir.empty?

        File.directory?(File.join(dir, "include")) ? dir : nil
      end

      def header_overrides(config)
        tc = toolchain(config)
        overrides = { "rubyhdrdir" => tc.headers_dir, "rubyarchhdrdir" => tc.arch_dir }
        overrides["libdir"] = import_lib_dir if platform.msys?
        overrides
      end

      # The headers must be the SAME ruby line as the runtime under test:
      # rb-sys's stable-api layer compiles versioned layout assumptions
      # (its ruby_4_0.rs names RUBY_FL_USERPRIV0 and the tagged RTypedData
      # type field — absent / differently-shaped in 3.x headers), so a
      # stale wrong-version stash fails the rb-sys compile deep in the
      # generated bindings (the 4.0.7 container legs, fed the image-baked
      # 3.3 stash by the alphabetical glob). The ABI spelling flows from
      # the runtime's own rbconfig dump.
      def toolchain(config)
        @toolchain ||= InterposeFixture::Toolchain.new(version_hint: config["ruby_version"])
      end

      # cdylib on musl needs crt-static OFF, and as a trailing `cargo
      # rustc --` flag the -C never lifts rustc's crate-type support
      # check (the first round's musl legs: "target does not support
      # these crate types") — RUSTFLAGS is evaluated at target level, the
      # idiom the tebako workspace's own musl cross-compiles use.
      def rustflags
        [ENV.fetch("RUSTFLAGS", nil), "-C target-feature=-crt-static"].compact.join(" ")
      end

      # The windows link model: rb-sys force-links libruby on mingw, so
      # libdir must name the directory holding lib*-ucrt-ruby*.dll.a — the
      # ruby build tree's, the same file the msys devkit stages.
      def import_lib_dir
        hits = Dir.glob(File.join(".build", "deps", "src", "_ruby_*", "lib*-ucrt-ruby*.dll.a"))
        if hits.empty?
          raise TebakoRuntimeBuilder::Error.new(
            "no ruby import library under .build/deps/src/_ruby_* (the msys leg stages it before the boot smoke)", 148
          )
        end

        File.expand_path(File.dirname(hits.first))
      end

      def rust_target
        MSYS_RUST_TARGETS.fetch(platform.host_id) do
          raise TebakoRuntimeBuilder::Error.new(
            "no rust target wired for msys host '#{platform.host_id}' (windows/arm64's clangarm64 link model " \
            "is unverified — wire it deliberately when the leg exists)", 148
          )
        end
      end

      def resolve_cargo
        explicit = ENV.fetch("TEBAKO_SMOKE_CARGO", nil)
        candidates = explicit ? [explicit] : CARGO_CANDIDATES + path_candidates("cargo")
        found = candidates.find { |path| File.executable?(path) && !File.directory?(path) }
        found || raise(TebakoRuntimeBuilder::Error.new(
                         "no cargo for the magnus boot-smoke fixture (tried: #{candidates.join(", ")}; " \
                         "set TEBAKO_SMOKE_CARGO)", 148
                       ))
      end

      def path_candidates(tool)
        # Windows keeps the runner's rust at .../cargo.exe; Ruby's
        # File.executable? never appends the extension, so the msys legs
        # probe both spellings per PATH entry.
        suffixes = platform.msys? ? ["", ".exe"] : [""]
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
           .flat_map { |dir| suffixes.map { |suffix| File.join(dir, "#{tool}#{suffix}") } }
      end

      def find_artifact(dir)
        base = File.join(dir, "target")
        base = File.join(base, rust_target) if platform.msys?
        hits = Dir.glob(File.join(base, "release", "{lib,}#{CRATE_NAME}.{so,dylib,dll}"))
        if hits.empty?
          raise TebakoRuntimeBuilder::Error.new("the magnus fixture build left no cdylib under #{base}/release", 149)
        end

        hits.first
      end
    end
  end
end
