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
#     walked against shared/platform/ignore rules. A shared hit affects
#     every platform; a platform hit affects that platform only;
#     ignore-only diffs produce no legs; validation_only diffs produce
#     the tidy validation legs. A matrix.json change is diffed by
#     CONTENT (which ruby sets/versions and which env entries moved).
#   repository_dispatch ("tebako release" — a new source release pin):
#     the pinned release's SHA256SUMS is diffed against the PREVIOUS
#     pin's — only versions whose tarball sha moved are affected (a
#     4.0-only source release rebuilds 4.0.x only), on every platform
#     (a source tarball change reaches every scenario of that version).
#   workflow_dispatch — the explicit filters (the three first-class
#     shapes: one version everywhere, one platform all versions, one
#     version on one platform), never the diff.
#
# Usage: compute_matrix.rb --platform <windows|linux-gnu|linux-musl|macos>
# Env:  GITHUB_EVENT_NAME / GITHUB_EVENT_PATH (the payload for diff SHAs),
#       MATRIX_RUBY_FILTER (dispatch: full|tidy|catalog|a,comma,slice),
#       MATRIX_ARCH_FILTER (optional arch within the platform),
#       GITHUB_OUTPUT (the emitted legs/env-matrix/ruby-matrix).
class MatrixComputer
  GRAPH = File.expand_path("../.github/build-graph.yaml", __dir__).freeze
  MATRIX_JSON = File.expand_path("../.github/matrix.json", __dir__).freeze
  PLATFORMS = %w[windows linux-gnu linux-musl macos].freeze

  def initialize(argv, fetcher: nil, differ: nil)
    @platform = parse_platform(argv)
    @fetcher = fetcher
    @differ = differ || GitDiffer.new
    @logger = Logger.new($stdout)
    @logger.formatter = proc { |severity, _, _, msg| "#{severity}: #{msg}\n" }
  end

  def graph_path = ENV.fetch("BUILD_GRAPH_PATH", GRAPH)

  def matrix_json_path = ENV.fetch("MATRIX_JSON_PATH", MATRIX_JSON)

  # The git-diff reader, extracted for specs.
  class GitDiffer
    def changed_files(before, after)
      raise ArgumentError, "diff needs both SHAs" if before.to_s.empty? || after.to_s.empty? || before == "0000000000000000000000000000000000000000"

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
    @logger.info("matrix computed for #{@platform}: #{legs[:run] ? "#{legs[:rubies].size} rubies × #{legs[:env].size} env" : "no legs"}")
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
      slice_legs(matrix_rubies("tidy"), platform_env, "tidy (event=#{event})")
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
    return slice_legs([], [], "empty diff") if paths.empty?

    graph = YAML.load_file(graph_path)
    paths = paths.reject { |p| ignored?(p, graph["ignore"]) }
    return slice_legs([], [], "docs-only change") if paths.empty?

    rubies = rubies_from_matrix_diff(before, after, paths)
    platform_hit = platform_changed?(@platform, paths, graph)

    # Validation-only changes (specs, lint config) validate on the tidy
    # set on EVERY platform — never a build-shaped leg, never empty.
    if validation_only?(paths, graph)
      return slice_legs(with_shas(matrix_rubies("tidy")), arch_filtered_env, "validation-only change")
    end

    if paths.any? { |p| shared?(p, graph) } || matrix_json_changed?(paths)
      platform_hit = true # shared inputs reach every platform
      rubies = with_shas(matrix_rubies("tidy")) if rubies.nil?
    end
    rubies = with_shas(matrix_rubies("tidy")) if rubies.nil? # tooling change: validate on the tips

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

  def rubies_from_matrix_diff(before, after, paths)
    return nil unless matrix_json_changed?(paths)

    old_data = JSON.parse(@differ.file_at(before, ".github/matrix.json"))
    new_data = matrix_data
    changed = []
    %w[tidy full catalog].each do |set|
      old_set = old_data.dig("ruby", set) || []
      new_set = new_data.dig("ruby", set) || []
      changed |= (new_set - old_set) # added/NEW versions build; removals never rebuild
    end
    old_env = old_data["env"] || []
    new_env = new_data["env"] || []
    @env_changed = (old_env != new_env)
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

  def platform_os
    @platform == "windows" ? "windows" : @platform.sub("linux-", "linux-") # identity; the matrix os ids are the platform ids
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
    new_sums.keys.select { |version| old_sums[version] != new_sums[version] }
  end

  def sha_sums(pin)
    fetcher = @fetcher || TebakoRuntimeBuilder::SourceFetcher.new(cache_dir: Dir.mktmpdir("tfs-sums-"), release: pin)
    fetcher.sha256sums.each_with_object({}) do |(name, sha), acc|
      m = name.match(/\Atfs-ruby-(\d+\.\d+\.\d+)-src\.tar\.gz\z/)
      acc[m[1]] = sha if m
    end
  end

  def all_versions(pin)
    sha_sums(pin).keys
  end

  def with_shas(versions)
    versions.map { |v| { "version" => v, "src_sha256" => source_fetcher.tarball_sha256(v) } }
  end

  def source_fetcher
    @source_fetcher ||= TebakoRuntimeBuilder::SourceFetcher.new(cache_dir: Dir.mktmpdir("tfs-src-sums"))
  end

  def event_shas
    payload = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
    case ENV.fetch("GITHUB_EVENT_NAME")
    when "push" then [payload.dig("before"), payload.dig("after")]
    when "pull_request" then [payload.dig("pull_request", "base", "sha"), payload.dig("pull_request", "head", "sha")]
    when "repository_dispatch" then [payload.dig("client_payload", "base_sha").to_s.empty? ? "HEAD~1" : payload["client_payload"]["base_sha"], "HEAD"]
    else ["HEAD~1", "HEAD"]
    end
  end

  # --- glob + emit ------------------------------------------------------

  def glob_match?(pattern, path)
    File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
      (pattern.end_with?("/**") && path.start_with?(pattern.delete_suffix("/**")))
  end

  def slice_legs(rubies, env, why)
    env = env.map { |entry| entry.merge("host_id" => TebakoRuntimeBuilder::Platform.host_id_for(entry["os"], entry["arch"])) }
    { run: rubies.any? && env.any?, rubies: rubies, env: env, why: why }
  end

  def emit(legs)
    out = ENV.fetch("GITHUB_OUTPUT") { raise "GITHUB_OUTPUT environment variable not set" }
    File.write(out, "run=#{legs[:run]}\n", mode: "a")
    File.write(out, "ruby-matrix=#{legs[:rubies].to_json}\n", mode: "a")
    File.write(out, "env-matrix=#{legs[:env].to_json}\n", mode: "a")
    File.write(out, "why=#{legs[:why]}\n", mode: "a")
  end
end

MatrixComputer.new(ARGV).run if $PROGRAM_NAME == __FILE__
