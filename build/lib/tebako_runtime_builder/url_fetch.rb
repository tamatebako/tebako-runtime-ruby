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

require "net/http"
require "openssl"
require "uri"

module TebakoRuntimeBuilder
  # The one GET every download in this build tree shares, with the
  # transient-failure budget the python factory already carried: three
  # attempts, doubling backoff, and only the failures a retry can honestly
  # fix (a dropped connection, a reset TLS session, a 408/429/5xx).
  #
  # Measured need: a publish leg built its runtime, then lost the whole
  # leg to a single `ECONNRESET` while fetching the tfs tool — forty
  # minutes of build discarded by one dropped connection, and the same
  # fetch is the release's own first step. A 404 or a 403 stays fatal on
  # the first attempt: a missing asset is not a transient fact.
  module UrlFetch
    ATTEMPTS = 3
    BACKOFF_BASE = 2
    RETRYABLE_STATUSES = [408, 429].freeze
    RETRYABLE_ERRORS = [
      EOFError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError, SocketError,
      SystemCallError, Timeout::Error
    ].freeze

    class << self
      # GET the URI within the attempt budget. Answers the response when it
      # is a success OR a non-retryable answer (the caller owns its status
      # contract), and raises the caller's named error once a retryable
      # failure outlives the budget.
      def get(uri, code:) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        ATTEMPTS.times do |attempt|
          begin
            response = http_get(uri)
          rescue *RETRYABLE_ERRORS => e
            next if retry_attempt?(uri, attempt + 1, "#{e.class}: #{e.message}")

            raise Error.new("#{e.class}: #{e.message} fetching #{uri}", code)
          end
          return response unless retryable_status?(response.code.to_i)

          next if retry_attempt?(uri, attempt + 1, "#{response.code} #{response.message}")

          raise Error.new("#{response.code} #{response.message} fetching #{uri}", code)
        end
      end

      # True when the HTTP status is one a retry can honestly fix.
      def retryable_status?(status, extra = [])
        RETRYABLE_STATUSES.include?(status) || extra.include?(status) || status >= 500
      end

      # Names a failed attempt on stderr and sleeps out the backoff; true
      # while another attempt remains, false once the budget is spent.
      def retry_attempt?(uri, attempt, reason)
        return false if attempt >= ATTEMPTS

        delay = BACKOFF_BASE**attempt
        warn "attempt #{attempt}/#{ATTEMPTS} failed fetching #{uri}: #{reason} — retrying in #{delay}s"
        sleep delay
        true
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
end
