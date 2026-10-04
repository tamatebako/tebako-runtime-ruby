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
  # The ONE owner of the runtime package-name era gate (tebako#716, spec 05
  # §2's era law): the asset spelling gains a language segment —
  # tebako-runtime-<tebako>-ruby-<ruby>-<platform> — ONLY on tebako lines
  # >= NEW_ERA_FLOOR. The <= 0.16.32 lines are immutable (sha256-pinned in
  # the live registries) and keep the lang-less spelling forever, so the
  # gate keys on the tebako version BEING BUILT / PUBLISHED IN THIS RUN,
  # never on a repo-wide flag: a catalog/mop-up rerun of an old line must
  # keep composing old-era names after the flip lands.
  #
  # Two consumers flow it, so name composition can never disagree with the
  # release machinery: Builder#default_output (the local-build package
  # name) and scripts/release_adapter.rb's lang_name (the tebako-release
  # gem's compose/audit hook — the gem's parser is dual-era and reads both
  # spellings forever). The CI workflow's compose sites compute the same
  # gate from the same per-run version (the compute job's lang-infix
  # output off `cat VERSION`); the boot smoke's Artifact parser accepts
  # both eras.
  class PackageName
    # The first tebako line whose runtime assets carry the language
    # segment (tebako#716).
    NEW_ERA_FLOOR = Gem::Version.new("0.17.0")

    # This factory's language segment — the value the adapter's lang_name
    # declares on new-era lines (the gem composes
    # tebako-runtime-<ver>-<lang>-<lv>-<triplet> from it).
    LANG_SEGMENT = "ruby"

    class << self
      # The language segment for a tebako line: "ruby" on >= 0.17.0, nil on
      # the immutable older lines (the gem's nil = pre-#716 spelling).
      def lang_segment(tebako_version)
        new_era?(tebako_version) ? LANG_SEGMENT : nil
      end

      # The name-grammar infix for a tebako line: "ruby-" on new-era lines,
      # empty on the old-era spelling.
      def lang_infix(tebako_version)
        segment = lang_segment(tebako_version)
        segment.nil? ? "" : "#{segment}-"
      end

      private

      def new_era?(tebako_version)
        Gem::Version.new(tebako_version) >= NEW_ERA_FLOOR
      end
    end
  end
end
