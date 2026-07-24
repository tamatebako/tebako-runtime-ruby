# frozen_string_literal: true

require "spec_helper"

RSpec.describe TebakoRuntimeBuilder::RubyVersion do
  subject(:rv) { described_class.new("3.3.7") }

  it "computes the API version" do
    expect(rv.api_version).to eq("3.3.0")
  end

  it "computes the lib version" do
    expect(rv.lib_version).to eq("330")
  end

  it "exposes the version gates" do
    expect(rv.ruby3x?).to be(true)
    expect(rv.ruby31?).to be(true)
    expect(rv.ruby32?).to be(true)
    expect(rv.ruby32only?).to be(false)
    expect(rv.ruby33?).to be(true)
    expect(rv.ruby33only?).to be(true)
    expect(rv.ruby3x7?).to be(true)
    expect(rv.ruby34?).to be(false)
  end

  it "treats 3.2.x as ruby32only" do
    rv32 = described_class.new("3.2.4")
    expect(rv32.ruby32only?).to be(true)
    expect(rv32.ruby33?).to be(false)
    expect(rv32.ruby3x7?).to be(false)
    expect(described_class.new("3.2.7").ruby3x7?).to be(true)
  end

  it "treats 4.x lines as ruby34 without string-indexing fallout" do
    rv40 = described_class.new("4.0.6")
    expect(rv40.ruby34?).to be(true)
    expect(rv40.ruby3x7?).to be(true)
    expect(rv40.ruby33only?).to be(false)
    expect(rv40.api_version).to eq("4.0.0")
    expect(rv40.lib_version).to eq("400")
  end

  it "rejects malformed versions" do
    expect { described_class.new("3.3") }.to raise_error(TebakoRuntimeBuilder::Error, /Invalid Ruby version format/)
  end
end
