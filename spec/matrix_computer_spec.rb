# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "tempfile"

$LOAD_PATH.unshift(File.expand_path("../scripts", __dir__))
require "compute_matrix"

# The fetcher seam (one per pinned release — the pin owns its SHA256SUMS);
# a spec moves a version's tarball by overriding its pin's sums.
class FakeFetcher
  def initialize(sums)
    @sums = sums
  end

  def tarball_sha256(version)
    "sha-#{version}"
  end

  attr_reader :sums
  alias sha256sums sums
end

# The git-diff seam: changed_files serves the staged file list, file_at
# the staged per-(ref, path) contents.
class FakeDiffer
  attr_accessor :files, :contents

  def initialize
    @files = []
    @contents = {}
  end

  def changed_files(_before, _after)
    @files
  end

  def file_at(ref, path)
    @contents.fetch([ref, path], "")
  end
end

RSpec.describe MatrixComputer do
  let(:out_file) { Tempfile.new("github-output") }
  let(:matrix_json) do
    {
      "ruby" => { "tidy" => %w[3.3.12 4.0.6], "full" => %w[3.1.6 3.3.12 4.0.6],
                  "catalog" => %w[3.1.6 3.2.11 3.3.12 4.0.6] },
      "env" => [
        { "host" => "ubuntu-22.04", "container" => "ubuntu-20.04", "os" => "linux-gnu", "arch" => "x86_64" },
        { "host" => "ubuntu-22.04-arm", "container" => "ubuntu-20.04", "os" => "linux-gnu", "arch" => "arm64" },
        { "host" => "ubuntu-22.04", "container" => "alpine", "os" => "linux-musl", "arch" => "x86_64" },
        { "host" => "ubuntu-22.04-arm", "container" => "alpine", "os" => "linux-musl", "arch" => "arm64" },
        { "host" => "macos-14", "container" => nil, "os" => "macos", "arch" => "arm64" },
        { "host" => "macos-15-intel", "container" => nil, "os" => "macos", "arch" => "x86_64" },
        { "host" => "windows-2022", "container" => nil, "os" => "windows", "arch" => "x86_64" }
      ]
    }
  end
  let(:default_sums) do
    { "tfs-ruby-3.3.12-src.tar.gz" => "aaa312",
      "tfs-ruby-4.0.6-src.tar.gz" => "aaa406",
      "SHA256SUMS" => "skip" }
  end
  let(:sums_by_pin) { Hash.new(default_sums) }
  # One fake fetcher per pinned release (the pin owns its SHA256SUMS);
  # a spec moves a version's tarball by overriding its pin's sums.
  let(:fetcher_factory) do
    sums = sums_by_pin
    ->(release) { FakeFetcher.new(sums[release]) }
  end
  let(:differ) { FakeDiffer.new }

  around do |example|
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "matrix.json"), JSON.generate(matrix_json))
      FileUtils.cp(File.expand_path("../.github/build-graph.yaml", __dir__), File.join(dir, "build-graph.yaml"))
      ENV["GITHUB_OUTPUT"] = out_file.path
      ENV["MATRIX_JSON_PATH"] = File.join(dir, "matrix.json")
      ENV["BUILD_GRAPH_PATH"] = File.join(dir, "build-graph.yaml")
      example.run
    end
  ensure
    %w[GITHUB_EVENT_NAME GITHUB_EVENT_PATH MATRIX_RUBY_FILTER MATRIX_ARCH_FILTER GITHUB_OUTPUT MATRIX_JSON_PATH
       BUILD_GRAPH_PATH].each do |k|
      ENV.delete(k)
    end
    out_file.unlink
  end

  def run_computer(platform, event:, files: [], payload: {})
    out_file.truncate(0) # one computation's output per call
    out_file.rewind
    ENV["GITHUB_EVENT_NAME"] = event
    with_event_payload(payload) do
      differ.files = files
      MatrixComputer.new(["--platform", platform], fetcher_factory: fetcher_factory, differ: differ).run
    end
    File.read(out_file.path)
  end

  def with_event_payload(payload)
    payload_file = Tempfile.new("event")
    payload_file.write(JSON.generate(payload))
    payload_file.flush
    ENV["GITHUB_EVENT_PATH"] = payload_file.path
    yield
  ensure
    payload_file&.unlink
  end

  def legs(output)
    output[/^run=(.+)$/, 1]
  end

  def rubies(output)
    JSON.parse(output[/^ruby-matrix=(.+)$/, 1]).map { |r| r["version"] }
  end

  it "computes nothing for a docs-only diff" do
    out = run_computer("windows", event: "push", files: ["docs/notes.md", "README.md"],
                                  payload: { "before" => "a", "after" => "b" })
    expect(legs(out)).to eq("false")
  end

  it "runs every platform's tidy legs on a shared change" do
    %w[windows linux-gnu linux-musl macos].each do |platform|
      out = run_computer(platform, event: "push", files: ["build/lib/tebako_runtime_builder/builder.rb"],
                                   payload: { "before" => "a", "after" => "b" })
      expect(legs(out)).to eq("true"), "#{platform} should run on a shared change"
      expect(rubies(out)).to eq(%w[3.3.12 4.0.6]) # the tidy set
    end
  end

  it "runs only windows on a windows-only change" do
    windows = run_computer("windows", event: "push", files: ["ci/link-unit.sh"],
                                      payload: { "before" => "a", "after" => "b" })
    expect(legs(windows)).to eq("true")

    linux = run_computer("linux-gnu", event: "push", files: ["ci/link-unit.sh"],
                                      payload: { "before" => "a", "after" => "b" })
    expect(legs(linux)).to eq("false")
  end

  it "emits only the changed versions when matrix.json's ruby lists moved" do
    old_matrix = matrix_json
    old_matrix["ruby"]["full"] = %w[3.1.6 3.3.12] # 4.0.6 added in the new matrix
    differ.contents[["a", ".github/matrix.json"]] = JSON.generate(old_matrix)
    out = run_computer("linux-gnu", event: "push", files: [".github/matrix.json"],
                                    payload: { "before" => "a", "after" => "b" })
    expect(legs(out)).to eq("true")
    expect(rubies(out)).to eq(["4.0.6"])
  end

  it "repository_dispatch with no tarball movement runs nothing" do
    differ.contents[["oldsha", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.13"'
    differ.contents[["HEAD", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.14"'
    out = run_computer("macos", event: "repository_dispatch",
                                payload: { "client_payload" => { "base_sha" => "oldsha" } })
    # Both pins resolve to the same sums → no changed versions
    expect(legs(out)).to eq("false")
  end

  it "repository_dispatch builds only the versions whose tarballs moved" do
    differ.contents[["oldsha", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.13"'
    differ.contents[["HEAD", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.14"'
    sums_by_pin["v0.2.14"] = default_sums.merge("tfs-ruby-4.0.6-src.tar.gz" => "bbb406")
    out = run_computer("linux-gnu", event: "repository_dispatch",
                                    payload: { "client_payload" => { "base_sha" => "oldsha" } })
    expect(legs(out)).to eq("true")
    expect(rubies(out)).to eq(["4.0.6"])
  end

  # The pin lands by merge: the push that moves DEFAULT_RELEASE rebuilds
  # exactly the moved versions — no repository_dispatch sender required.
  it "a push that moves the source pin builds exactly the moved versions, on every platform" do
    differ.contents[["a", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.13"'
    differ.contents[["b", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.14"'
    sums_by_pin["v0.2.14"] = default_sums.merge("tfs-ruby-4.0.6-src.tar.gz" => "bbb406")
    %w[windows linux-gnu linux-musl macos].each do |platform|
      out = run_computer(platform, event: "push", files: [MatrixComputer::PIN_FILE],
                                   payload: { "before" => "a", "after" => "b" })
      expect(rubies(out)).to eq(["4.0.6"]), "#{platform} should build the moved version"
    end
  end

  # A fetcher edit that leaves the pin alone is ordinary shared tooling:
  # validate on the tidy set, never "all versions".
  it "a push editing the fetcher without moving the pin validates on the tidy set" do
    differ.contents[["a", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.14" # comment'
    differ.contents[["b", MatrixComputer::PIN_FILE]] = 'DEFAULT_RELEASE = "v0.2.14"'
    out = run_computer("windows", event: "push", files: [MatrixComputer::PIN_FILE],
                                  payload: { "before" => "a", "after" => "b" })
    expect(legs(out)).to eq("true")
    expect(rubies(out)).to eq(%w[3.3.12 4.0.6])
  end

  it "dispatch with a single version runs exactly that version" do
    ENV["MATRIX_RUBY_FILTER"] = "4.0.6"
    out = run_computer("windows", event: "workflow_dispatch", payload: {})
    expect(legs(out)).to eq("true")
    expect(rubies(out)).to eq(["4.0.6"])
  end

  it "dispatch with the catalog set runs the catalog" do
    ENV["MATRIX_RUBY_FILTER"] = "catalog"
    out = run_computer("linux-gnu", event: "workflow_dispatch", payload: {})
    expect(rubies(out)).to eq(%w[3.1.6 3.2.11 3.3.12 4.0.6])
  end

  it "a spec-only change validates on the tidy set" do
    out = run_computer("linux-musl", event: "push", files: ["spec/platform_spec.rb"],
                                     payload: { "before" => "a", "after" => "b" })
    expect(legs(out)).to eq("true")
    expect(rubies(out)).to eq(%w[3.3.12 4.0.6])
  end

  it "env entries carry the model-owned host_id" do
    ENV["MATRIX_RUBY_FILTER"] = "tidy"
    out = run_computer("windows", event: "workflow_dispatch", payload: {})
    env = JSON.parse(out[/^env-matrix=(.+)$/, 1])
    expect(env.first["host_id"]).to eq("windows-ucrt64")
  end
end
