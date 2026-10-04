# frozen_string_literal: true

require "spec_helper"

# tebako#716's era gate (spec 05 §2's era law): the language segment of the
# runtime package name exists ONLY on tebako lines >= 0.17.0 — the <= 0.16.32
# lines are immutable (sha256-pinned in the live registries) and compose the
# lang-less spelling forever. PackageName is the gate's single owner; the
# builder's default output and the release adapter's lang_name both flow it.
RSpec.describe TebakoRuntimeBuilder::PackageName do
  it "declares no language segment on the immutable old-era lines" do
    expect(described_class.lang_segment("0.15.9")).to be_nil
    expect(described_class.lang_segment("0.16.32")).to be_nil
    expect(described_class.lang_infix("0.16.32")).to eq("")
  end

  it "declares the language segment from 0.17.0 on, boundary included" do
    expect(described_class.lang_segment("0.17.0")).to eq("ruby")
    expect(described_class.lang_infix("0.17.0")).to eq("ruby-")
    expect(described_class.lang_segment("0.17.1")).to eq("ruby")
    expect(described_class.lang_segment("1.0.0")).to eq("ruby")
  end

  it "compares versions numerically, never lexically" do
    # "0.9.0" sorts after "0.17.0" lexically; numerically it is old-era.
    expect(described_class.lang_segment("0.9.0")).to be_nil
  end

  it "fails named on a malformed version (never a silent old-era fallback)" do
    expect { described_class.lang_segment("not-a-version") }.to raise_error(ArgumentError)
  end
end
