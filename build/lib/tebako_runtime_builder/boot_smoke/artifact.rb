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

module TebakoRuntimeBuilder
  class BootSmoke
    # Name model of a runtime package artifact:
    # tebako-runtime-<tebako x.y.z>-<ruby x.y.z>-<platform id>[.exe] -- the
    # platform id itself carries dashes (linux-gnu-x86_64), so the versions
    # anchor the parse from the front.
    class Artifact
      NAME_RE = /\Atebako-runtime-(?<tebako>\d+\.\d+\.\d+)-(?<ruby>\d+\.\d+\.\d+)-(?<platform>.+?)(?:\.exe)?\z/

      def initialize(basename)
        match = NAME_RE.match(basename)
        unless match
          raise TebakoRuntimeBuilder::Error.new(
            "'#{basename}' is not a tebako runtime artifact name " \
            "(tebako-runtime-<tebako>-<ruby>-<platform>[.exe])", 142
          )
        end

        @tebako_version = match[:tebako]
        @ruby_version = match[:ruby]
        @platform_id = match[:platform]
      end

      attr_reader :tebako_version, :ruby_version, :platform_id

      def ruby_major
        @ruby_major ||= @ruby_version.split(".").first.to_i
      end
    end
  end
end
