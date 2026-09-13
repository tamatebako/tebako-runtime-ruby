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
    expect(build.fetch("needs")).to eq(%w[compute preflight-containers link-unit roll-source])
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

  # The roll cache keys on the hash of the ROLLED INPUTS (versions.yml +
  # patches/ + schema/ + tools/ — the complete input set of tools/apply),
  # never the ruby branch sha: the determinism contract makes the rolled
  # bytes a pure function of the inputs, so a harness-only ruby commit
  # restores in seconds instead of re-rolling 2.5 GB (and minting the
  # cache-cap pressure that evicts the build-prefix entries). The
  # checkout must precede the cache step — hashFiles needs the tree.
  it "keys the roll cache on the rolled-inputs content hash, never the branch sha" do
    steps = workflow.fetch("jobs").fetch("roll-source").fetch("steps")
    names = steps.map { |step| step["name"].to_s }
    cache = steps.find { |step| step["name"] == "Cache the roll" }
    key = cache.dig("with", "key").to_s
    expect(key).to include("hashFiles('ruby-src/versions.yml'")
    expect(key).not_to include("chain-sha")
    checkout = steps.find { |step| step["name"] == "Checkout tamatebako/ruby (the chain source)" }
    expect(checkout["if"]).to be_nil # always — the key's hashFiles needs the tree
    expect(names.index("Checkout tamatebako/ruby (the chain source)")).to be < names.index("Cache the roll")
  end

  # The staged-unit cache stands in for the published pin while no
  # product release ships the units: keyed on the product + dwarfs-rs
  # SHAs and the recipe hash (never a ruby version, never a ruby branch
  # sha), restored before any source-build step, with every source-build
  # and warmer step gated on the miss — a re-run with an unmoved product
  # tree is a seconds-scale restore, never another fat-LTO build.
  it "restores the staged link unit before any source build" do
    steps = workflow.fetch("jobs").fetch("link-unit").fetch("steps")
    names = steps.map { |step| step["name"].to_s }
    staged = steps.find { |step| step["name"].to_s == "Cache the staged link unit" }
    expect(staged).not_to be_nil
    expect(staged.dig("with", "path")).to eq(".build/link-unit")
    key = staged.dig("with", "key").to_s
    expect(key).to include("${{ matrix.env.os }}", "${{ matrix.env.arch }}",
                           "steps.unit-key.outputs.tebako", "steps.unit-key.outputs.dwarfs")
    expect(key).not_to include("ruby")
    # The key's SHAs come from the checkouts — resolve runs after them.
    expect(names.index("Resolve the link-unit input SHAs"))
      .to be > names.index("Checkout the tebako product repo (the link unit source)")
    # The restored unit gets the same completeness assertion the legs do.
    assertion = steps.find { |step| step["name"].to_s == "Assert the restored staged unit is complete" }
    expect(assertion).not_to be_nil
    expect(assertion["if"].to_s).to include("steps.staged.outputs.cache-hit == 'true'")
    expect(assertion["run"]).to include("libtebako_driver.a", "libtfs.a", "closure")
    # Every builder/warmer gated on the miss, after the cache step.
    builders = steps.select do |step|
      step["name"].to_s.start_with?("Stage the", "Build + stage", "Set up vcpkg", "Setup MSys",
                                    "Install pacman", "Configure the vcpkg", "Restore the vcpkg",
                                    "Cache the cargo", "Cache vcpkg", "Cache the musl")
    end
    expect(builders).not_to be_empty
    builders.each do |step|
      expect(step["if"].to_s).to include("steps.staged.outputs.cache-hit != 'true'"),
                                 "#{step["name"]} must be gated on the staged-unit cache missing"
      expect(names.index(step["name"])).to be > names.index("Cache the staged link unit")
    end
  end

  # Spec 13 §2a's de-rendezvous (roadmap 85): the leg that built a package
  # publishes it and signs its served names IN-LEG — write-once names the
  # leg owns alone, so N legs publish concurrently with zero rendezvous.
  # Locked structurally so the publish can never creep back out into a
  # shared coordinator-side mutation.
  it "publishes and signs in-leg, gated on inputs.publish && !inputs.audit" do
    steps = workflow.fetch("jobs").fetch("build").fetch("steps")
    names = steps.map { |step| step["name"].to_s }
    publish = steps.find { |step| step["name"] == "Publish the leg's runtime package (spec 13 §2a)" }
    sign = steps.find { |step| step["name"] == "Sign the leg's release assets (spec 09 §5)" }
    expect(publish).not_to be_nil
    expect(sign).not_to be_nil
    [publish, sign].each do |step|
      expect(step["if"]).to eq("${{ inputs.publish && !inputs.audit }}")
    end
    # The leg scopes both tools to its own (ruby, platform) slice: the
    # publish reads a one-row expected matrix, the signer a one-stem scope.
    expect(publish.dig("env", "EXPECTED_ENV_MATRIX")).to eq("[${{ toJSON(matrix.env) }}]")
    expect(publish.dig("env", "EXPECTED_RUBY_MATRIX")).to eq("[${{ toJSON(matrix.ruby) }}]")
    expect(publish.dig("env", "TEBAKO_VERSION")).to eq("${{ needs.compute.outputs.tebako-version }}")
    expect(publish.dig("env", "FORCE_REBUILD")).to eq("${{ inputs.force_rebuild && 'true' || 'false' }}")
    expect(publish.dig("env", "TEBAKO_RELEASE_SIGNING_ENABLED")).to eq("${{ vars.TEBAKO_RELEASE_SIGNING_ENABLED }}")
    expect(publish.dig("env", "TEBAKO_RELEASE_SIGNING_KEYID")).to eq("${{ vars.TEBAKO_RELEASE_SIGNING_KEYID }}")
    expect(sign.dig("env", "SIGN_ONLY_STEMS")).to eq(
      "tebako-runtime-${{ needs.compute.outputs.tebako-version }}-${{ matrix.ruby.version }}-${{ matrix.env.host_id }}"
    )
    expect(sign.dig("env", "TEBAKO_RELEASE_SIGNING_KEY")).to eq("${{ secrets.TEBAKO_RELEASE_SIGNING_KEY }}")
    # Both run after the leg's artifact upload (the publish consumes the
    # same workspace bytes the upload ships).
    upload_index = names.index("Upload runtime package")
    expect(names.index(publish["name"])).to be > upload_index
    expect(names.index(sign["name"])).to be > upload_index
  end

  it "accepts publish and force_rebuild as workflow_call inputs" do
    inputs = workflow.dig(true, "workflow_call", "inputs") # YAML 1.1: the `on:` key parses as boolean true
    expect(inputs.dig("publish", "type")).to eq("boolean")
    expect(inputs.dig("publish", "default")).to be(false)
    expect(inputs.dig("force_rebuild", "type")).to eq("boolean")
    expect(inputs.dig("force_rebuild", "default")).to be(false)
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

