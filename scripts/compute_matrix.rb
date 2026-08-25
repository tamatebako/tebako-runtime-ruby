#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2025-2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "json"
require "logger"
require "yaml"
require "tmpdir"

# The Platform/SourceFetcher model (build/lib) — the source release pin
# (SourceFetcher::DEFAULT_RELEASE) and the SHA256SUMS reads are owned
# there, never re-derived here.
$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_runtime_builder"

# The dependency-tree matrix generator (the multi-staged hierarchy).
#
# Every per-platform workflow's prepare job runs this with --platform.
# The matrix is COMPUTED from .github/build-graph.yaml: a leg runs iff
# something it reads changed — the change set walked against the tree.
#
# Change sets by event:
#   push / pull_request — the git diff (before..after / base..head),
#     walked against shared/platform/publish_only/ignore rules. A shared
#     hit affects every platform; a platform hit affects that platform
#     only; ignore-only and publish_only-only diffs produce no legs
#     (publish/release tooling is consumed at release time, never read
#     by a build leg); validation_only diffs produce the tidy validation
#     legs. A matrix.json change is diffed by CONTENT (which ruby
#     sets/versions and which env entries moved).
#     A diff that moves the source pin (PIN_FILE) rebuilds exactly the
#     versions whose tarballs moved IN THE SCENARIOS THIS PLATFORM
#     CONSUMES — an msys-only source re-roll runs windows legs only,
#     a POSIX-only one leaves windows idle (the per-scenario SHA256SUMS
#     diff; macos consumes the linux-gnu scenario). The pin lands by
#     merge, so the repository_dispatch path below is a compat route,
#     never required.
#   repository_dispatch ("tebako release" — a new source release pin):
#     the pinned release's SHA256SUMS is diffed against the PREVIOUS
#     pin's — only versions whose tarball sha moved are affected, and
#     only on the platforms whose scenario moved.
#   workflow_dispatch — the explicit filters (the three first-class
#     shapes: one version everywhere, one platform all versions, one
#     version on one platform), never the diff.
#
# Usage: compute_matrix.rb --platform <windows|linux-gnu|linux-musl|macos>
# Env:  GITHUB_EVENT_NAME / GITHUB_EVENT_PATH (the payload for diff SHAs),
#       MATRIX_RUBY_FILTER (dispatch: full|tidy|catalog|a,comma,slice),
#       MATRIX_ARCH_FILTER (optional arch within the platform),
#       GITHUB_OUTPUT (the emitted legs/env-matrix/ruby-matrix).
class MatrixComputer # rubocop:disable Metrics/ClassLength
  GRAPH = File.expand_path("../.github/build-graph.yaml", __dir__).freeze
  MATRIX_JSON = File.expand_path("../.github/matrix.json", __dir__).freeze
  # The source pin file: a diff that moves DEFAULT_RELEASE rebuilds exactly
  # the versions whose tarballs moved in the scenarios each platform
  # consumes (the pin lands by merge — no external sender required).
  PIN_FILE = "build/lib/tebako_runtime_builder/source_fetcher.rb"
  PLATFORMS = %w[windows linux-gnu linux-musl macos].freeze
  # The scenario this platform's legs consume (macos reads the base
  # linux-gnu tarball — SourceFetcher.scenario_asset_names is the owner
  # of the platform→asset rule; this map only says which release
  # scenario FEEDS each platform).
  PLATFORM_SCENARIOS = {
    "windows" => "msys",
    "linux-gnu" => "linux-gnu",
    "linux-musl" => "linux-musl",
    "macos" => "linux-gnu"
  }.freeze
  # Asset name → [version, scenario]: the source release's naming
  # contract (unsuffixed = the linux-gnu scenario).
  ASSET_SCENARIO = /\Atfs-ruby-(\d+\.\d+\.\d+)-src(?:-(linux-musl|msys))?(?:-pass[12])?\.tar\.gz\z/

  def initialize(argv, fetcher_factory: nil, differ: nil)
    @platform = parse_platform(argv)
    @fetcher_factory = fetcher_factory || method(:default_fetcher)
    @differ = differ || GitDiffer.new
    @logger = Logger.new($stdout)
    @logger.formatter = proc { |severity, _, _, msg| "#{severity}: #{msg}\n" }
  end

  # The production fetcher seam: one SourceFetcher per pinned release (the
  # pin owns its SHA256SUMS). release nil = the repo's current pin.
  # TEBAKO_SRC_MIRROR redirects ONLY the current pin's reads (the spec-22
  # chain gate: the matrix's src_sha256 keys come from the workflow's own
  # source roll). Previous-pin diff reads keep the published release URL —
  # the mirror carries one roll, not a release history.
  def default_fetcher(release)
    args = { cache_dir: Dir.mktmpdir("tfs-sums-") }
    args[:release] = release if release
    mirror = ENV.fetch("TEBAKO_SRC_MIRROR", nil)
    args[:mirror] = mirror if release.nil? && mirror && !mirror.empty?
    TebakoRuntimeBuilder::SourceFetcher.new(**args)
  end

  def graph_path
    ENV.fetch("BUILD_GRAPH_PATH", GRAPH)
  end

  def matrix_json_path
    ENV.fetch("MATRIX_JSON_PATH", MATRIX_JSON)
  end

  # The git-diff reader, extracted for specs.
  class GitDiffer
    ZERO_SHA = "0" * 40

    def changed_files(before, after)
      raise ArgumentError, "diff needs both SHAs" if before.to_s.empty? || after.to_s.empty? || before == ZERO_SHA

      `git diff --name-only #{before}..#{after}`.split("\n")
    end

    def file_at(ref, path)
      `git show #{ref}:#{path} 2>/dev/null`
    end
  end

  def run
    event = ENV.fetch("GITHUB_EVENT_NAME", "unknown")
    legs = legs_for(event)
    emit(legs)
    shape = legs[:run] ? "#{legs[:rubies].size} rubies × #{legs[:env].size} env" : "no legs"
    @logger.info("matrix computed for #{@platform}: #{shape} (#{legs[:why]})")
  rescue StandardError => e
    @logger.fatal("matrix computation failed: #{e.message}")
    exit 1
  end

  private

  def parse_platform(argv)
    idx = argv.index("--platform")
    platform = idx && argv[idx + 1]
    raise "usage: compute_matrix.rb --platform <#{PLATFORMS.join("|")}>" unless PLATFORMS.include?(platform)

    platform
  end

  # --- the event change sets ------------------------------------------

  def legs_for(event)
    case event
    when "workflow_dispatch" then dispatch_legs
    when "repository_dispatch" then release_pin_legs
    when "push", "pull_request" then diff_legs(event)
    else
      # schedule and unknown events validate, never publish-wide
      slice_legs(validation_rubies, platform_env, "tidy (event=#{event})")
    end
  end

  # Dispatch: the explicit grammar is the whole story (one version
  # everywhere / one platform all versions / one version on one platform).
  def dispatch_legs
    rubies = ruby_filter_versions
    env = arch_filtered_env
    slice_legs(rubies, env, "dispatch ruby_filter=#{ruby_filter} arch_filter=#{arch_filter}")
  end

  # The source-release pin moved: which versions' tarballs changed.
  def release_pin_legs
    before, after = event_shas
    old_pin = pin_at(before)
    new_pin = pin_at(after)
    changed = changed_versions(old_pin, new_pin)
    if changed.empty?
      @logger.info("pin #{old_pin} -> #{new_pin}: no version tarballs changed")
      return slice_legs([], [], "pin bump with no changed versions")
    end
    @logger.info("pin #{old_pin} -> #{new_pin}: changed versions #{changed.join(", ")}")
    slice_legs(with_shas(changed), platform_env, "pin bump #{new_pin}")
  end

  def diff_legs(event)
    before, after = event_shas
    paths = @differ.changed_files(before, after)
    return empty_legs("empty diff") if paths.empty?

    paths = paths.reject { |p| ignored?(p, graph["ignore"]) }
    return empty_legs("docs-only change") if paths.empty?

    # Publish/release tooling (the graph's publish_only list) is consumed
    # at release time against already-built artifacts — never a build
    # input. Rejected AFTER ignore so a mixed docs+publish diff reports
    # the honest reason, and BEFORE routing so a publish+build diff still
    # builds on the build paths alone.
    paths = paths.reject { |p| ignored?(p, graph.fetch("publish_only", [])) }
    return empty_legs("publish-only change") if paths.empty?

    routed_legs(event, before, after, paths)
  end

  # The live-diff routing: a pin move beats validation-only beats the
  # build-shaped walk.
  def routed_legs(event, before, after, paths)
    pin_legs = pin_move_legs(before, after, paths)
    return pin_legs if pin_legs
    return validation_legs if validation_only?(paths, graph)

    build_legs_for(event, before, paths, graph)
  end

  # No legs, with the operator-facing reason the run short-circuited.
  def empty_legs(why)
    slice_legs([], [], why)
  end

  # The dependency tree, memoized per computation.
  def graph
    @graph ||= YAML.load_file(graph_path)
  end

  # The pin-move slice, or nil: a push that moves DEFAULT_RELEASE rebuilds
  # exactly the versions whose tarballs moved — the pin lands by merge, no
  # external sender needed. (A fetcher edit that leaves the pin alone
  # falls through to the shared-input behavior below.)
  def pin_move_legs(before, after, paths)
    return nil unless paths.include?(PIN_FILE)

    old_pin = pin_at(before)
    new_pin = pin_at(after)
    return nil if new_pin.nil? || old_pin == new_pin

    moved = changed_versions(old_pin, new_pin)
    @logger.info("source pin #{old_pin} -> #{new_pin}: changed versions #{moved.join(", ")}")
    slice_legs(with_shas(moved), arch_filtered_env, "source pin bump to #{new_pin}")
  end

  # Validation-only changes (specs, lint config) validate on the tidy
  # set on EVERY platform — never a build-shaped leg, never empty.
  def validation_legs
    slice_legs(validation_rubies, arch_filtered_env, "validation-only change")
  end

  # The validation set for THIS platform, defer-aware (the "never empty"
  # rule): the tidy members available here; when EVERY tidy member
  # defers on this platform (windows: 3.3 + 4.0 both defer today, tidy
  # is exactly those two lines), the available line tips substitute —
  # a validation leg validates what the platform actually ships, and a
  # shared-input change can never conclude green having built nothing.
  def validation_rubies
    tidy = with_shas(matrix_rubies("tidy"))
    tidy = with_shas(matrix_rubies("full")) if available(tidy).empty?
    tidy
  end

  # The build-shaped walk: a matrix.json content diff decides the
  # versions; a shared hit reaches every platform; a platform hit only
  # this one. Any other build-input change validates on the tips.
  def build_legs_for(event, before, paths, graph)
    rubies = rubies_from_matrix_diff(before, paths)
    platform_hit = platform_changed?(@platform, paths, graph)
    if paths.any? { |p| shared?(p, graph) } || matrix_json_changed?(paths)
      platform_hit = true # shared inputs reach every platform
      rubies ||= validation_rubies
    end
    rubies ||= validation_rubies # tooling change: validate on the tips
    return slice_legs([], [], "#{@platform} unaffected by this diff") unless platform_hit

    slice_legs(rubies, arch_filtered_env, "#{event} diff: #{paths.size} changed path(s)")
  end

  # --- the tree walk helpers ------------------------------------------

  def shared?(path, graph)
    graph["shared"].any? { |pat| glob_match?(pat, path) }
  end

  def platform_changed?(platform, paths, graph)
    (graph["platforms"][platform] || []).any? do |pat|
      paths.any? { |p| glob_match?(pat, p) }
    end
  end

  def ignored?(path, patterns)
    patterns.any? { |pat| glob_match?(pat, path) }
  end

  def validation_only?(paths, graph)
    paths.all? { |p| graph["validation_only"].any? { |pat| glob_match?(pat, p) } }
  end

  def matrix_json_changed?(paths)
    paths.include?(".github/matrix.json")
  end

  # The matrix.json content diff: versions ADDED to any ruby set build
  # (removals never rebuild). nil when matrix.json is not in the diff or
  # no version moved — the caller's tidy default then applies.
  def rubies_from_matrix_diff(before, paths)
    return nil unless matrix_json_changed?(paths)

    old_data = JSON.parse(@differ.file_at(before, ".github/matrix.json"))
    changed = %w[tidy full catalog].flat_map do |set|
      (matrix_data.dig("ruby", set) || []) - (old_data.dig("ruby", set) || [])
    end.uniq
    changed.empty? ? nil : with_shas(changed)
  end

  # --- the vocabulary helpers ------------------------------------------

  def matrix_data
    @matrix_data ||= JSON.parse(File.read(matrix_json_path))
  end

  def matrix_rubies(set)
    matrix_data.dig("ruby", set) or raise "matrix.json has no ruby.#{set}"
  end

  def platform_env
    matrix_data.fetch("env").select { |entry| entry["os"] == platform_os }
  end

  def arch_filtered_env
    env = platform_env
    return env if arch_filter.empty? || arch_filter == "all"

    env.select { |entry| entry["arch"] == arch_filter }
  end

  # The matrix os ids ARE the platform ids (identity).
  def platform_os
    @platform
  end

  def ruby_filter
    ENV.fetch("MATRIX_RUBY_FILTER", "")
  end

  def arch_filter
    ENV.fetch("MATRIX_ARCH_FILTER", "")
  end

  def ruby_filter_versions
    return with_shas(matrix_rubies(ruby_filter)) if %w[full tidy catalog].include?(ruby_filter)
    return with_shas(ruby_filter.split(",").map(&:strip).reject(&:empty?)) unless ruby_filter.empty?

    with_shas(matrix_rubies("full"))
  end

  # --- pins and shas ---------------------------------------------------

  def pin_at(ref)
    content = @differ.file_at(ref, "build/lib/tebako_runtime_builder/source_fetcher.rb")
    match = content.match(/DEFAULT_RELEASE\s*=\s*"([^"]+)"/)
    match ? match[1] : nil
  end

  def changed_versions(old_pin, new_pin)
    return all_versions(new_pin) if old_pin.nil? || old_pin == new_pin

    old_sums = sha_sums(old_pin)
    new_sums = sha_sums(new_pin)
    # Only the (version, scenario) pairs THIS platform consumes: an
    # msys-only source re-roll moves no POSIX asset, so no POSIX leg
    # runs; a POSIX-only re-roll leaves windows idle.
    my_scenario = PLATFORM_SCENARIOS.fetch(@platform)
    new_sums.keys
            .select { |(_version, scenario)| scenario == my_scenario }
            .reject { |pair| old_sums[pair] == new_sums[pair] }
            .map(&:first)
            .uniq
  end

  # The pin's per-asset sums keyed by [version, scenario] — every
  # scenario asset participates (an msys-only re-roll is visible to the
  # windows planner, invisible to the POSIX ones).
  def sha_sums(pin)
    @fetcher_factory.call(pin).sha256sums.each_with_object({}) do |(name, sha), acc|
      m = name.match(ASSET_SCENARIO)
      acc[[m[1], m[2] || "linux-gnu"]] = sha if m
    end
  end

  def all_versions(pin)
    sha_sums(pin).keys.map(&:first).uniq
  end

  def with_shas(versions)
    versions.map { |v| { "version" => v, "src_sha256" => platform_tarball_sha256(v) } }
  end

  # The cache-key sha is the sha of the tarball THIS platform consumes
  # (the msys pass-1 tree on windows, the musl tree on linux-musl, the
  # base tree elsewhere): a scenario-suffixed re-roll moves the key of
  # exactly the platforms whose bytes moved.
  def platform_tarball_sha256(version)
    name = TebakoRuntimeBuilder::SourceFetcher.scenario_asset_names(version, matrix_platform).first
    source_fetcher.sha256sums.fetch(name)
  end

  # The builder Platform for this matrix platform (the scenario asset
  # rule consumes it).
  def matrix_platform
    ostype = { "windows" => "x64-mingw-ucrt", "linux-gnu" => "linux-gnu",
               "linux-musl" => "linux-musl", "macos" => "darwin" }.fetch(@platform)
    TebakoRuntimeBuilder::Platform.new(ostype)
  end

  def source_fetcher
    @source_fetcher ||= @fetcher_factory.call(nil)
  end

  def event_shas
    payload = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
    case ENV.fetch("GITHUB_EVENT_NAME")
    when "push" then [payload["before"], payload["after"]]
    when "pull_request" then [payload.dig("pull_request", "base", "sha"), payload.dig("pull_request", "head", "sha")]
    when "repository_dispatch" then [
      payload.dig("client_payload", "base_sha").to_s.empty? ? "HEAD~1" : payload["client_payload"]["base_sha"], "HEAD"
    ]
    else ["HEAD~1", "HEAD"]
    end
  end

  # --- glob + emit ------------------------------------------------------

  def glob_match?(pattern, path)
    File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
      (pattern.end_with?("/**") && path.start_with?(pattern.delete_suffix("/**")))
  end

  def slice_legs(rubies, env, why)
    rubies = available(rubies)
    env = env.map { |entry| entry.merge("host_id" => TebakoRuntimeBuilder::Platform.host_id_for(entry["os"], entry["arch"])) }
    { run: rubies.any? && env.any?, rubies: rubies, env: env, why: why }
  end

  # Per-platform availability (matrix.json `defer`): a version is deferred
  # for this platform — never scheduled, never expected, never promised —
  # when it starts with one of the platform's listed minor-line prefixes.
  # Applied at the universal chokepoint so EVERY trigger path (dispatch
  # filters, the pin-bump diff walk, the tidy validation set) drops a
  # deferred version before it can become a leg. Handles both the bare
  # version strings (tidy) and the sha-mapped rows (every other path).
  def available(rubies)
    deferred = matrix_data.dig("defer", @platform) || []
    return rubies if deferred.empty?

    rubies.reject do |row|
      v = row.is_a?(Hash) ? row["version"] : row
      deferred.any? { |prefix| v.start_with?("#{prefix}.") || v == prefix }
    end
  end

  def emit(legs)
    out = ENV.fetch("GITHUB_OUTPUT") { raise "GITHUB_OUTPUT environment variable not set" }
    File.write(out, "run=#{legs[:run]}\n", mode: "a")
    File.write(out, "ruby-matrix=#{legs[:rubies].to_json}\n", mode: "a")
    File.write(out, "env-matrix=#{legs[:env].to_json}\n", mode: "a")
    File.write(out, "link-unit-matrix=#{link_unit_matrix(legs[:env]).to_json}\n", mode: "a")
    File.write(out, "why=#{legs[:why]}\n", mode: "a")
  end

  # The link-unit matrix: one leg per platform-arch, NEVER per ruby —
  # the native closure depends on the triplet only. Deduped by env key
  # (os, arch) so a future second host for the same arch still stages
  # once (two same-named artifact uploads would collide in the run).
  def link_unit_matrix(env)
    env.uniq { |entry| [entry["os"], entry["arch"]] }
  end
end

MatrixComputer.new(ARGV).run if $PROGRAM_NAME == __FILE__
