#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice and this list of conditions and the following disclaimer in
#    the documentation and/or other materials provided with the distribution.
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "yaml"

# The ABI continuity gate (publish.yml's registry job; docs/build-chain.md
# "The abi gates"). The registry's `abi` segment is resolution truth —
# native-extension payloads constrain BOTH the version line and this line
# (spec 05 §5), and tools/registry_update.rb mirrors the shard's abi
# verbatim (registry MINOR 11, tebako#1047). Nothing between the shard and
# the mirror ever asserted the vocabulary's continuity: the 0.17.16 line's
# e21ac536 triplet pin restored the contract floor's darwin-23 spelling
# after the 0.17.14/0.17.15 darwin-24 drift window (the macos-15 fleet's
# kernel release baked in by config.guess) and a patch line silently broke
# every darwin-24-pressed native payload (the metanorma smoke's
# "Could not find 'ox' (>= 0) among 316 total gem(s)"). A vocabulary move
# is legitimate ONLY as a deliberate act — the same treatment an era
# boundary gets: this gate compares the render's darwin rows against the
# previous line's rows on main and fails closed naming every
# (line, platform, old → new) tuple unless the run carries the abi_bump
# dispatch input, whose text is then recorded into the registry bot PR
# body by the publish step.
#
#   ruby tools/registry_abi_gate.rb <rendered-registry.yaml> <main-registry.yaml> [abi_bump]
#
# Exit 0: no darwin abi moved, or every move is acknowledged by the knob
# (stdout then carries one `bump acknowledged:` line per tuple — the
# publish step embeds them into the PR body). Exit 1: a move with no knob
# (every tuple named, ::error:: prefixed for the runner).
#
# Scope rules (MECE — this gate owns continuity, nothing else):
# - Only darwin rows participate (an abi whose segment spells darwinN):
#   the floor's derivation gate (Builder#assert_abi_floor!) and this
#   gate's fleet-move class are darwin-shaped; linux/windows abi strings
#   carry no kernel segment to drift.
# - A (line × platform) pair absent from main is an INTRODUCTION (a new
#   ruby line or a new platform row), never a bump — pass.
# - A previous row carrying no abi (pre-MINOR-11) declares no vocabulary
#   to continue — pass.
# - `status: withdrawn` rows are dead vocabulary: newest means newest
#   NON-WITHDRAWN on both sides.
# - The version grammar (`<ruby>-<tebako>`, dotted) is enforced upstream
#   (the product reader's `registry validate` runs before this gate in
#   the same job); rows outside it do not participate here.
class RegistryAbiGate
  class GateError < StandardError; end

  VERSION_GRAMMAR = /\A(?<ruby>[\d.]+)-(?<tebako>[\d.]+)\z/
  DARWIN_ABI = /-darwin-\d+\z/

  # One acknowledged (or offending) vocabulary move.
  Bump = Struct.new(:payload, :line, :platform, :old_version, :old_abi, :new_version, :new_abi) do
    def to_s
      "#{payload} line=#{line} platform=#{platform}: #{old_version} spells #{old_abi} " \
        "→ #{new_version} spells #{new_abi}"
    end
  end

  def initialize(rendered_path:, main_path:)
    @rendered = YAML.safe_load_file(rendered_path)
    @main = YAML.safe_load_file(main_path)
  end

  # Every (payload, ruby line, darwin platform) whose newest rendered abi
  # differs from main's newest — sorted for a stable report.
  def diffs
    @diffs ||= collect_moves.sort_by { |bump| [bump.payload, bump.line, bump.platform] }
  end

  # The gate verdict. bump: the abi_bump dispatch input ("" when absent).
  # Returns the lines to print; raises GateError when moves stand
  # unacknowledged.
  def report(bump:)
    moves = diffs
    return ["abi continuity gate: #{row_count} darwin row(s) stable vs the previous line — no bump"] if moves.empty?

    unless bump.to_s.empty?
      lines = moves.map { |move| "bump acknowledged: #{move}" }
      lines << "knob: #{bump}"
      return lines
    end

    warn "::error::an ABI-vocabulary move needs the deliberate abi_bump dispatch input:\n"
    moves.each { |move| warn "::error::  #{move}\n" }
    raise GateError, "#{moves.size} darwin abi move(s) with no abi_bump knob — re-run with the deliberate bump declared"
  end

  private

  # The unacknowledged moves: one per (payload, ruby line, darwin
  # platform) whose render's newest abi moved vs main's newest.
  def collect_moves
    render_lines = darwin_lines(@rendered)
    main_lines = darwin_lines(@main)
    render_lines.filter_map do |key, versions|
      move_for(key, versions, main_lines[key])
    end
  end

  def move_for(key, versions, main_versions)
    return unless main_versions

    new_version, new_abi = newest(versions)
    old_version, old_abi = newest(main_versions)
    return if new_abi == old_abi

    Bump.new(key[0], key[1], key[2], old_version, old_abi, new_version, new_abi)
  end

  def row_count
    darwin_lines(@rendered).size
  end

  # { [payload, ruby_line, platform] => { version => abi } } for every
  # platform row whose abi spells darwin, withdrawn rows excluded.
  def darwin_lines(registry)
    lines = {}
    Array(registry["payloads"]).each do |payload|
      Array(payload["versions"]).each do |version|
        index_version(lines, payload, version)
      end
    end
    lines
  end

  def index_version(lines, payload, version)
    return if version["status"] == "withdrawn"

    grammar = VERSION_GRAMMAR.match(version["version"].to_s)
    return unless grammar

    key = [payload["name"], grammar["ruby"]]
    (version["platforms"] || {}).each do |platform, row|
      index_row(lines, key, version["version"], platform, row)
    end
  end

  def index_row(lines, key, version, platform, row)
    abi = row.is_a?(Hash) ? row["abi"] : nil
    return unless abi&.match?(DARWIN_ABI)

    (lines[[*key, platform]] ||= {})[version] = abi
  end

  # The newest (dotted-compare on the tebako segment — the ruby segment
  # is uniform within one line) [version, abi] of one (line × platform).
  def newest(versions)
    version = versions.keys.max_by { |candidate| candidate.partition("-").last.split(".").map(&:to_i) }
    [version, versions[version]]
  end
end

if __FILE__ == $PROGRAM_NAME
  rendered = ARGV[0]
  main = ARGV[1]
  knob = ARGV[2].to_s
  unless rendered && main
    warn "usage: registry_abi_gate.rb <rendered-registry.yaml> <main-registry.yaml> [abi_bump]"
    exit 64
  end
  begin
    puts RegistryAbiGate.new(rendered_path: rendered, main_path: main).report(bump: knob)
  rescue RegistryAbiGate::GateError, Psych::Exception, Errno::ENOENT => e
    warn e.message
    exit 1
  end
end
