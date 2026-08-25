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
require "yaml"

RSpec.describe TebakoRuntimeBuilder::ImageManifest do
  let(:msys) { TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64") }
  let(:gnu) { TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu", "x86_64") }
  let(:src_sha256) { "ab" * 32 }

  def manifest_for(platform, ruby_version: "3.4.8")
    described_class.new(platform: platform, ruby_version: ruby_version,
                        tebako_version: "0.16.6", patch_set: "v0.2.24",
                        src_sha256: src_sha256).to_h
  end

  it "writes the runtime-kind identity block per spec 03 §2.1" do
    identity = manifest_for(gnu)["identity"]
    expect(identity).to include(
      "schema_version" => 1,
      "era" => 2,
      "kind" => "runtime",
      "name" => "tebako-runtime-ruby",
      "version" => "0.16.6",
      "producer" => { "tool" => "tebako-runtime-ruby", "tool_version" => "0.16.6" },
      "source" => { "src_sha256" => src_sha256 },
      "signing" => { "state" => "unsigned" },
      "encryption" => { "state" => "none" }
    )
    expect(identity["created"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
  end

  it "zeroes the digest pair per the spec 03 §7 fixed-point rule" do
    digest = manifest_for(gnu)["identity"]["digest"]
    expect(digest["blob_sha256"]).to eq("0" * 64)
    expect(digest["tree_hash"]).to eq("sha256:#{"0" * 64}")
  end

  it "declares the engine line the dispatcher matches (spec 03 §2.2)" do
    provides = manifest_for(gnu)["provides"]
    expect(provides).to eq(
      "provides" => {
        "engine" => "ruby",
        "version" => "3.4.8",
        "abi_line" => "3.4",
        "platform" => "x86_64-linux-gnu"
      },
      "built_from" => { "src_sha256" => src_sha256, "patch_set" => "v0.2.24" },
      "capabilities" => { "exec" => true, "read" => true, "runtime" => true }
    )
  end

  it "declares the CA bundle for class-R materialization on msys only" do
    expect(manifest_for(msys)["materialize"]).to eq(["/ssl/cert.pem"])
    expect(manifest_for(msys)["provides"]["provides"]["platform"]).to eq("x86_64-windows-ucrt")
    expect(manifest_for(gnu)).not_to have_key("materialize")
  end

  # The spec 22 §2.1 alias channel (the packed-mn#251 windows 126): the
  # msys image declares the toolchain support-DLL set so the driver's boot
  # pass materializes it and leads PATH with it — the OS's own search
  # order then binds a payload ext's libwinpthread-1.dll import. The
  # declaration flows from SupportDlls, the single owner; POSIX images
  # omit the key (the channel is a windows contract).
  it "declares the support-DLL library_aliases on msys only (spec 22 §2.1)" do
    expect(manifest_for(msys)["library_aliases"]).to eq(
      TebakoRuntimeBuilder::SupportDlls.alias_declarations
    )
    expect(manifest_for(msys)["library_aliases"].map { |a| a["name"] })
      .to include("libwinpthread-1.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll")
    expect(manifest_for(gnu)).not_to have_key("library_aliases")
  end

  it "deploys parseable YAML at /__tpkg__/manifest.yaml in the layout tree" do
    Dir.mktmpdir do |tree|
      path = described_class.new(platform: msys, ruby_version: "3.4.8",
                                 tebako_version: "0.16.6", patch_set: "v0.2.24",
                                 src_sha256: src_sha256).deploy(tree)
      expect(path).to eq(File.join(tree, "__tpkg__", "manifest.yaml"))
      loaded = YAML.load_file(path)
      expect(loaded["materialize"]).to eq(["/ssl/cert.pem"])
      expect(loaded["identity"]["kind"]).to eq("runtime")
    end
  end
end
