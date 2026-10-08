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

# Sync .github/matrix.json's dispatch vocabulary (ruby.catalog / ruby.full /
# ruby.tidy) with the versions a tamatebako/ruby release newly makes
# buildable.
#
#   tools/sync_matrix_vocabulary.rb OLD_REF NEW_REF [--dry-run]
#
# Each ref names a tamatebako/ruby SOURCE RELEASE tag (v0.2.38 & co) — the
# tool reads the release's PUBLISHED index (its SHA256SUMS asset, the same
# artifact the builder's SourceFetcher verifies downloads against), never
# the repository tree: releases are the interface. A ref that names an
# existing local file reads that file as a SHA256SUMS instead (local
# forensics and the spec suite).
#
# DELTA MODE: only versions present in NEW but absent in OLD are admitted.
# The source release ships every ruby the factory can roll (37+ lines,
# including backfills the runtime factory deliberately never shipped); the
# runtime vocabulary is curated to published runtimes, so syncing against
# the full catalog would resurrect every skipped version. The delta between
# the two pinned releases is exactly what the bump newly offers — and the
# pin-bump PR's diff is the human review gate.
#
# catalog is additive — a published row never leaves. full/tidy move a
# line's tip only forward, and only for lines the set already carries:
# admitting a NEW minor line to full/tidy is a curation decision (CI cost,
# defer policy) that stays with the reviewer. Exits 0 without writing when
# the delta is empty or already covered. --dry-run prints the would-be
# changes and never writes. Named, loud failures — never a silent partial
# sync.

require "json"
require "tmpdir"

# The SourceFetcher model (build/lib) owns the release's SHA256SUMS reads —
# the published index this tool consumes. Never re-derived here.
$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_runtime_builder"

class VocabularySync
  # A release's published version set is the unsuffixed linux-gnu source
  # asset names in its SHA256SUMS (every onboarded version ships the base
  # scenario; scenario-suffixed assets name no new versions).
  VERSION_ASSET = /\Atfs-ruby-(\d+\.\d+\.\d+)-src\.tar\.gz\z/
  MATRIX = File.expand_path("../.github/matrix.json", __dir__).freeze
  SUMS_LINE = /\A([0-9a-f]{64})\s+\*?(\S+)\z/i

  def initialize(matrix_path: ENV.fetch("MATRIX_JSON_PATH", MATRIX), fetcher_factory: nil, stdout: $stdout)
    @matrix_path = matrix_path
    @fetcher_factory = fetcher_factory || method(:default_fetcher)
    @stdout = stdout
  end

  # The published version set of a release tag (or a local SHA256SUMS file),
  # sorted oldest first.
  def versions_for(ref)
    names = sums_for(ref).keys
    names.filter_map { |name| name.match(VERSION_ASSET)&.[](1) }
         .uniq
         .sort_by { |v| Gem::Version.new(v) }
  end

  # Sync the vocabulary from OLD to NEW; returns the summary line. Writes
  # the matrix unless dry_run. Raises (loud, named) on any unreadable index.
  def sync(old_ref, new_ref, dry_run: false)
    old_versions = versions_for(old_ref)
    new_versions = versions_for(new_ref)
    raise "no ruby versions found in the published index of #{new_ref}" if new_versions.empty?

    delta = new_versions - old_versions
    if delta.empty?
      return report("no new versions between #{old_ref} and #{new_ref} (#{new_versions.last} is already known) " \
                    "-- vocabulary unchanged")
    end

    matrix = JSON.parse(File.read(@matrix_path))
    ruby = matrix.fetch("ruby") { raise "#{@matrix_path}: no ruby key" }
    %w[catalog full tidy].each { |set| ruby.fetch(set) { raise "#{@matrix_path}: no ruby.#{set} array" } }

    added, moved = apply_delta(ruby, delta)
    if added.empty? && moved.empty?
      return report("delta versions #{delta.join(', ')} already covered -- vocabulary unchanged")
    end

    File.write(@matrix_path, JSON.pretty_generate(matrix) + "\n") unless dry_run
    report("#{"[dry-run] would sync: " if dry_run}vocabulary synced: catalog += [#{added.join(', ')}]; " \
           "tips moved: #{moved.join(', ')}#{added.empty? && moved.empty? ? ' (none)' : ''}")
  end

  private

  def report(line)
    @stdout.puts(line)
    line
  end

  # The delta applied to the vocabulary sets: catalog gains each new version
  # after its line's last member (line-grouped, oldest first); full/tidy
  # move a tracked line's tip forward. Returns [catalog_additions, tip_moves].
  def apply_delta(ruby, delta)
    line_of = ->(v) { v.split(".").first(2).join(".") }

    added = []
    catalog = ruby["catalog"]
    delta.each do |v|
      next if catalog.include?(v)

      last = catalog.rindex { |e| line_of.call(e) == line_of.call(v) }
      catalog.insert(last ? last + 1 : catalog.length, v)
      added << v
    end

    moved = []
    %w[full tidy].each do |set|
      ruby[set].map! do |tip|
        newest = delta.select { |v| line_of.call(v) == line_of.call(tip) }.last
        if newest && Gem::Version.new(newest) > Gem::Version.new(tip)
          moved << "#{tip} -> #{newest} (#{set})"
          newest
        else
          tip
        end
      end
    end
    [added, moved]
  end

  # {asset_name => sha256} for the ref: the release's published SHA256SUMS
  # through the owning model, or the local file read verbatim.
  def sums_for(ref)
    return parse_sums(File.read(ref)) if File.file?(ref)

    @fetcher_factory.call(ref).sha256sums
  rescue TebakoRuntimeBuilder::Error => e
    raise "cannot read the published index of #{ref}: #{e.message}"
  end

  def parse_sums(content)
    content.each_line.each_with_object({}) do |line, acc|
      m = line.strip.match(SUMS_LINE)
      acc[m[2]] = m[1].downcase if m
    end
  end

  def default_fetcher(release)
    TebakoRuntimeBuilder::SourceFetcher.new(cache_dir: Dir.mktmpdir("tfs-sums-"), release: release)
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.reject { |a| a == "--dry-run" }
  dry_run = args.length != ARGV.length
  old_ref = args.fetch(0) { abort "usage: #{$PROGRAM_NAME} OLD_REF NEW_REF [--dry-run]" }
  new_ref = args.fetch(1) { abort "usage: #{$PROGRAM_NAME} OLD_REF NEW_REF [--dry-run]" }
  begin
    VocabularySync.new.sync(old_ref, new_ref, dry_run: dry_run)
  rescue StandardError => e
    abort "sync_matrix_vocabulary: #{e.message}"
  end
end
