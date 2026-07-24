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

require "digest"
require "fileutils"
require "net/http"
require "uri"

module TebakoRuntimeBuilder
  # Download, SHA256-verification and caching of the pre-patched ruby source
  # published by tamatebako/ruby: the release carries one
  # tfs-ruby-<version>-src.tar.gz asset per supported ruby version plus a
  # SHA256SUMS manifest. Only the asset names and the SHA256SUMS format are
  # part of the contract -- never the repository's internal patch layout.
  class SourceFetcher
    DEFAULT_RELEASE = "v0.1.0"
    MAX_REDIRECTS = 5

    def initialize(cache_dir:, release: DEFAULT_RELEASE, mirror: nil)
      @release = release
      @base_url = (mirror || "https://github.com/tamatebako/ruby/releases/download/#{release}").sub(%r{/+\z}, "")
      @cache_dir = cache_dir
    end

    def asset_name(ruby_version)
      "tfs-ruby-#{ruby_version}-src.tar.gz"
    end

    # Returns [tarball_path, sha256] for the requested ruby version
    def fetch(ruby_version) # rubocop:disable Metrics/MethodLength
      name = asset_name(ruby_version)
      sha256 = expected_sha256(name)
      tarball = File.join(@cache_dir, @release, name)
      return [tarball, sha256] if File.file?(tarball) && Digest::SHA256.file(tarball).hexdigest == sha256

      FileUtils.rm_f(tarball)
      download("#{@base_url}/#{name}", tarball)
      actual = Digest::SHA256.file(tarball).hexdigest
      return [tarball, sha256] if actual == sha256

      FileUtils.rm_f(tarball)
      raise TebakoRuntimeBuilder::Error.new(
        "#{name}: expected SHA256 #{sha256}, got #{actual}; download deleted", 121
      )
    end

    private

    def expected_sha256(name)
      sums = File.join(@cache_dir, @release, "SHA256SUMS")
      download("#{@base_url}/SHA256SUMS", sums) unless File.file?(sums)
      File.foreach(sums) do |line|
        sha256, file = line.strip.split(/\s+/, 2)
        return sha256.downcase if file&.sub(/\A\*/, "") == name && sha256 =~ /\A[0-9a-f]{64}\z/i
      end
      raise TebakoRuntimeBuilder::Error.new(
        "#{name} not found in the SHA256SUMS of tamatebako/ruby release #{@release} " \
        "(#{@base_url}/SHA256SUMS)", 122
      )
    end

    def download(url, dest)
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, read_url(url))
    rescue TebakoRuntimeBuilder::Error
      FileUtils.rm_f(dest)
      raise
    end

    def read_url(url, redirects_left = MAX_REDIRECTS) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      uri = URI.parse(url)
      return read_file_url(uri) if uri.scheme == "file"
      raise TebakoRuntimeBuilder::Error.new("too many redirects fetching #{url}", 122) if redirects_left.zero?

      response = http_get(uri)
      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection
        read_url(URI.join(url, response["location"]).to_s, redirects_left - 1)
      else
        raise TebakoRuntimeBuilder::Error.new(
          "#{response.code} #{response.message} fetching #{url}", 122
        )
      end
    end

    def read_file_url(uri)
      File.binread(uri.path)
    rescue Errno::ENOENT
      raise TebakoRuntimeBuilder::Error.new("not found: #{uri.path}", 122)
    end

    def http_get(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 15
      http.read_timeout = 600
      http.start { |session| session.get(uri.request_uri.empty? ? "/" : uri.request_uri) }
    end
  end
end
