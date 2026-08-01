# frozen_string_literal: true

require "spec_helper"
require "fileutils"

# Spec 18 C1/S49: the mount root flows from the source tarball's
# tebako-mount-root manifest (tamatebako/ruby is the single owner). A
# tarball without the manifest is a pre-era source -- a named refusal
# with exit 132, never a fallback to the platform convention. The empty
# manifest keeps its own named error (131).
RSpec.describe TebakoRuntimeBuilder::MountRoot do
  let(:staging_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(staging_dir)
  end

  # A minimal tfs-ruby-<version>-src.tar.gz fixture: one source-tree
  # directory, the manifest included only when `manifest` is given.
  def make_tarball(manifest: "/__tfs__\n")
    tree = File.join(staging_dir, "ruby-3.3.7")
    FileUtils.mkdir_p(tree)
    File.write(File.join(tree, "configure"), "# stub\n")
    File.write(File.join(tree, TebakoRuntimeBuilder::MountRoot::MANIFEST), manifest) unless manifest.nil?
    tarball = File.join(staging_dir, "tfs-ruby-3.3.7-src.tar.gz")
    system("tar", "-czf", tarball, "-C", staging_dir, "ruby-3.3.7") or raise "tar fixture failed"
    tarball
  end

  it "reads the mount root from the tarball's tebako-mount-root manifest" do
    expect(described_class.new(make_tarball).read).to eq("/__tfs__")
  end

  it "passes the msys drive-letter root form through unchanged" do
    expect(described_class.new(make_tarball(manifest: "A:/t\n")).read).to eq("A:/t")
  end

  it "refuses a tarball without the manifest by name, with exit 132" do
    expect { described_class.new(make_tarball(manifest: nil)).read }
      .to raise_error(TebakoRuntimeBuilder::Error) do |error|
        expect(error.message).to eq(
          "pre-era source tarball (no tebako-mount-root manifest) — roll a new one with tamatebako/ruby ≥ v0.2.13"
        )
        expect(error.error_code).to eq(132)
      end
  end

  it "keeps the empty-manifest refusal (131)" do
    expect { described_class.new(make_tarball(manifest: "\n")).read }
      .to raise_error(TebakoRuntimeBuilder::Error) do |error|
        expect(error.message).to match(/empty tebako-mount-root/)
        expect(error.error_code).to eq(131)
      end
  end
end
