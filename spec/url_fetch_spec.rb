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

require "spec_helper"

RSpec.describe TebakoRuntimeBuilder::UrlFetch do
  let(:uri) { URI.parse("https://example.test/tfs-linux-amd64") }
  let(:success) { response(Net::HTTPOK, "200", "OK", "payload") }
  let(:retryable_status) { response(Net::HTTPBadGateway, "502", "Bad Gateway") }
  let(:not_found) { response(Net::HTTPNotFound, "404", "Not Found") }

  # A real response object (the caller matches on the class ancestry),
  # marked read so the body answers without an IO source.
  def response(klass, code, message, body = "")
    klass.new("1.1", code, message).tap do |res|
      res.body = body
      res.instance_variable_set(:@read, true)
    end
  end

  before do
    allow(described_class).to receive(:sleep)
    allow(described_class).to receive(:warn)
  end

  it "answers the first success without spending an attempt" do
    allow(described_class).to receive(:http_get).once.and_return(success)
    expect(described_class.get(uri, code: 122).body).to eq("payload")
  end

  it "retries a dropped connection and answers the retry" do
    allow(described_class).to receive(:http_get)
      .and_invoke(->(_uri) { raise Errno::ECONNRESET }, ->(_uri) { success })
    expect(described_class.get(uri, code: 122).body).to eq("payload")
    expect(described_class).to have_received(:warn).with(/ECONNRESET.*retrying in 2s/)
    expect(described_class).to have_received(:sleep).with(2)
  end

  it "raises the caller's named error once the budget is spent" do
    allow(described_class).to receive(:http_get).and_raise(Errno::ECONNRESET)
    expect { described_class.get(uri, code: 122) }
      .to raise_error(TebakoRuntimeBuilder::Error, /ECONNRESET/) { |e| expect(e.error_code).to eq(122) }
    expect(described_class).to have_received(:http_get).exactly(3).times
  end

  it "retries a 5xx answer" do
    allow(described_class).to receive(:http_get).and_return(retryable_status, success)
    expect(described_class.get(uri, code: 122).body).to eq("payload")
  end

  it "raises after a 5xx answer outlives the budget" do
    allow(described_class).to receive(:http_get).and_return(retryable_status)
    expect { described_class.get(uri, code: 122) }
      .to raise_error(TebakoRuntimeBuilder::Error, /502 Bad Gateway/) { |e| expect(e.error_code).to eq(122) }
  end

  it "fails a 404 on the first attempt" do
    allow(described_class).to receive(:http_get).once.and_return(not_found)
    response = described_class.get(uri, code: 122)
    expect(response.code).to eq("404")
    expect(described_class).not_to have_received(:sleep)
  end
end
