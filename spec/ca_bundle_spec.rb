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
require "digest"
require "fileutils"

RSpec.describe TebakoRuntimeBuilder::CaBundle do
  let(:mirror_dir) { Dir.mktmpdir }
  let(:cache_dir) { Dir.mktmpdir }
  let(:layout_dir) { Dir.mktmpdir }
  let(:bundle_content) { "fake-ca-bundle" }
  let(:bundle_sha256) { Digest::SHA256.hexdigest(bundle_content) }

  # The digest is injectable precisely so specs pin the fixture's bytes —
  # production uses the SHA256 constant (the curl.se pin) by default.
  let(:bundle) { described_class.new(mirror: "file://#{mirror_dir}", cache_dir: cache_dir, sha256: bundle_sha256) }

  before do
    File.binwrite(File.join(mirror_dir, described_class::FILENAME), bundle_content)
  end

  after do
    FileUtils.remove_entry(mirror_dir)
    FileUtils.remove_entry(cache_dir)
    FileUtils.remove_entry(layout_dir)
  end

  it "names the in-image path the boot shim exports" do
    expect(described_class::IN_IMAGE_PATH).to eq(File.join("ssl", "cert.pem"))
  end

  it "fetches through the mirror and verifies the pinned digest" do
    path = bundle.fetch
    expect(File.binread(path)).to eq(bundle_content)
  end

  it "serves a verified cached download without re-reading the mirror" do
    bundle.fetch
    FileUtils.rm(File.join(mirror_dir, described_class::FILENAME))
    expect(File.binread(bundle.fetch)).to eq(bundle_content)
  end

  it "deploys the verified bundle at ssl/cert.pem in the layout" do
    dest = bundle.deploy(layout_dir)
    expect(dest).to eq(File.join(layout_dir, "ssl", "cert.pem"))
    expect(File.binread(dest)).to eq(bundle_content)
  end

  it "raises and deletes the download on a checksum mismatch" do
    File.binwrite(File.join(mirror_dir, described_class::FILENAME), "tampered")
    expect { bundle.fetch }.to raise_error(TebakoRuntimeBuilder::Error, /expected SHA256/)
    expect(Dir.glob(File.join(cache_dir, "**", described_class::FILENAME))).to be_empty
  end

  it "raises by name when the mirror lacks the bundle" do
    FileUtils.rm(File.join(mirror_dir, described_class::FILENAME))
    expect { bundle.fetch }.to raise_error(TebakoRuntimeBuilder::Error, /not found/)
  end
end
