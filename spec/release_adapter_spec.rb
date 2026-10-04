# frozen_string_literal: true

require "spec_helper"

require "tebako_release"
require_relative "../scripts/release_adapter"

# The adapter's lang_name is the tebako-release gem's compose/audit hook for
# tebako#716's language segment. The gate reads the version being published
# in THIS run off TEBAKO_VERSION — the exact channel the gem's uploader
# reads (@version, uploader.rb) — so a catalog/mop-up rerun of a <= 0.16.32
# line composes old-era names even with this adapter merged, and a 0.17.0+
# run on any ref composes new-era names. Locked here so the gate can never
# drift to a repo-wide constant (the VERSION file) or an unconditional
# "ruby".
RSpec.describe RubyReleaseAdapter do
  subject(:adapter) { described_class.new }

  around do |example|
    saved = ENV.fetch("TEBAKO_VERSION", nil)
    example.run
  ensure
    saved.nil? ? ENV.delete("TEBAKO_VERSION") : ENV["TEBAKO_VERSION"] = saved
  end

  it "declares the language segment when the run publishes a >= 0.17.0 line" do
    ENV["TEBAKO_VERSION"] = "0.17.0"
    expect(adapter.lang_name).to eq("ruby")
  end

  it "declares nil (the pre-tebako#716 spelling) when the run publishes a <= 0.16.32 line" do
    ENV["TEBAKO_VERSION"] = "0.16.32"
    expect(adapter.lang_name).to be_nil
  end

  it "fails named when the run's version channel is unset (the uploader's own contract)" do
    ENV.delete("TEBAKO_VERSION")
    expect { adapter.lang_name }.to raise_error(KeyError, /TEBAKO_VERSION/)
  end
end
