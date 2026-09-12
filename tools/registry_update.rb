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

require "bundler/setup"
require "octokit"
require "base64"
require "json"
require "yaml"

# CI log truth: flush every line so the runner's timestamps are the
# writes' real times (the 2026-08-20 wedge lesson, upload_release.rb).
$stdout.sync = true

# The host_id → vcpkg-triplet mapping the platform rows render through is
# owned by the Platform model (mirroring tpkg::Platform in tamatebako/tebako
# — the single triplet owner).
$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_runtime_builder"

RUNTIME_REPO = "tamatebako/tebako-runtime-ruby" unless defined?(RUNTIME_REPO)

# Renders this repo's tpkg-registry.yaml from a release's per-package
# .manifest.json shards (spec 13 §2a: the shard is the release's
# machine-readable unit; the registry is a spec 04 §2 MIRROR of
# resolution fields, derived — never hand-authored).
#
# One payload entry (`ruby`, kind: runtime, engine: ruby); one version
# line per ruby built by the release, keyed by the composite
# `<ruby_version>-<tebako_version>`; per-triplet platform rows mirroring
# the shard's package artifact + sha256; the version's release ref points
# at the release the shards came from. The merge is additive and
# write-once-friendly: existing versions keep their rows (new shards win
# per triplet), `status: withdrawn` marks (the only sanctioned hand-edit —
# spec 04 §2) survive every render, and `default:` tracks the newest
# non-withdrawn version.
#
# The workflow calls this in the audit+registry job and lands the result
# by bot PR against main — git arbitrates, never a force-push.
class RegistryUpdate # rubocop:disable Metrics/ClassLength
  class RegistryUpdateError < StandardError; end

  PAYLOAD_NAME = "ruby"
  SHARD_SUFFIX = ".manifest.json"
  REGISTRY_BASENAME = "tpkg-registry.yaml"

  HEADER = <<~HEADER
    # =============================================================================
    # tpkg-registry.yaml — the tebako-runtime-ruby runtime registry (spec 04 §2)
    #
    # OWNED BY tools/registry_update.rb — rendered from a release's per-package
    # .manifest.json shards by the publish workflow's audit+registry job and
    # landed on main by bot PR (spec 13 §2a). NEVER hand-edit: the one sanctioned
    # manual mark is `status: withdrawn` on a version entry (spec 04 §2 — release
    # assets are immutable, so withdrawal is the only remedy for a bad published
    # artifact), and the renderer preserves those marks across renders.
    # =============================================================================
  HEADER

  def initialize(client: nil, env: ENV)
    @env = env
    @client = client || Octokit::Client.new(access_token: @env.fetch("GITHUB_TOKEN"), auto_paginate: true)
    @version = @env.fetch("TEBAKO_VERSION")
    @tag = "v#{@version}"
    @registry_path = @env["REGISTRY_PATH"] || File.expand_path("../#{REGISTRY_BASENAME}", __dir__)
  end

  def run
    release = find_release
    merged = merge(current_registry, version_rows(release))
    path = write_registry(merged)
    puts "#{@tag}: registry rendered to #{path} " \
         "(#{merged.fetch("payloads").size} payload(s))"
    path
  end

  private

  def find_release
    @client.release_for_tag(RUNTIME_REPO, @tag)
  rescue Octokit::NotFound
    raise RegistryUpdateError, "NAMED FAILURE: no release found for tag #{@tag} — nothing to mirror"
  end

  # The release's shards, grouped into one registry version line per ruby.
  def version_rows(release) # rubocop:disable Metrics/MethodLength
    shards = @client.release_assets(release.url).select { |asset| asset.name.end_with?(SHARD_SUFFIX) }
    raise RegistryUpdateError, "NAMED FAILURE: #{@tag} carries no #{SHARD_SUFFIX} shards" if shards.empty?

    by_ruby = {}
    shards.each { |asset| accumulate_shard(by_ruby, asset) }
    by_ruby.map do |ruby, platforms|
      {
        "version" => "#{ruby}-#{@version}",
        "platforms" => platforms.sort.to_h,
        "release" => { "ref" => "tfs:github:#{RUNTIME_REPO}:#{@tag}" }
      }
    end
  end

  # One shard folds into its ruby's platform rows: it must name THIS
  # release's tebako version (a stale shard from another line is a named
  # refusal, never silently mirrored), and two shards claiming one triplet
  # is a named refusal (a row must never be a silent pick).
  def accumulate_shard(by_ruby, asset) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    entry = shard_entry(asset)
    unless entry["tebako_version"] == @version
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset.name} declares tebako_version " \
            "#{entry["tebako_version"].inspect} but this render is for #{@version} — " \
            "the release mixes lines; audit it before mirroring"
    end

    row = platform_row(asset.name, entry)
    group = (by_ruby[entry.fetch("ruby_version")] ||= {})
    if group.key?(row.first)
      raise RegistryUpdateError,
            "NAMED FAILURE: two shards claim #{row.first} for ruby #{entry["ruby_version"]} on #{@tag}"
    end

    group[row.first] = row.last
  end

  def shard_entry(asset)
    entry = JSON.parse(@client.get(asset.browser_download_url).to_s)
    missing = %w[tebako_version ruby_version platform filename sha256] - entry.keys
    unless missing.empty?
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset.name} is missing #{missing.join(", ")} — republish the leg"
    end

    entry
  end

  # One shard → one (triplet, {artifact, sha256}) platform row. The
  # triplet mapping is fail-closed: a host_id the Platform model does not
  # know can never become a silently wrong registry row.
  def platform_row(asset_name, entry)
    host_id = entry.fetch("platform")
    triplet = TebakoRuntimeBuilder::Platform::TPKG_TRIPLETS[host_id]
    unless triplet
      raise RegistryUpdateError,
            "NAMED FAILURE: shard #{asset_name} names unknown platform #{host_id.inspect} — " \
            "no spec 03 §3 triplet mapping for it"
    end

    [triplet, { "artifact" => entry.fetch("filename"), "sha256" => entry.fetch("sha256") }]
  end

  # The current registry on main (contents API — the canonical published
  # state), or the seed document when the file does not exist yet.
  def current_registry
    res = @client.contents(RUNTIME_REPO, path: REGISTRY_BASENAME)
    data = YAML.safe_load(Base64.decode64(res.content.to_s))
    return seed unless data.is_a?(Hash)

    data
  rescue Octokit::NotFound
    seed
  end

  def seed
    { "schema_version" => 1, "payloads" => [] }
  end

  # Additive merge: upsert the payload entry, then per rendered version —
  # absent versions are inserted, present versions keep their platform rows
  # (new rows win per triplet) and any `status: withdrawn` mark. Versions
  # sort ascending by (ruby, tebako); `default:` tracks the newest
  # non-withdrawn line, and a registry with none left says so loudly.
  def merge(registry, rendered) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    payloads = registry["payloads"] ||= []
    payload = payloads.find { |p| p["name"] == PAYLOAD_NAME }
    unless payload
      payload = { "name" => PAYLOAD_NAME, "kind" => "runtime", "engine" => "ruby", "versions" => [] }
      payloads << payload
    end
    versions = payload["versions"] ||= []
    rendered.each { |row| merge_version(versions, row) }
    payload["versions"] = versions.sort_by { |v| version_sort_key(v.fetch("version")) }
    refresh_default(payload)
    registry
  end

  # One rendered version into the payload's version list: an existing line
  # unions platform rows (new wins per triplet) and keeps its status mark;
  # `platforms: universal` on an existing line can never mix with the
  # shards' per-triplet rows (spec 04 §2: a version carries one shape).
  def merge_version(versions, row) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    existing = versions.find { |v| v["version"] == row["version"] }
    unless existing
      versions << row
      return
    end

    platforms = (existing["platforms"] ||= {})
    unless platforms.is_a?(Hash)
      raise RegistryUpdateError,
            "NAMED FAILURE: registry version #{row["version"].inspect} carries " \
            "`platforms: #{platforms.inspect}` but the shards render per-triplet rows — " \
            "the registry was hand-edited into a mixed shape (spec 04 §2: never both)"
    end

    row["platforms"].each { |triplet, artifact| platforms[triplet] = artifact }
    existing["platforms"] = platforms.sort.to_h
    existing["release"] = row["release"]
  end

  def refresh_default(payload)
    usable = payload["versions"].reject { |v| v["status"] == "withdrawn" }
    if usable.empty?
      warn "WARNING: every #{PAYLOAD_NAME} version is withdrawn — the registry carries no default"
      payload.delete("default")
    else
      payload["default"] = usable.last.fetch("version")
    end
  end

  # The composite `<ruby>-<tebako>` key sorts by its two numeric parts —
  # never lexically ("3.10.x" must not sort before "3.9.x").
  def version_sort_key(key)
    ruby, tebako = key.split("-", 2)
    unless ruby && tebako
      raise RegistryUpdateError,
            "NAMED FAILURE: registry version #{key.inspect} is not a <ruby>-<tebako> composite"
    end

    [Gem::Version.new(ruby), Gem::Version.new(tebako)]
  end

  def write_registry(registry)
    body = YAML.dump(registry).sub(/\A---\n/, "")
    File.write(@registry_path, "#{HEADER}#{body}")
    @registry_path
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    RegistryUpdate.new.run
  rescue RegistryUpdate::RegistryUpdateError, KeyError => e
    warn e.message
    exit 1
  end
end
