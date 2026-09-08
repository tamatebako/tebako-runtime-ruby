# frozen_string_literal: true

require "spec_helper"
require_relative "../build/lib/tebako_runtime_builder/capabilities"

RSpec.describe TebakoRuntimeBuilder::Capabilities do
  describe ".yjit (the truth table)" do
    it "is on for non-windows legs of ruby >= 3.2, any arch" do
      expect(described_class.yjit(ruby_version: "3.2.11", platform_id: "macos-arm64")).to be(true)
      expect(described_class.yjit(ruby_version: "3.3.12", platform_id: "linux-gnu-x86_64")).to be(true)
      expect(described_class.yjit(ruby_version: "3.4.10", platform_id: "linux-musl-arm64")).to be(true)
      expect(described_class.yjit(ruby_version: "4.0.6", platform_id: "macos-x86_64")).to be(true)
    end

    it "is on for the 3.1 line on x86_64 only" do
      expect(described_class.yjit(ruby_version: "3.1.6", platform_id: "linux-gnu-x86_64")).to be(true)
      expect(described_class.yjit(ruby_version: "3.1.6", platform_id: "linux-musl-x86_64")).to be(true)
    end

    it "is off on windows (no mingw-x64 arm upstream)" do
      expect(described_class.yjit(ruby_version: "3.3.12", platform_id: "windows-ucrt64")).to be(false)
      expect(described_class.yjit(ruby_version: "4.0.6", platform_id: "windows-ucrt64")).to be(false)
    end

    it "is off on the 3.1 line's non-x86_64 legs" do
      expect(described_class.yjit(ruby_version: "3.1.6", platform_id: "macos-arm64")).to be(false)
      expect(described_class.yjit(ruby_version: "3.1.6", platform_id: "linux-gnu-arm64")).to be(false)
    end
  end

  describe ".for (the manifest value)" do
    it "wraps yjit in an array, empty when off" do
      expect(described_class.for(ruby_version: "3.3.12", platform_id: "macos-arm64")).to eq(["yjit"])
      expect(described_class.for(ruby_version: "3.3.12", platform_id: "windows-ucrt64")).to eq([])
    end
  end

  # Parity with boot smoke is by construction: BootSmoke#derived_yjit_state
  # delegates to Capabilities.yjit (the yjit-scenario spec exercises the
  # expectation against real legs); the manifest writer calls
  # Capabilities.for. One truth table, two callers -- the versions
  # catalog's plan 04 contract.
end
