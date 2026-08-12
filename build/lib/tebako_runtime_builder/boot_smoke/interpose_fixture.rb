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
    # surface (class E, §3.3 — a data file; no leg needs a JDK). Mounted at
    # /probe for the loader_interpose and class_e_exec scenarios (see
    # boot_smoke/probe.rb for the checks it enables). The .c sources
    # mirror tamatebako/ruby ci/spec22/fixtures (the acceptance harness of
    # the dln_c_loader_interpose patch family); separate release chains,
    # kept in lockstep by hand.
    class InterposeFixture
      autoload :Toolchain, File.expand_path("interpose_fixture/toolchain", __dir__)

      MOUNT = "/probe"
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

      def keep_image(image_path, tag)
        keep = File.join(Dir.tmpdir, "tebako-spec22-fixture-#{tag}.tfs")
        FileUtils.cp(image_path, keep)
        keep
      end

      # The per-platform compile argv lists: libvfsdep (the leaf), then
      # libvfsprobe (links it — the closure-walk exercise), then the
      # self-dlopening ruby C extension.
      def compile_commands(lib_dir)
        dep = File.join(lib_dir, "libvfsdep.#{platform.macos? ? "dylib" : "so"}")
        lib = File.join(lib_dir, "libvfsprobe.#{platform.macos? ? "dylib" : "so"}")
        ext = File.join(lib_dir, "probe_ext.#{platform.macos? ? "bundle" : "so"}")
        platform.macos? ? macos_commands(dep, lib, ext) : elf_commands(dep, lib, ext, lib_dir)
      end

      def macos_commands(dep, lib, ext)
        [["-dynamiclib", "-O2", src("vfsdep.c"), "-install_name", "@rpath/libvfsdep.dylib", "-o", dep],
         ["-dynamiclib", "-O2", src("vfsprobe.c"), dep, "-install_name", "@rpath/libvfsprobe.dylib",
          "-Wl,-rpath,@loader_path", "-o", lib],
         ["-bundle", "-O2", "-undefined", "dynamic_lookup", src("probe_ext.c"), *includes, *defines, "-o", ext]]
      end

      def elf_commands(dep, lib, ext, lib_dir)
        [["-shared", "-fPIC", "-O2", src("vfsdep.c"), "-Wl,-soname,libvfsdep.so", "-o", dep],
         ["-shared", "-fPIC", "-O2", src("vfsprobe.c"), "-L#{lib_dir}", "-lvfsdep", "-Wl,-rpath,$ORIGIN", "-o", lib],
         ["-shared", "-fPIC", "-O2", src("probe_ext.c"), *includes, *defines, "-o", ext]]
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
