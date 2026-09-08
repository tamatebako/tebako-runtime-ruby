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
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS
# OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module TebakoRuntimeBuilder
  # The ONE owner of the runtime capability truth table (the versions
  # catalog's plan 04): the value the release manifest's additive
  # `capabilities` key carries, AND the expectation boot smoke's yjit
  # scenario asserts -- one method, two callers, parity by construction.
  # The versions site renders this key when present (its own derivation
  # is a fallback, never the authority).
  #
  # yjit: compiled in exactly where upstream builds it with rustc present
  # -- non-msys legs of ruby >= 3.2, plus the 3.1 line on x86_64 only
  # (its YJIT_TARGET_OK arms no aarch64). Off on windows (upstream
  # carries no mingw-x64 YJIT arm) and on 3.1's non-x86_64 legs.
  # zjit (the ruby-4 line, upstream #147) joins this table the same way
  # when it ships -- never a site-side derivation.
  class Capabilities
    YJIT = "yjit"

    class << self
      def yjit(ruby_version:, platform_id:)
        return false if platform_id.include?("windows")

        return platform_id.end_with?("x86_64") if RubyVersion.new(ruby_version).ruby31only?

        true
      end

      # The manifest value: always an array (empty when the runtime has no
      # derived capabilities), additive -- pre-key readers ignore it.
      def for(ruby_version:, platform_id:)
        yjit(ruby_version: ruby_version, platform_id: platform_id) ? [YJIT] : []
      end
    end
  end
end
