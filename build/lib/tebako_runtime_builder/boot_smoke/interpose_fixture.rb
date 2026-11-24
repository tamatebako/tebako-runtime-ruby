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
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "tmpdir"

module TebakoRuntimeBuilder
  class BootSmoke
    # The spec-22 boot-smoke fixture: a probe payload image carrying a
    # VFS-resident native library with a dependency and a hand-rolled ruby
    # C extension that self-dlopens it (class L, POSIX), plus the
    # precompiled probe.jar a spawned JVM reads through the interposed
    # surface (class E, §3.3 — a data file; no leg needs a JDK), plus the
    # unpatched-IO probe pair (native_open_ext + the marker file it
    # raw-opens — tebako#1125's class, see boot_smoke/probe.rb's
    # native_open scenario). Mounted at /probe for the loader_interpose,
    # class_e_exec and native_open scenarios. The dln-interpose .c
    # sources (vfsdep/vfsprobe/probe_ext) mirror tamatebako/ruby
    # ci/spec22/fixtures (the acceptance harness of the
    # dln_c_loader_interpose patch family); separate release chains,
    # kept in lockstep by hand. native_open_ext.c is the ruby factory's
    # own IO-surface probe — no upstream mirror.
    class InterposeFixture
      autoload :Toolchain, File.expand_path("interpose_fixture/toolchain", __dir__)

      MOUNT = "/probe"
      # The native_open scenario's marker file (tebako#1125): the in-image
      # file the unpatched extension raw-opens. The probe computes the
      # same VFS path from TEBAKO_BOOT_PROBE_MOUNT (the two homes spell
      # the name independently, like library_vfs_path) and pins the raw
      # bytes against the patched API's read — never a hardcoded content.
      MARKER_NAME = "native-open-marker.txt"
      FIXTURES_DIR = File.expand_path("fixtures", __dir__).freeze

      def initialize(platform: Platform.new, headers_dir: nil, image_tool: nil)
        @platform = platform
        @toolchain = Toolchain.new(headers_dir: headers_dir, image_tool: image_tool)
      end

      attr_reader :platform

      # Build the fixture tree and pack it once per process; returns the
      # payload image path (copied out of the scratch tmpdir so it
      # outlives the build).
      def image
        @image ||= build
      end

      # The VFS path of the library the scenario dlopens (the in-runtime
      # probe computes the same from TEBAKO_BOOT_PROBE_MOUNT).
      def library_vfs_path
        File.join(MOUNT, "lib", "libvfsprobe.#{platform.macos? ? "dylib" : "so"}")
      end

      private

      def build
        if platform.msys?
          raise TebakoRuntimeBuilder::Error.new(
            "the loader-interpose boot-smoke scenario is POSIX-only in spec 22 phase 1 " \
            "(windows class L is its own later phase)", 145
          )
        end

        Dir.mktmpdir("tebako-spec22-fixture") { |dir| keep_image(build_in(dir), File.basename(dir)) }
      end

      def build_in(dir)
        lib_dir = File.join(dir, "tree", "lib")
        FileUtils.mkdir_p(lib_dir)
        compile_commands(lib_dir).each { |args| cc(args) }
        stage_jar(lib_dir)
        stage_marker(lib_dir)
        image_path = File.join(dir, "spec22-probe.tfs")
        pack_image(File.join(dir, "tree"), image_path)
        image_path
      end

      # The class-E proof fixture (spec 22 §3.3): the PRECOMPILED jar rides
      # as a data file next to its .java source and regeneration note — no
      # CI leg needs a JDK to build it (running the check only needs a JRE,
      # which the probe senses and skips on honestly when absent).
      def stage_jar(lib_dir)
        FileUtils.cp(File.join(FIXTURES_DIR, "probe.jar"), File.join(lib_dir, "probe.jar"))
      end

      # The native_open scenario's marker (tebako#1125): a plain data file
      # whose ONLY reader of interest is the unpatched extension's raw
      # open(2)/read(2). The content is generated here (never pinned in
      # the probe — the check asserts the shim serves byte-identically
      # what ruby's patched File.read serves, whatever the bytes are);
      # multi-line, so a short/offset read cannot pass by accident.
      def stage_marker(lib_dir)
        lines = (1..7).map { |n| "tebako native-open marker line #{n} (tebako#1125)" }
        File.write(File.join(lib_dir, MARKER_NAME), "#{lines.join("\n")}\n")
      end

      def keep_image(image_path, tag)
        keep = File.join(Dir.tmpdir, "tebako-spec22-fixture-#{tag}.tfs")
        FileUtils.cp(image_path, keep)
        keep
      end

      # The per-platform compile argv lists: libvfsdep (the leaf), then
      # libvfsprobe (links it — the closure-walk exercise), then the
      # self-dlopening ruby C extension, then the unpatched-IO probe
      # extension (native_open_ext.c — no PROBE_LIB_PATH define; it
      # opens whatever path the probe hands it).
      def compile_commands(lib_dir)
        dep, lib, ext, native = artifact_paths(lib_dir)
        platform.macos? ? macos_commands(dep, lib, ext, native) : elf_commands(dep, lib, ext, native, lib_dir)
      end

      # The four fixture artifacts' output paths: the two shared
      # libraries (dylib/so), then the two ruby extensions (bundle/so).
      def artifact_paths(lib_dir)
        lib_suffix = platform.macos? ? "dylib" : "so"
        ext_suffix = platform.macos? ? "bundle" : "so"
        [File.join(lib_dir, "libvfsdep.#{lib_suffix}"),
         File.join(lib_dir, "libvfsprobe.#{lib_suffix}"),
         File.join(lib_dir, "probe_ext.#{ext_suffix}"),
         File.join(lib_dir, "native_open_ext.#{ext_suffix}")]
      end

      def macos_commands(dep, lib, ext, native)
        [["-dynamiclib", "-O2", src("vfsdep.c"), "-install_name", "@rpath/libvfsdep.dylib", "-o", dep],
         ["-dynamiclib", "-O2", src("vfsprobe.c"), dep, "-install_name", "@rpath/libvfsprobe.dylib",
          "-Wl,-rpath,@loader_path", "-o", lib],
         ["-bundle", "-O2", "-undefined", "dynamic_lookup", src("probe_ext.c"), *includes, *defines, "-o", ext],
         ["-bundle", "-O2", "-undefined", "dynamic_lookup", src("native_open_ext.c"), *includes, "-o", native]]
      end

      def elf_commands(dep, lib, ext, native, lib_dir)
        [["-shared", "-fPIC", "-O2", src("vfsdep.c"), "-Wl,-soname,libvfsdep.so", "-o", dep],
         ["-shared", "-fPIC", "-O2", src("vfsprobe.c"), "-L#{lib_dir}", "-lvfsdep", "-Wl,-rpath,$ORIGIN", "-o", lib],
         ["-shared", "-fPIC", "-O2", src("probe_ext.c"), *includes, *defines, "-o", ext],
         ["-shared", "-fPIC", "-O2", src("native_open_ext.c"), *includes, "-o", native]]
      end

      def includes
        ["-I#{@toolchain.headers_dir}", "-I#{@toolchain.arch_dir}"]
      end

      def defines
        ["-DPROBE_LIB_PATH=\"#{library_vfs_path}\""]
      end

      def cc(args)
        BuildHelpers.run_with_capture([ENV.fetch("CC", "cc"), *args])
      rescue TebakoRuntimeBuilder::Error => e
        raise TebakoRuntimeBuilder::Error.new("the spec-22 boot-smoke fixture did not compile: #{e.message}", 146)
      end

      def src(name)
        File.join(FIXTURES_DIR, name)
      end

      def pack_image(tree, image_path)
        tool = @toolchain.image_tool
        if File.basename(tool).start_with?("tfs")
          BuildHelpers.run_with_capture([tool, "mkimage", "--format", "dwarfs", tree, "-o", image_path])
        else
          BuildHelpers.run_with_capture([tool, "-i", tree, "-o", image_path, "--no-progress", "--force"])
        end
      end
    end
  end
end
