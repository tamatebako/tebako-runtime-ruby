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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"

RSpec.describe TebakoRuntimeBuilder::SupportDlls do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def fake_prefix(names, prefix: "ucrt64")
    root = File.join(@dir, prefix)
    FileUtils.mkdir_p(File.join(root, "bin"))
    names.each { |name| File.write(File.join(root, "bin", name), "pe") }
    root
  end

  it "owns the alias declaration grammar (spec 03 §2.5) from the single NAMES constant" do
    expect(described_class.alias_declarations).to eq(
      described_class::NAMES.map { |name| { "name" => name, "path" => "/bin/#{name}" } }
    )
    expect(described_class::NAMES).to include("libwinpthread-1.dll")
  end

  it "stages every name into the layout tree's bin" do
    prefix = fake_prefix(described_class::NAMES)
    bin = File.join(@dir, "tree", "bin")

    staged = described_class.new(prefixes: [prefix]).stage(bin)

    expect(staged.map { |path| File.basename(path) }).to eq(described_class::NAMES)
    described_class::NAMES.each do |name|
      expect(File.file?(File.join(bin, name))).to be(true)
    end
  end

  it "fails closed by name when a prefix holds none of the set" do
    prefix = fake_prefix(%w[libwinpthread-1.dll])

    expect { described_class.new(prefixes: [prefix]).stage(File.join(@dir, "tree", "bin")) }
      .to raise_error(TebakoRuntimeBuilder::Error, /libgcc_s_seh-1\.dll.*searched: #{Regexp.escape(prefix)}/)
  end

  it "searches later prefixes for a name the first prefix lacks" do
    incomplete = fake_prefix(%w[libwinpthread-1.dll], prefix: "first")
    complete = fake_prefix(described_class::NAMES, prefix: "second")
    bin = File.join(@dir, "tree", "bin")

    described_class.new(prefixes: [incomplete, complete]).stage(bin)

    described_class::NAMES.each do |name|
      expect(File.file?(File.join(bin, name))).to be(true)
    end
  end

  it "resolves the toolchain prefixes from MSYSTEM_PREFIX then the running ruby" do
    TebakoRuntimeBuilder::BuildHelpers.with_env("MSYSTEM_PREFIX" => "/ucrt64") do
      expect(described_class.toolchain_prefixes.first).to eq("/ucrt64")
      expect(described_class.toolchain_prefixes).to include(RbConfig::CONFIG["prefix"])
    end
  end
end
