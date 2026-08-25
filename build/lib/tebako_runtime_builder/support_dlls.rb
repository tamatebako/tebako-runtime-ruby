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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "rbconfig"

module TebakoRuntimeBuilder
  # The msys2 toolchain runtime DLLs the env image ships and declares as
  # `library_aliases:` (spec 22 §2.1 — the windows class-L alias channel;
  # spec 03 §2.5 owns the declaration grammar).
  #
  # Why they ride the runtime (packed-mn windows dogfood, 2026-08-25 —
  # metanorma/packed-mn#251): a payload-resident C extension compiled by
  # a mingw/ucrt toolchain imports the toolchain's support DLLs (ox.so and
  # sqlite3_native.so import libwinpthread-1.dll; the C++ extension class —
  # sassc's libsass — adds libgcc_s_seh-1.dll and libstdc++-6.dll). The PE
  # closure walk resolves a bare import importer-dir-only by design, the
  # runtime's own DLL is excluded (already loaded in-process), and nothing
  # else puts a support DLL on the OS search path — so the load died with
  # the OS loader's honest 126 on a clean windows machine. The runtime's
  # own PE modules statically link this set (Mlibs::MSYS_DLL_LIBRARIES),
  # which is exactly why the factory's pre-alias smoke never missed them.
  #
  # The declared channel is the product's boot pass (tebako
  # crates/tebako-driver alias.rs): EVERY co-mounted image's
  # `library_aliases:` are materialized at boot and their directories lead
  # the process PATH, so the OS's own standard search order resolves a
  # declared name for any caller — interception-free, per-gem-code-free.
  #
  # NAMES is the single owner (invariant 10): the deploy pass stages
  # exactly these names into the image's bin/, ImageManifest declares
  # exactly these names, and the boot smoke's expectation flows from here.
  # Staging is fail-closed — a name no toolchain prefix holds is a named
  # build error, so the manifest can never declare an absent DLL.
  class SupportDlls
    # The toolchain support set: libwinpthread (the proven payload-ext
    # import), libgcc_s + libstdc++ (the C++ extension class).
    NAMES = %w[libwinpthread-1.dll libgcc_s_seh-1.dll libstdc++-6.dll].freeze

    # The in-image home (the layout tree's bin/ maps to the image's /bin).
    IN_IMAGE_BIN = "bin"

    # The L1 manifest's `library_aliases:` block (spec 03 §2.5): the bare
    # PE name and the in-image absolute path of the staged copy.
    def self.alias_declarations
      NAMES.map { |name| { "name" => name, "path" => "/#{IN_IMAGE_BIN}/#{name}" } }
    end

    # The msys2 toolchain prefixes to source from, most authoritative
    # first: the invoking shell's MSYSTEM_PREFIX (the msys2 shell the CI
    # leg builds under), then the running toolchain ruby's own prefix.
    def self.toolchain_prefixes
      [ENV.fetch("MSYSTEM_PREFIX", nil), RbConfig::CONFIG["prefix"]].compact.uniq
    end

    def initialize(prefixes: self.class.toolchain_prefixes)
      @prefixes = prefixes
    end

    # Stage the set into the layout tree's bin dir; answers the staged
    # host paths. A name absent from every prefix is a named error —
    # never a silently skipped declaration.
    def stage(bin_dir)
      FileUtils.mkdir_p(bin_dir)
      NAMES.map { |name| stage_one(bin_dir, name) }
    end

    private

    def stage_one(bin_dir, name)
      dest = File.join(bin_dir, name)
      FileUtils.cp(source_for(name), dest)
      dest
    end

    # The first toolchain prefix holding `name` under its bin dir. A name
    # absent from every prefix is a named error — never a silently skipped
    # declaration: the msys2 gcc-runtime set is a ruby build-time
    # dependency, so a toolchain image without it cannot produce a runtime
    # payload exts bind against.
    def source_for(name)
      source = @prefixes.map { |prefix| File.join(prefix, IN_IMAGE_BIN, name) }
                        .find { |candidate| File.file?(candidate) }
      return source if source

      raise TebakoRuntimeBuilder::Error.new(
        "support DLL '#{name}' not found under any toolchain prefix's #{IN_IMAGE_BIN}/ " \
        "(searched: #{@prefixes.join(", ")})", 147
      )
    end
  end
end
