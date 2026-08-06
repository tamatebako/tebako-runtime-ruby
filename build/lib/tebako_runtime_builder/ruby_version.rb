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
  # Ruby version gates (gem Tebako::RubyVersion, version predicates only --
  # the pre-patched source carries its own integrity metadata, so the
  # RUBY_VERSIONS sha256 table of the gem is not carried here)
  class RubyVersion
    def initialize(ruby_version)
      @ruby_version = ruby_version
      version_check_format
    end

    attr_reader :ruby_version

    def api_version
      @api_version ||= "#{@ruby_version.split(".")[0..1].join(".")}.0"
    end

    def lib_version
      @lib_version ||= "#{@ruby_version.split(".")[0..1].join}0"
    end

    # The shared libruby name of the msys build (issue #40): ruby
    # configure's RUBY_SO_NAME for x86_64-w64-mingw32 (ucrt64) is
    # x64-ucrt-ruby$(MAJOR)$(MINOR)0, so the DLL is
    # x64-ucrt-ruby<lib_version>.dll (and its import library
    # libx64-ucrt-ruby<lib_version>.dll.a). ONE owner: the MAINLIBS literal
    # (mlibs.rb), the release pipeline's install-as name
    # (scripts/upload_release.rb), the finalize staging and the boot
    # smoke's materialization all flow it; CI asserts parity by linking
    # and loading (a drifted name binds nothing).
    def msys_dll_name
      "x64-ucrt-ruby#{lib_version}.dll"
    end

    def msys_implib_name
      "libx64-ucrt-ruby#{lib_version}.dll.a"
    end

    # Version gates compare numerically so 4.x lines fall out naturally
    # (string indexing broke the moment the major version hit 4)
    def ruby3x?
      @ruby3x ||= version_at_least?(3, 0)
    end

    def ruby31?
      @ruby31 ||= version_at_least?(3, 1)
    end

    def ruby32?
      @ruby32 ||= version_at_least?(3, 2)
    end

    def ruby32only?
      @ruby32only ||= major_minor == [3, 2]
    end

    def ruby33?
      @ruby33 ||= version_at_least?(3, 3)
    end

    def ruby33only?
      @ruby33only ||= major_minor == [3, 3]
    end

    def ruby34only?
      @ruby34only ||= major_minor == [3, 4]
    end

    def ruby3x7?
      @ruby3x7 ||= ruby34? ||
                   (ruby33only? && patch_version >= 7) ||
                   (ruby32only? && patch_version >= 7)
    end

    def ruby34?
      @ruby34 ||= version_at_least?(3, 4)
    end

    def version_check_format
      return if @ruby_version =~ /^\d+\.\d+\.\d+$/

      raise TebakoRuntimeBuilder::Error.new("Invalid Ruby version format '#{@ruby_version}'. Expected format: x.y.z",
                                            109)
    end

    private

    def major_minor
      @major_minor ||= @ruby_version.split(".").first(2).map(&:to_i)
    end

    def patch_version
      @patch_version ||= @ruby_version.split(".")[2].to_i
    end

    def version_at_least?(major, minor)
      (major_minor <=> [major, minor]) >= 0
    end
  end
end
