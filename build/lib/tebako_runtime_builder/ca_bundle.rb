# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
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
  # The windows runtime's CA bundle (0.16.5; class-R wired in 0.16.6).
  # vcpkg's static openssl was built with the CI runner's openssldir — a
  # path no user machine has — so the default verify paths find nothing
  # there and the first HTTPS from a packaged app fails ("certificate
  # verify failed"). The env image ships the curl project's CA bundle
  # (the Mozilla store) at ssl/cert.pem; the image manifest declares it
  # in the class-R materialize list (ImageManifest) and the exe's boot
  # shim (build/CMakeLists.txt's TEBAKO_MAIN_SHIM) points SSL_CERT_FILE
  # at the driver's materialized HOST copy — the bundle must exist
  # off-VFS because libcrypto reads it through its own native CRT IO.
  # A user-set SSL_CERT_FILE still wins. POSIX legs ship nothing: vcpkg's
  # unix openssl builds with --openssldir=/etc/ssl, which the host
  # supplies through the jail.
  #
  # The pin is a VERSIONED curl.se URL plus its SHA256 — an immutable
  # pair, never the moving cacert.pem alias. Bump procedure: pick the
  # newest cacert-<date>.pem, record its digest here, same PR.
  class CaBundle
    FILENAME = "cacert-2026-08-13.pem"
    URL = "https://curl.se/ca/#{FILENAME}".freeze
    SHA256 = "f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9"
    # Where the bundle rides inside the env image — the path the image
    # manifest's class-R materialize list declares (as "/ssl/cert.pem").
    IN_IMAGE_PATH = File.join("ssl", "cert.pem").freeze
    MAX_REDIRECTS = 5

    def initialize(cache_dir:, mirror: nil, sha256: SHA256)
      @url = mirror ? "#{mirror}/#{FILENAME}" : URL
      @cache_dir = cache_dir
      @sha256 = sha256
    end

    # The verified bundle path (cache-first; a digest mismatch deletes
    # the download and fails by name — a supply-chain event, never a
    # silent refetch loop).
    def fetch # rubocop:disable Metrics/MethodLength
      cached = File.join(@cache_dir, FILENAME)
      return cached if File.file?(cached) && Digest::SHA256.file(cached).hexdigest == @sha256

      FileUtils.rm_f(cached)
      FileUtils.mkdir_p(@cache_dir)
      File.binwrite(cached, read_url(@url))
      actual = Digest::SHA256.file(cached).hexdigest
      return cached if actual == @sha256

      FileUtils.rm_f(cached)
      raise TebakoRuntimeBuilder::Error.new(
        "#{FILENAME}: expected SHA256 #{@sha256}, got #{actual}; download deleted", 123
      )
    end

    # Deploy the verified bundle into the env-image layout at
    # ssl/cert.pem; returns the deployed path.
    def deploy(layout_dir)
      dest = File.join(layout_dir, IN_IMAGE_PATH)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(fetch, dest)
      dest
    end

    private

    def read_url(url, redirects_left = MAX_REDIRECTS) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      uri = URI.parse(url)
      return read_file_url(uri) if uri.scheme == "file"
      raise TebakoRuntimeBuilder::Error.new("too many redirects fetching #{url}", 124) if redirects_left.zero?

      response = http_get(uri)
      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection
        read_url(URI.join(url, response["location"]).to_s, redirects_left - 1)
      else
        raise TebakoRuntimeBuilder::Error.new("#{response.code} #{response.message} fetching #{url}", 124)
      end
    end

    def read_file_url(uri)
      # RFC 8089: a Windows drive letter rides the file URL path as
      # /D:/...; a mingw/ucrt ruby needs D:/... (the slashed form is
      # EINVAL to File.binread). This is URL decoding, not a fallback.
      path = uri.path.sub(%r{\A/([A-Za-z]:/)}, '\1')
      File.binread(path)
    rescue Errno::ENOENT
      raise TebakoRuntimeBuilder::Error.new("not found: #{path}", 124)
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
