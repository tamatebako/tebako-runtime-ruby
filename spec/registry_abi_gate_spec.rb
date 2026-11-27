# frozen_string_literal: true

require "spec_helper"
require "yaml"

require_relative "../tools/registry_abi_gate"

# The ABI continuity gate (publish.yml's registry job — see the class's
# own header for the contract). Driven against fixture registries: main's
# published state and the accumulated render, as the workflow hands them.
RSpec.describe RegistryAbiGate do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_registry(name, versions)
    path = File.join(@dir, "#{name}.yaml")
    registry = { "schema_version" => 1,
                 "payloads" => [{ "name" => "ruby", "kind" => "runtime", "engine" => "ruby",
                                  "versions" => versions }] }
    File.write(path, YAML.dump(registry))
    path
  end

  def darwin_platform(abi)
    { "artifact" => "art", "sha256" => "ab" * 32, "abi" => abi }
  end

  def version_row(version, abi: "arm64-darwin-24", status: nil, extra_platforms: {})
    platforms = { "aarch64-macos" => darwin_platform(abi) }.merge(extra_platforms)
    row = { "version" => version, "platforms" => platforms, "release" => { "ref" => "tfs:github:x:y" } }
    row["status"] = status if status
    row
  end

  def gate(main_versions:, render_versions:)
    described_class.new(
      rendered_path: write_registry("render", render_versions),
      main_path: write_registry("main", main_versions)
    )
  end

  it "passes when every darwin row is stable vs the previous line" do
    stable = [version_row("4.0.9-0.17.15"), version_row("4.0.9-0.17.16")]
    lines = gate(main_versions: stable, render_versions: stable).report(bump: "")
    expect(lines).to eq(["abi continuity gate: 1 darwin row(s) stable vs the previous line — no bump"])
  end

  it "fails closed on an abi move without the knob, naming line, platform, old → new" do
    gate = gate(
      main_versions: [version_row("4.0.9-0.17.15")],
      render_versions: [version_row("4.0.9-0.17.15"), version_row("4.0.9-0.17.16", abi: "arm64-darwin-23")]
    )
    expect { gate.report(bump: "") }.to raise_error(
      RegistryAbiGate::GateError, /1 darwin abi move\(s\) with no abi_bump knob/
    )
    expect(gate.diffs.map(&:to_s)).to eq(
      ["ruby line=4.0.9 platform=aarch64-macos: 4.0.9-0.17.15 spells arm64-darwin-24 " \
       "→ 4.0.9-0.17.16 spells arm64-darwin-23"]
    )
  end

  it "acknowledges the move when the deliberate bump is carried, recording the knob text" do
    lines = gate(
      main_versions: [version_row("4.0.9-0.17.15")],
      render_versions: [version_row("4.0.9-0.17.15"), version_row("4.0.9-0.17.16", abi: "arm64-darwin-23")]
    ).report(bump: "macos:darwin-24->darwin-23 — the e21ac536 triplet pin")
    expect(lines).to eq(
      ["bump acknowledged: ruby line=4.0.9 platform=aarch64-macos: 4.0.9-0.17.15 spells arm64-darwin-24 " \
       "→ 4.0.9-0.17.16 spells arm64-darwin-23",
       "knob: macos:darwin-24->darwin-23 — the e21ac536 triplet pin"]
    )
  end

  it "treats a brand-new ruby line as an introduction, never a bump" do
    lines = gate(
      main_versions: [version_row("3.3.13-0.17.15")],
      render_versions: [version_row("3.3.13-0.17.15"), version_row("4.0.9-0.17.16", abi: "arm64-darwin-23")]
    ).report(bump: "")
    expect(lines.first).to include("no bump")
  end

  it "treats a brand-new darwin platform row on an existing line as an introduction" do
    render_versions = [
      version_row("4.0.9-0.17.15"),
      version_row("4.0.9-0.17.16",
                  extra_platforms: { "x86_64-macos" => darwin_platform("x86_64-darwin-23") })
    ]
    lines = gate(main_versions: [version_row("4.0.9-0.17.15")],
                 render_versions: render_versions).report(bump: "")
    expect(lines.first).to include("no bump")
  end

  it "compares against the newest NON-WITHDRAWN row on main (dead vocabulary is not continuity)" do
    gate = gate(
      main_versions: [version_row("4.0.9-0.17.14"), version_row("4.0.9-0.17.15", status: "withdrawn")],
      render_versions: [version_row("4.0.9-0.17.14"),
                        version_row("4.0.9-0.17.15", status: "withdrawn"),
                        version_row("4.0.9-0.17.16", abi: "arm64-darwin-23")]
    )
    expect(gate.diffs.map(&:to_s)).to eq(
      ["ruby line=4.0.9 platform=aarch64-macos: 4.0.9-0.17.14 spells arm64-darwin-24 " \
       "→ 4.0.9-0.17.16 spells arm64-darwin-23"]
    )
  end

  it "skips rows outside the version grammar (the product reader owns the grammar)" do
    lines = gate(
      main_versions: [version_row("4.0.9-0.17.15")],
      render_versions: [{ "version" => "next", "platforms" => {},
                          "release" => { "ref" => "tfs:github:x:y" } },
                        version_row("4.0.9-0.17.16", abi: "arm64-darwin-23")]
    ).report(bump: "bump")
    expect(lines.grep(/^bump acknowledged:/).size).to eq(1)
  end

  it "names every moved row in one verdict (both darwin arches, sorted)" do
    moved = [
      version_row("4.0.9-0.17.15", extra_platforms: { "x86_64-macos" => darwin_platform("x86_64-darwin-24") }),
      version_row("4.0.9-0.17.16", abi: "arm64-darwin-23",
                                   extra_platforms: { "x86_64-macos" => darwin_platform("x86_64-darwin-23") })
    ]
    gate = gate(main_versions: [moved.first], render_versions: moved)
    expect(gate.diffs.map(&:to_s)).to eq(
      ["ruby line=4.0.9 platform=aarch64-macos: 4.0.9-0.17.15 spells arm64-darwin-24 " \
       "→ 4.0.9-0.17.16 spells arm64-darwin-23",
       "ruby line=4.0.9 platform=x86_64-macos: 4.0.9-0.17.15 spells x86_64-darwin-24 " \
       "→ 4.0.9-0.17.16 spells x86_64-darwin-23"]
    )
  end
end
