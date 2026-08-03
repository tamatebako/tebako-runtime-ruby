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