# The coordinator after spec 13 §2a's de-rendezvous (roadmap 85): the legs
# publish and sign; the ONE release job only audits (read-only) and renders
# + publishes the registry mirror by bot PR. Locked structurally: no
# artifact download, no sign step, no shared-name mutation can creep back.
RSpec.describe "publish coordinator workflow" do
  let(:workflow_path) { File.join(REPO_ROOT, ".github", "workflows", "publish.yml") }
  let(:workflow) { YAML.load_file(workflow_path) }
  let(:release) { workflow.fetch("jobs").fetch("release") }
  let(:release_steps) { release.fetch("steps") }
  let(:release_step_names) { release_steps.map { |step| step["name"].to_s } }

  it "audits + publishes the registry — and never downloads, uploads, or signs a package byte" do
    expect(release.fetch("name")).to eq("Audit the release + publish the registry")
    forbidden = release_steps.select do |step|
      step.fetch("uses", "").to_s.start_with?("actions/download-artifact@") ||
        step["name"].to_s.match?(/\A(Sign|Publish the runtime|Update the release)/)
    end
    expect(forbidden).to be_empty
    expect(release.fetch("timeout-minutes")).to eq(30)
  end

  it "runs the per-platform audit read-only (AUDIT_ONLY=true), threaded with the signing gate" do
    audit = release_steps.find { |step| step["name"] == "Audit the release, per platform" }
    expect(audit).not_to be_nil
    expect(audit.dig("env", "AUDIT_ONLY")).to eq("true")
    expect(audit.dig("env", "TEBAKO_RELEASE_SIGNING_ENABLED")).to eq("${{ vars.TEBAKO_RELEASE_SIGNING_ENABLED }}")
    expect(audit.fetch("run")).to include("./scripts/upload_release.rb")
    expect(audit.fetch("run")).not_to include("FINALIZE_ONLY")
  end

  it "renders and publishes the registry only on publish runs (never audit-only)" do
    render = release_steps.find { |step| step["name"] == "Render the registry entries" }
    publish = release_steps.find { |step| step["name"] == "Publish the registry via pull request" }
    [render, publish].each do |step|
      expect(step).not_to be_nil
      expect(step["if"]).to eq("${{ !inputs.audit }}")
    end
    expect(render.fetch("run")).to include("./tools/registry_update.rb")
    # The registry lands by bot PR against origin/main — git arbitrates.
    expect(publish.fetch("run")).to include("git checkout -b", "origin/main",
                                            "gh pr create", "--body-file", "gh pr merge --auto --squash")
    # The audit precedes the registry work.
    expect(release_step_names.index("Audit the release, per platform"))
      .to be < release_step_names.index("Render the registry entries")
  end

  it "threads publish and force_rebuild from the coordinator into every platform caller" do
    %w[windows linux-gnu linux-musl macos].each do |platform|
      with = workflow.fetch("jobs").fetch(platform).fetch("with")
      expect(with["publish"])
        .to(eq("${{ github.event_name == 'repository_dispatch' || inputs.publish }}"),
            "#{platform} must thread publish")
      expect(with["force_rebuild"])
        .to(eq("${{ inputs.force_rebuild || false }}"), "#{platform} must thread force_rebuild")
    end
  end
end
