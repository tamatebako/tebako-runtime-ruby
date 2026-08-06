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
  # catalog's 22 legs per platform-arch). The link-unit job stages ONCE
  # per platform-arch from a ruby-free matrix; the build legs download.
  it "stages the link unit once per platform-arch (a ruby-free matrix)" do
    link_unit = workflow.fetch("jobs").fetch("link-unit")
    matrix = link_unit.fetch("strategy").fetch("matrix")
    expect(matrix).to eq("env" => "${{fromJson(needs.compute.outputs.link-unit-matrix)}}")
    expect(link_unit["if"]).to include("inputs.platform != 'windows'")
  end

  it "keys no link-unit cache on a ruby version" do
    workflow.fetch("jobs").fetch("link-unit").fetch("steps").each do |step|
      key = step.dig("with", "key")
      expect(key).not_to include("ruby") if key
    end
  end

  it "has the build legs download the staged unit, never rebuild it per ruby" do
    build = workflow.fetch("jobs").fetch("build")
    expect(build.fetch("needs")).to eq(%w[compute link-unit])
    steps = build.fetch("steps")
    download = steps.find { |step| step["name"] == "Download the staged link unit" }
    expect(download["if"]).to eq("matrix.env.os != 'windows'")
    expect(download.dig("with", "path")).to eq(".build/link-unit")
    assertion = steps.find { |step| step["name"] == "Assert the staged link unit is complete" }
    expect(assertion["if"]).to eq("matrix.env.os != 'windows'")
    expect(assertion["run"]).to include("libtebako_driver.a", "libtfs.a", "closure")
    per_leg_rebuilds = steps.select do |step|
      step["if"] == "matrix.env.os != 'windows'" &&
        ["Checkout the tebako product repo (the link unit source)",
         "Checkout dwarfs-rs (link-unit sibling path dep)",
         "Stage the POSIX link unit"].include?(step["name"])
    end
    expect(per_leg_rebuilds).to be_empty
  end

  # The publish job downloads THIS platform's artifacts only and the
  # publishes serialize globally — the manifest merge is read-modify-write,
  # so two publishes must never run at once.
  it "publishes per-platform under the global publish serialization" do
    publish = workflow.fetch("jobs").fetch("publish")
    expect(publish.dig("concurrency", "group")).to eq("publish-runtime-packages")
    expect(publish.dig("concurrency", "cancel-in-progress")).to be(false)
    download = publish.fetch("steps").find { |step| step["name"] == "Download this platform's runtime packages" }
    expect(download.dig("with", "pattern")).to eq("runtime-packages-${{ inputs.platform }}-*")
  end
end
