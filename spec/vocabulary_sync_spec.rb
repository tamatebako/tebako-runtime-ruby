# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../tools", __dir__))
require "sync_matrix_vocabulary"

# The fetch seam double: ref -> an object answering sha256sums (the
# SourceFetcher shape), so a spec never touches the network.
class FakeSumsFetcher
  def initialize(sums)
    @sums = sums
  end

  attr_reader :sums
  alias sha256sums sums
end

# The pin-bump vocabulary sync (tools/sync_matrix_vocabulary.rb): the
# factory's dispatch vocabulary (matrix.json ruby.catalog/full/tidy) follows
# the source factory's PUBLISHED release index (the release's SHA256SUMS
# asset), in delta mode — only versions a bump newly offers are admitted.
RSpec.describe VocabularySync do
  def sums_content(versions)
    lines = versions.flat_map do |v|
      ["#{"a" * 64}  tfs-ruby-#{v}-src.tar.gz",
       "#{"b" * 64}  tfs-ruby-#{v}-src-linux-musl.tar.gz",
       "#{"c" * 64}  tfs-ruby-#{v}-src-msys-pass1.tar.gz",
       "#{"d" * 64}  tfs-ruby-#{v}-src-msys-pass2.tar.gz"]
    end
    "#{lines.join("\n")}\n"
  end

  def write_sums(dir, tag, versions)
    path = File.join(dir, "SHA256SUMS-#{tag}")
    File.write(path, sums_content(versions))
    path
  end

  def matrix_doc
    { "ruby" => { "catalog" => %w[3.3.3 3.3.12 4.0.6], "full" => %w[3.3.12 4.0.6], "tidy" => %w[3.3.12 4.0.6] } }
  end

  def with_matrix
    Dir.mktmpdir do |dir|
      path = File.join(dir, "matrix.json")
      File.write(path, "#{JSON.pretty_generate(matrix_doc)}\n")
      yield path, dir
    end
  end

  def sync_for(matrix_path, stdout: StringIO.new)
    described_class.new(matrix_path: matrix_path, stdout: stdout)
  end

  describe "#versions_for" do
    it "derives the published version set from a SHA256SUMS file, base assets only" do
      Dir.mktmpdir do |dir|
        sums = write_sums(dir, "v0.2.38", %w[3.3.7 3.3.12 4.0.6 4.0.7])
        expect(sync_for("unused").versions_for(sums)).to eq(%w[3.3.7 3.3.12 4.0.6 4.0.7])
      end
    end

    it "reads a release tag's published index through the fetcher seam" do
      fetcher = lambda do |release|
        raise "unexpected release #{release}" unless release == "v0.2.38"

        FakeSumsFetcher.new({ "tfs-ruby-4.0.7-src.tar.gz" => "a" * 64 })
      end
      sync = described_class.new(matrix_path: "unused", fetcher_factory: fetcher, stdout: StringIO.new)
      expect(sync.versions_for("v0.2.38")).to eq(["4.0.7"])
    end

    it "fails by name when a release tag's index is unreadable" do
      fetcher = ->(_release) { raise TebakoRuntimeBuilder::Error.new("404 Not Found fetching SHA256SUMS", 122) }
      sync = described_class.new(matrix_path: "unused", fetcher_factory: fetcher, stdout: StringIO.new)
      expect { sync.versions_for("v9.9.9") }
        .to raise_error(/cannot read the published index of v9\.9\.9: 404 Not Found/)
    end
  end

  describe "#sync" do
    it "admits the delta to catalog line-grouped and moves the tracked lines' tips forward" do
      with_matrix do |path, dir|
        old_sums = write_sums(dir, "v0.2.37", %w[3.3.3 3.3.12 4.0.6])
        new_sums = write_sums(dir, "v0.2.38", %w[3.3.3 3.3.12 4.0.6 4.0.7])
        out = StringIO.new
        summary = sync_for(path, stdout: out).sync(old_sums, new_sums)

        expect(summary).to include("catalog += [4.0.7]")
        expect(summary).to include("4.0.6 -> 4.0.7 (full)")
        expect(summary).to include("4.0.6 -> 4.0.7 (tidy)")
        ruby = JSON.parse(File.read(path)).fetch("ruby")
        expect(ruby["catalog"]).to eq(%w[3.3.3 3.3.12 4.0.6 4.0.7])
        expect(ruby["full"]).to eq(%w[3.3.12 4.0.7])
        expect(ruby["tidy"]).to eq(%w[3.3.12 4.0.7])
      end
    end

    it "admits a new minor line to catalog only — full/tidy admission stays a curation decision" do
      with_matrix do |path, dir|
        old_sums = write_sums(dir, "vA", %w[3.3.12 4.0.6])
        new_sums = write_sums(dir, "vB", %w[3.3.12 4.0.6 4.1.0])
        sync_for(path).sync(old_sums, new_sums)

        ruby = JSON.parse(File.read(path)).fetch("ruby")
        expect(ruby["catalog"]).to include("4.1.0")
        expect(ruby["full"]).to eq(%w[3.3.12 4.0.6])
        expect(ruby["tidy"]).to eq(%w[3.3.12 4.0.6])
      end
    end

    it "never moves a tip backward" do
      with_matrix do |path, dir|
        # NEW ships an older patchlevel for a tracked line (a backfill
        # re-roll): the tip stays; catalog gains it after the line's last
        # member (the vocabulary is line-grouped).
        old_sums = write_sums(dir, "vA", %w[3.3.3 3.3.12 4.0.6])
        new_sums = write_sums(dir, "vB", %w[3.3.3 3.3.12 4.0.6 3.3.4])
        sync_for(path).sync(old_sums, new_sums)

        ruby = JSON.parse(File.read(path)).fetch("ruby")
        expect(ruby["catalog"]).to eq(%w[3.3.3 3.3.12 3.3.4 4.0.6])
        expect(ruby["full"]).to eq(%w[3.3.12 4.0.6])
      end
    end

    it "no-ops without writing when the delta is empty" do
      with_matrix do |path, dir|
        sums = write_sums(dir, "vA", %w[3.3.12 4.0.6])
        before = File.read(path)
        out = StringIO.new
        summary = sync_for(path, stdout: out).sync(sums, sums)
        expect(summary).to include("no new versions")
        expect(File.read(path)).to eq(before)
      end
    end

    it "no-ops without writing when the delta is already covered" do
      with_matrix do |path, dir|
        old_sums = write_sums(dir, "vA", %w[3.3.3 3.3.12])
        new_sums = write_sums(dir, "vB", %w[3.3.3 3.3.12 4.0.6])
        before = File.read(path)
        summary = sync_for(path).sync(old_sums, new_sums)
        expect(summary).to include("already covered")
        expect(File.read(path)).to eq(before)
      end
    end

    it "--dry-run reports the would-be sync and never writes" do
      with_matrix do |path, dir|
        old_sums = write_sums(dir, "vA", %w[3.3.3 3.3.12 4.0.6])
        new_sums = write_sums(dir, "vB", %w[3.3.3 3.3.12 4.0.6 4.0.7])
        before = File.read(path)
        summary = sync_for(path).sync(old_sums, new_sums, dry_run: true)
        expect(summary).to start_with("[dry-run] would sync:")
        expect(summary).to include("catalog += [4.0.7]")
        expect(File.read(path)).to eq(before)
      end
    end

    it "fails by name when the new ref's index carries no versions" do
      with_matrix do |path, dir|
        old_sums = write_sums(dir, "vA", %w[3.3.12])
        empty = File.join(dir, "SHA256SUMS-empty")
        File.write(empty, "#{"e" * 64}  README\n")
        expect { sync_for(path).sync(old_sums, empty) }
          .to raise_error(/no ruby versions found in the published index/)
      end
    end
  end
end
