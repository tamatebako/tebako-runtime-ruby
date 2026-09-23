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

module TebakoRuntimeBuilder
  # The tfs CLI (tamatebako/tebako's tfs-cli) as a build-time factory
  # tool: `tfs mkimage` packs the env image (the limnifs writer — the
  # default format, spec 20 §6) and the boot smoke's fixture images. The
  # CLI is consumed from the SAME tamatebako/tebako release pin as the
  # link unit (one product release carries both), verified against its
  # published `<asset>.sha256` sidecar — the store trust-anchor shape
  # ("<sha256>  <filename>\n"). Never a runtime dependency of the shipped
  # packages; never the container's baked tfs (an unpinned version is a
  # provenance gap). Mirrored from the python factory's TfsTool.
  class TfsTool
    REPO = "tamatebako/tebako"

    def initialize(cache_dir:, release:, platform:)
      @cache_dir = cache_dir
      @release = release
      @platform = platform
    end

    def asset_name
      "tfs-#{@release.sub(/\Av/, "")}-#{@platform.host_id}#{@platform.exe_suffix}"
    end

    # Fetch + verify + return the executable path (cached by its sha256).
    def fetch # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      expected = expected_sha256
      dest = File.join(@cache_dir, "tfs", expected, asset_name)
      if File.file?(dest) && TebakoRuntimeBuilder::BuildHelpers.sha256_file(dest) == expected
        FileUtils.chmod(0o755, dest)
        return dest
      end

      FileUtils.rm_f(dest)
      url = "https://github.com/#{REPO}/releases/download/#{@release}/#{asset_name}"
      TebakoRuntimeBuilder::BuildHelpers.download(url, dest, code: 125)
      actual = TebakoRuntimeBuilder::BuildHelpers.sha256_file(dest)
      unless actual == expected
        FileUtils.rm_f(dest)
        raise TebakoRuntimeBuilder::Error.new(
          "#{asset_name}: expected SHA256 #{expected} (the published .sha256 sidecar), got #{actual}; " \
          "download deleted", 125
        )
      end

      FileUtils.chmod(0o755, dest)
      puts "-- tfs CLI #{asset_name} verified (sha256 #{expected})"
      dest
    end

    # An explicitly requested tfs CLI (--tfs / TEBAKO_TFS): resolves the
    # request to an executable path or fails closed — silently falling
    # back would hide a misconfigured toolchain.
    def self.resolve_requested(requested, platform)
      return requested if File.file?(requested) && File.executable?(requested)

      exts = platform.msys? ? [".exe", ""] : [""]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).product(exts).each do |dir, ext|
        candidate = File.join(dir, "#{requested}#{ext}")
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end

      raise TebakoRuntimeBuilder::Error.new(
        "requested tfs binary '#{requested}' was not found (not a file, not on PATH)", 131
      )
    end

    private

    # The sidecar asset's declared sha256 for the CLI asset — fetched from
    # the release and parsed in the trust-anchor grammar.
    def expected_sha256 # rubocop:disable Metrics/MethodLength
      sidecar = "#{asset_name}.sha256"
      cached = File.join(@cache_dir, "tfs", sidecar)
      unless File.file?(cached)
        url = "https://github.com/#{REPO}/releases/download/#{@release}/#{sidecar}"
        TebakoRuntimeBuilder::BuildHelpers.download(url, cached, code: 125)
      end
      sha256, file = File.read(cached).strip.split(/\s+/, 2)
      unless sha256 =~ /\A[0-9a-f]{64}\z/ && file == asset_name
        FileUtils.rm_f(cached)
        raise TebakoRuntimeBuilder::Error.new(
          "#{sidecar}: not a trust-anchor sidecar for #{asset_name} (got #{File.read(cached).inspect})", 125
        )
      end
      sha256
    end
  end
end
