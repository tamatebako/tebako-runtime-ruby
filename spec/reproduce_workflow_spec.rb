# frozen_string_literal: true

require "spec_helper"
require "yaml"

# reproduce.yml verifies ONE published release leg: it dispatches the
# platform's thin trigger ON THE RELEASE TAG's ref, watches the build,
# and diffs the rebuilt bytes against the published anchors. The
# structural guards locked here are the CodeQL
# actions/cache-poisoning/direct-cache lesson (the first shape threaded
# an input-selected ref into _build-platform.yml's checkouts — inside
# jobs that write the shared build caches — and the code-scanning gate
# failed): an untrusted-ref checkout and a cache write must never share
# a job. The tag-ref dispatch removes the taint by construction: the
# tag's own pipeline runs with event-ref checkouts, and its cache writes
# land in the tag's own scope, never the default branch's.
RSpec.describe "reproduce workflow" do
  let(:workflow_path) { File.join(REPO_ROOT, ".github", "workflows", "reproduce.yml") }
  let(:workflow) { YAML.load_file(workflow_path) }
  let(:text) { File.read(workflow_path) }

  it "takes the leg identity as workflow_dispatch inputs" do
    inputs = workflow.dig(true, "workflow_dispatch", "inputs") # YAML 1.1: the `on:` key parses as boolean true
    expect(inputs.dig("tag", "required")).to be(true)
    expect(inputs.dig("ruby_version", "required")).to be(true)
    expect(inputs.dig("platform", "type")).to eq("choice")
    expect(inputs.dig("platform", "options")).to eq(%w[linux-gnu linux-musl macos windows])
    expect(inputs.dig("arch", "type")).to eq("choice")
    expect(inputs.dig("arch", "options")).to eq(%w[x86_64 arm64])
  end

  # The rebuild rides a tag-ref dispatch of the thin trigger. A `uses:`
  # call into the reusable workflow with an input-selected ref is the
  # exact CodeQL class — locked out structurally.
  it "never calls the reusable build workflow (no input-selected ref inside its cache-writing jobs)" do
    expect(text).not_to include("uses: ./.github/workflows/_build-platform.yml")
  end

  # The one input-ref'd checkout in this file is the era job's
  # `ref: ${{ inputs.tag }}`. That job (and every other job here) must
  # stay cache-free so the checkout can never share a job with a cache
  # write — the query's sink is any actions/cache(/save) step.
  it "carries no actions/cache step anywhere" do
    expect(text).not_to match(%r{uses:\s+actions/cache})
  end

  it "dispatches the platform trigger ON THE TAG REF and watches the run with --exit-status" do
    rebuild = workflow.fetch("jobs").fetch("rebuild")
    expect(rebuild.fetch("needs")).to eq("era")
    dispatch = rebuild.fetch("steps").find { |step| step.fetch("id", "") == "dispatch" }
    expect(dispatch.fetch("run")).to include('gh workflow run "$wf" --repo "$repo" --ref "$TAG"',
                                             '-f ruby_filter="$RUBY_VERSION"', '-f arch_filter="$ARCH"')
    watch = rebuild.fetch("steps").find { |step| step["name"].to_s.start_with?("Watch the build run") }
    expect(watch.fetch("run")).to include("--exit-status")
    # The run id flows to the verdict job — its artifact download is
    # cross-run (the build is a dispatched run, not a job in this one).
    expect(rebuild.dig("outputs", "run_id")).to eq("${{ steps.dispatch.outputs.run_id }}")
    verdict = workflow.fetch("jobs").fetch("verdict")
    expect(verdict.fetch("needs")).to contain_exactly("era", "rebuild")
    render = verdict.fetch("steps").find { |step| step["name"] == "Render the verdict" }
    expect(render.dig("env", "REBUILD_RUN_ID")).to eq("${{ needs.rebuild.outputs.run_id || '' }}")
  end

  # publish defaults to false on the dispatched trigger, and no job here
  # may hold a release-mutating grant — the verification touching the
  # release must be impossible by permission, not by convention.
  it "holds no release-mutating grant anywhere" do
    forbidden = %w[contents packages id-token attestations]
    maps = [workflow.fetch("permissions", {})] +
           workflow.fetch("jobs").map { |_name, job| job.fetch("permissions", {}) }
    maps.each do |perms|
      perms.each do |scope, level|
        expect(forbidden.include?(scope) && level == "write").to be(false),
              "a release-mutating grant crept in: #{scope}: #{level}"
      end
    end
  end

  # The weekly watch verifies the witness leg the arc's E2 twin-run
  # proved (runs 44983654950 + 45000701327). Repinning is a deliberate,
  # spec-visible act tied to matrix.json's tidy vocabulary.
  it "pins the weekly watch's witness leg (repin deliberately)" do
    weekly = workflow.fetch("jobs").fetch("weekly-watch")
    run = weekly.fetch("steps").map { |step| step["run"].to_s }.join("\n")
    expect(run).to include("gh workflow run reproduce.yml")
    expect(run).to include("-f ruby_version=4.0.9", "-f platform=linux-gnu", "-f arch=x86_64")
    # The latest NON-SHARD release tag only (shard tags carry a suffix).
    expect(run).to include('^v[0-9]+\.[0-9]+\.[0-9]+$')
  end
end
