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
  # The memfs mount root the runtime is built against (spec 18 C1/S49).
  # The value FLOWS from the source tarball's tebako-mount-root manifest
  # (tamatebako/ruby's SourcePrep is the single owner of the constant;
  # MANIFEST below is the layout contract point). A tarball without the
  # manifest is a pre-era (or corrupt) source: refused by name with exit
  # 132 -- never a fallback to the platform convention, because a silent
  # convention vs. patch-literals drift is exactly the mismatch class the
  # era-2 contract set closes.
  class MountRoot
    MANIFEST = "tebako-mount-root"
    # The override capability manifest (spec 17 §1): the source tree
    # carries the loadpath patch, so its compiled-in load paths follow
    # TEBAKO_MOUNT_ROOT. Absent ⇒ closed — the fail-closed direction.
    OVERRIDE_MANIFEST = "tebako-mount-root-override"

    def initialize(tarball)
      @tarball = tarball
    end

    def read
      entry = manifest_entry
      if entry.nil?
        raise TebakoRuntimeBuilder::Error.new(
          "pre-era source tarball (no #{MANIFEST} manifest) — roll a new one with tamatebako/ruby ≥ v0.2.13", 132
        )
      end

      root = tar_output("-xOzf", tar_path, entry).strip
      raise TebakoRuntimeBuilder::Error.new("empty #{MANIFEST} in #{@tarball}", 131) if root.empty?

      root
    end

    # The override capability the tarball declares (the loadpath patch's
    # presence, emitted by SourcePrep) — the image layout's
    # mount_root_override grant is truthful only when this is true.
    def override?
      entry = manifest_entry(OVERRIDE_MANIFEST)
      return false if entry.nil?

      tar_output("-xOzf", tar_path, entry).strip == "true"
    end

    private

    def manifest_entry(manifest = MANIFEST)
      tar_output("-tzf", tar_path).lines.map(&:strip).find { |name| name.end_with?("/#{manifest}") }
    end

    # A tar invocation whose failure is a READ error (corrupt tarball,
    # unreadable path) — raised as such, exit 133, and never conflated
    # with "manifest absent" (the 132 pre-era case, which requires a
    # successful listing that simply lacks the entry).
    def tar_output(mode, *args)
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["tar", mode, *args])
    rescue TebakoRuntimeBuilder::Error => e
      raise TebakoRuntimeBuilder::Error.new("cannot read source tarball #{@tarball}: #{e.message}", 133)
    end

    # GNU tar parses 'D:/...' as a remote host on msys ("Cannot connect
    # to D: resolve failed" — the pitfall BuildPasses.extract_overlay
    # documents); feed it the cygpath form there, elsewhere the path as-is.
    def tar_path
      @tar_path ||= begin
        path = @tarball
        if TebakoRuntimeBuilder::Platform.new.msys?
          path = TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["cygpath", "-u", path]).strip
        end
        path
      end
    end
  end
end
