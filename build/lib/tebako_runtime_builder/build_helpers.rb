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
require "open3"
require "json"
require "net/http"
require "uri"

module TebakoRuntimeBuilder
  # Ruby build helpers (gem Tebako::BuildHelpers) plus the shared download
  # core every fetcher uses (SourceFetcher carries its own private copy for
  # the SHA256SUMS flow; TfsTool consumes this one) — so the Net::HTTP
  # discipline (redirect bound, timeouts, named failures) exists exactly
  # once per consumer class, mirrored from the python factory.
  module BuildHelpers
    MAX_REDIRECTS = 5

    class << self
      # The names of a GitHub release's assets, read off the release API
      # (in-process Net::HTTP — never a gh/curl shell-out). The CI leg
      # planner's windows/arm64 artifact gate consumes this against the
      # pinned tamatebako/tebako release. Authenticated when a token is
      # supplied: the shared runner NAT's unauthenticated 60/h budget stays
      # out of the plan. A token that fails to authenticate, an unknown
      # release, or any non-success answer is a named error (122 — the
      # fetch class), never an empty list (an empty list would silently
      # gate a leg that should run).
      def release_asset_names(repo, release, token: nil)
        response = release_api_get(repo, release, token: token)
        unless response.is_a?(Net::HTTPSuccess)
          raise TebakoRuntimeBuilder::Error.new(
            "#{response.code} #{response.message} reading #{repo} #{release} assets from the release API", 122
          )
        end

        JSON.parse(response.body).fetch("assets", []).map { |asset| asset.fetch("name") }
      end

      def run_with_capture(args, env: {})
        args = args.compact
        puts "   ... @ #{args.join(" ")}"
        out, st = Open3.capture2e(env, *args)
        if st.signaled? || !st.exitstatus.zero?
          raise TebakoRuntimeBuilder::Error, "Failed to run #{args.join(" ")} (#{st}):\n #{out}"
        end

        out
      end

      def run_with_capture_v(args, env: {})
        if verbose?
          args_v = args.dup
          args_v.push("--verbose")
          puts run_with_capture(args_v, env: env)
        else
          run_with_capture(args, env: env)
        end
      end

      # Sets up temporary environment variables and yields to the
      # block. When the block exits, the environment variables are set
      # back to their original values.
      def with_env(hash)
        old = {}
        hash.each do |k, v|
          old[k] = ENV.fetch(k, nil)
          ENV[k] = v
        end
        begin
          yield
        ensure
          hash.each_key { |k| ENV[k] = old[k] }
        end
      end

      def verbose?
        %w[yes true].include?(ENV.fetch("VERBOSE", nil))
      end

      def sha256_file(path)
        Digest::SHA256.file(path).hexdigest
      end

      # Download url to dest (creating the parent dir); a failure deletes
      # the partial file and raises with the caller's exit code.
      def download(url, dest, code:)
        FileUtils.mkdir_p(File.dirname(dest))
        File.binwrite(dest, read_url(url, code: code))
        dest
      rescue TebakoRuntimeBuilder::Error
        FileUtils.rm_f(dest)
        raise
      end

      def read_url(url, code:, redirects_left: MAX_REDIRECTS) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        uri = URI.parse(url)
        return read_file_url(uri, code) if uri.scheme == "file"
        raise TebakoRuntimeBuilder::Error.new("too many redirects fetching #{url}", code) if redirects_left.zero?

        response = http_get(uri)
        case response
        when Net::HTTPSuccess then response.body
        when Net::HTTPRedirection
          read_url(URI.join(url, response["location"]).to_s, code: code,
                                                             redirects_left: redirects_left - 1)
        else
          raise TebakoRuntimeBuilder::Error.new("#{response.code} #{response.message} fetching #{url}", code)
        end
      end

      def read_file_url(uri, code)
        # RFC 8089: a Windows drive letter rides the file URL path as
        # /D:/...; a mingw/ucrt ruby needs D:/... (the slashed form is
        # EINVAL to File.binread). This is URL decoding, not a fallback.
        path = uri.path.sub(%r{\A/([A-Za-z]:/)}, '\1')
        File.binread(path)
      rescue Errno::ENOENT
        raise TebakoRuntimeBuilder::Error.new("not found: #{path}", code)
      end

      def http_get(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 15
        http.read_timeout = 600
        http.start do |session|
          session.get(uri.request_uri.empty? ? "/" : uri.request_uri)
        end
      end

      private

      def release_api_get(repo, release, token: nil)
        uri = URI.parse("https://api.github.com/repos/#{repo}/releases/tags/#{release}")
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
          get = Net::HTTP::Get.new(uri.request_uri)
          get["Accept"] = "application/vnd.github+json"
          get["X-GitHub-Api-Version"] = "2022-11-28"
          get["Authorization"] = "Bearer #{token}" if token && !token.empty?
          http.request(get)
        end
      end
    end
  end
end
