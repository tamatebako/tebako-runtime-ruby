# frozen_string_literal: true

require "spec_helper"
require "yaml"

# The .build cache-key composition is a contract between the compute job
# (which emits per-version src_sha256 into the ruby matrix) and the build
# job (which keys the cache on it). Fault isolation: the key carries the
# version's OWN source tarball sha256, so a per-line source change
# re-spends only that line's legs; CACHE_VER stays the manual escape
# hatch. Locked here so a drift between the two jobs fails loudly.
RSpec.describe "build-platform reusable workflow" do
  let(:workflow_path) { File.join(REPO_ROOT, ".github", "workflows", "_build-platform.yml") }
  let(:workflow) { YAML.load_file(workflow_path) }

  it "keys the .build cache on the version's own source tarball sha256" do
    cache_step = workflow.fetch("jobs").fetch("build").fetch("steps")
                         .find { |step| step["name"] == "Cache build prefix" }
    expect(cache_step.dig("with", "key")).to eq(
      "tebako-runtime-${{ matrix.env.os }}-${{ matrix.env.arch }}-${{ matrix.ruby.version }}-" \
      "${{ needs.compute.outputs.tebako-version }}-${{ matrix.ruby.src_sha256 }}-v${{ env.CACHE_VER }}"
    )
  end

  it "consumes the object-shaped ruby matrix rows everywhere (no bare matrix.ruby left)" do
    expect(File.read(workflow_path)).not_to include("${{ matrix.ruby }}")
  end

  # The native closure depends on the platform triplet only — staging it
  # inside the ruby matrix paid the full native build per version (the
  # catalog's 22 legs per platform-arch; windows paid it per leg before
  # the hoist). The link-unit job stages ONCE per platform-arch from a
  # ruby-free matrix — every platform, windows included — and the build
  # legs download.
  it "stages the link unit once per platform-arch (a ruby-free matrix)" do
    link_unit = workflow.fetch("jobs").fetch("link-unit")
    matrix = link_unit.fetch("strategy").fetch("matrix")
    expect(matrix).to eq("env" => "${{fromJson(needs.compute.outputs.link-unit-matrix)}}")
    expect(link_unit["if"]).not_to include("windows")
  end

  it "keys no link-unit cache on a ruby version" do
    workflow.fetch("jobs").fetch("link-unit").fetch("steps").each do |step|
      key = step.dig("with", "key")
      expect(key).not_to include("ruby") if key
    end
  end

  # Triplet-scoping is the cache-correctness rule: rust-cache's default key
  # (job + lockfile hashes) names no triplet, so two triplets on a shared
  # job name would silently share one target-dir entry. Every cargo cache
  # in the workflow keys on (os, arch) explicitly — the same key shape the
  # POSIX link-unit job carries.
  it "keys every cargo target cache on the platform triplet (never the default)" do
    workflow.fetch("jobs").each_value do |job|
      job.fetch("steps", []).each do |step|
        next unless step.fetch("uses", "").to_s.start_with?("Swatinem/rust-cache@")

        key = step.dig("with", "key").to_s
        expect(key).to include("${{ matrix.env.os }}")
        expect(key).to include("${{ matrix.env.arch }}")
      end
    end
  end

  it "has the build legs download the staged unit, never rebuild it per ruby" do
    build = workflow.fetch("jobs").fetch("build")
    expect(build.fetch("needs")).to eq(%w[compute preflight-containers link-unit])
    steps = build.fetch("steps")
    download = steps.find { |step| step["name"] == "Download the staged link unit" }
    expect(download["if"]).to be_nil # every platform downloads, windows included
    expect(download.dig("with", "path")).to eq(".build/link-unit")
    assertion = steps.find { |step| step["name"] == "Assert the staged link unit is complete" }
    expect(assertion["if"]).to be_nil
    expect(assertion["run"]).to include("libtebako_driver.a", "libtfs.a", "closure")
    per_leg_rebuilds = steps.select do |step|
      ["Checkout the tebako product repo (the link unit source)",
       "Checkout dwarfs-rs (link-unit sibling path dep)",
       "Stage the POSIX link unit",
       "Build + stage the windows-gnu link unit",
       "Set up vcpkg for the link unit"].include?(step["name"])
    end
    expect(per_leg_rebuilds).to be_empty
  end

  # The pin-hit consumption path (contract.yml link_unit_release): the
  # link-unit job attempts the published-unit download first, and every
  # source-build step is gated on the miss — a pinned run is a ~30 s
  # download, never a closure rebuild.
  it "attempts the published link-unit download before any source build" do
    steps = workflow.fetch("jobs").fetch("link-unit").fetch("steps")
    names = steps.map { |step| step["name"].to_s }
    download_index = names.index("Download the published link unit (pin hit)")
    expect(download_index).not_to be_nil
    builders = steps.select { |step| step["name"].to_s.start_with?("Stage the", "Build + stage") }
    expect(builders).not_to be_empty
    builders.each do |step|
      expect(step["if"].to_s).to include("steps.published.outputs.hit != 'true'"),
                                 "#{step["name"]} must be gated on the download missing"
      expect(names.index(step["name"])).to be > download_index
    end
  end

  # The publish job is GONE from the per-platform builder: N platform runs
  # sharing one publish group displaced (cancelled) queued publishes. The
  # coordinator (publish.yml) publishes from a single release job. Locked
  # structurally so the per-platform publish can never creep back in.
  it "carries no publish job (publishing is the coordinator's single release job)" do
    expect(workflow.fetch("jobs")).not_to have_key("publish")
  end

  it "exposes the compute matrices and version as workflow_call outputs for the coordinator" do
    outputs = workflow.dig(true, "workflow_call", "outputs") # YAML 1.1: the `on:` key parses as boolean true
    %w[run env-matrix ruby-matrix tebako-version].each do |key|
      expect(outputs).to have_key(key)
    end
  end

  # The boot smoke gates the upload (owner directive: a broken runtime
  # fails its own pipeline, never ships): every leg runs a boot-smoke step
  # AFTER its build and BEFORE the artifact upload, and a red step skips
  # the upload. Locked structurally so a workflow edit can never silently
  # un-gate the upload.
  it "gates the artifact upload behind a boot-smoke step on every leg" do
    steps = workflow.fetch("jobs").fetch("build").fetch("steps")
    names = steps.map { |step| step["name"].to_s }
    smoke_indexes = names.each_index.select { |i| names[i].start_with?("Boot-smoke the fresh runtime") }
    upload_index = names.index("Upload runtime package")
    expect(smoke_indexes).not_to be_empty
    expect(upload_index).not_to be_nil
    expect(smoke_indexes.max).to be < upload_index
  end

  # The openssl native-extension canary compares the probed state against
  # the expectation recorded per leg (issue 40 tripwire): every boot-smoke
  # step must carry the record.
  it "records the openssl canary expectation on every boot-smoke step" do
    steps = workflow.fetch("jobs").fetch("build").fetch("steps")
    smoke_steps = steps.select { |step| step["name"].to_s.start_with?("Boot-smoke the fresh runtime") }
    expect(smoke_steps).not_to be_empty
    smoke_steps.each do |step|
      expect(step.dig("env", "TEBAKO_SMOKE_EXPECT_OPENSSL")).to(satisfy { |value| %w[ok fail].include?(value) })
    end
  end
end
