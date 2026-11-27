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
require "json"
require "yaml"

RSpec.describe TebakoRuntimeBuilder::Builder do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:exe) { File.join(@dir, "tebako-runtime-0.17.15-ruby-3.4.8-x86_64-linux-gnu") }
  let(:assets) { [["/tmp/tfs-ruby-3.4.8-src.tar.gz", "ab" * 32]] }

  def builder(output: exe)
    described_class.new(repo_root: REPO_ROOT, ruby_version: "3.4.8", tebako_version: "0.17.15",
                        prefix: File.join(@dir, "prefix"), output: output)
  end

  def sidecar
    YAML.safe_load_file("#{exe}.contract.yaml")
  end

  describe "#write_contract_sidecar" do
    before { File.write(exe, "exe-bytes") }

    it "records the pre-signing exe digest and folds the verified source pairs" do
      builder.write_contract_sidecar(assets)
      card = sidecar
      expect(card).to include("contract_era" => 2, "image_layout" => 1)
      expect(card["built_from"]).to include(
        "release" => TebakoRuntimeBuilder::SourceFetcher::DEFAULT_RELEASE,
        "sources" => [{ "name" => "tfs-ruby-3.4.8-src.tar.gz", "sha256" => "ab" * 32 }],
        # The reproducibility anchor the E1/E2 re-run diffs: the bytes
        # BEFORE macOS/windows signing rewrite the exe.
        "exe_sha256_presign" => Digest::SHA256.hexdigest("exe-bytes")
      )
    end

    it "omits built_from.toolchain when TEBAKO_BUILD_TOOLCHAIN_JSON is unset (a local build)" do
      TebakoRuntimeBuilder::BuildHelpers.with_env("TEBAKO_BUILD_TOOLCHAIN_JSON" => nil) do
        builder.write_contract_sidecar(assets)
      end
      expect(sidecar["built_from"]).not_to have_key("toolchain")
    end

    it "folds the leg's toolchain identity verbatim when the CI legs set it" do
      toolchain = { "os" => "ubuntu-20.04", "cc" => "gcc 11.5.0", "container" => "ghcr.io/x@sha256:#{"cd" * 32}" }
      TebakoRuntimeBuilder::BuildHelpers.with_env("TEBAKO_BUILD_TOOLCHAIN_JSON" => JSON.generate(toolchain)) do
        builder.write_contract_sidecar(assets)
      end
      expect(sidecar["built_from"]["toolchain"]).to eq(toolchain)
    end

    it "refuses a malformed TEBAKO_BUILD_TOOLCHAIN_JSON by name" do
      TebakoRuntimeBuilder::BuildHelpers.with_env("TEBAKO_BUILD_TOOLCHAIN_JSON" => "{not json") do
        expect { builder.write_contract_sidecar(assets) }
          .to raise_error(TebakoRuntimeBuilder::Error, /TEBAKO_BUILD_TOOLCHAIN_JSON is not valid JSON/)
      end
    end

    it "refuses by name when the finalize pass left no executable" do
      missing = File.join(@dir, "no-such-runtime")
      expect { builder(output: missing).write_contract_sidecar(assets) }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not exist/)
    end
  end

  describe "#write_abi_sidecar" do
    # The floor flows from the repo's own contract.yml (bump-proof: a
    # floor move must not require a spec edit). OFF_FLOOR is any major
    # that is NOT the floor's — the drift-window spelling shape.
    let(:floor_major) do
      TebakoRuntimeBuilder::Contract.new(File.join(REPO_ROOT, "contract.yml")).darwin_kernel_major
    end
    let(:off_floor_major) { floor_major + 1 }

    def stage_rbconfig(archdir)
      dir = File.join(@dir, "prefix", "o", "s", "lib", "ruby", "4.0.0", archdir)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "rbconfig.rb"), "# rbconfig fixture\n")
    end

    def abi_text
      File.read("#{exe}.abi")
    end

    it "hyphenates the shipped archdir's darwin segment (spec 05 §5's abi line)" do
      stage_rbconfig("arm64-darwin#{floor_major}")
      builder.write_abi_sidecar
      expect(abi_text).to eq("arm64-darwin-#{floor_major}\n")
    end

    it "accepts the contract floor's darwin major (N ↔ darwin N+9, derived — never hardcoded)" do
      stage_rbconfig("x86_64-darwin#{floor_major}")
      expect { builder.write_abi_sidecar }.not_to raise_error
      expect(abi_text).to eq("x86_64-darwin-#{floor_major}\n")
    end

    it "refuses a darwin major that is not the contract floor's — the drift-window guard, naming both" do
      stage_rbconfig("arm64-darwin#{off_floor_major}")
      expect { builder.write_abi_sidecar }
        .to raise_error(TebakoRuntimeBuilder::Error,
                        /'arm64-darwin-#{off_floor_major}'.*not the contract floor's #{floor_major}/)
      expect(File.exist?("#{exe}.abi")).to be(false)
    end

    it "leaves a non-darwin archdir untouched (no floor applies)" do
      stage_rbconfig("x86_64-linux")
      builder.write_abi_sidecar
      expect(abi_text).to eq("x86_64-linux\n")
    end

    it "refuses by name when the layout tree carries no rbconfig" do
      expect { builder.write_abi_sidecar }
        .to raise_error(TebakoRuntimeBuilder::Error, /no rbconfig\.rb under/)
    end
  end
end
