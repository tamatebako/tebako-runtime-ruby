#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2025 [Ribose Inc](https://www.ribose.com).
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
require "tmpdir"

# The Platform/SourceFetcher model (build/lib) — the source release pin
# (SourceFetcher::DEFAULT_RELEASE) and the SHA256SUMS reads are owned
# there, never re-derived here.
$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_runtime_builder"

# Matrix generator for tebako build workflow
class MatrixGenerator
  def initialize(fetcher: nil)
    @source_fetcher = fetcher
    @logger = Logger.new($stdout)
    @logger.formatter = proc do |severity, _, _, msg|
      "#{severity}: #{msg}\n"
    end
  end

  def determine_ruby_suffix
    event_name = ENV.fetch("GITHUB_EVENT_NAME", "unknown")
    # push + pull_request are VALIDATION events: the tidy set (one 3.x tip
    # + the 4.0 tip × every env) proves the pipeline end-to-end without
    # firing the full 154-leg matrix on every landing commit. The full set
    # is reserved for the publish paths (workflow_dispatch /
    # repository_dispatch / schedule) — a per-platform or per-version fix
    # must never re-spend the whole matrix (the ten-cancelled-runs class
    # of the POSIX migration).
    suffix = %w[pull_request push].include?(event_name) ? "tidy" : "full"
    @logger.info("Using #{suffix} Ruby versions for #{event_name} event")
    suffix
  end

  def get_ruby_versions(data, suffix)
    ruby_data = validate_json_section(data, "ruby")
    validate_json_section(ruby_data, suffix)
  end

  def process_env_matrix(data)
    @logger.info("Processing environment matrix...")
    env = validate_json_section(data, "env")
    env = filter_env(env)
    # The release platform id per entry — tpkg::Platform's vocabulary,
    # mirrored by Platform.host_id_for (the SSOT: "windows-ucrt64" is NOT
    # derivable from os+arch by formula — the workflow's runtime artifact
    # names flow from this, never from a local os-arch join).
    env.each { |entry| entry["host_id"] = TebakoRuntimeBuilder::Platform.host_id_for(entry["os"], entry["arch"]) }
    @logger.info("Generated env matrix:")
    @logger.info(JSON.pretty_generate(env))
    write_output("env-matrix", env)
  rescue StandardError => e
    report_matrix_error("env", e, data)
  end

  def report_matrix_error(stage, error, data)
    @logger.error("Error processing #{stage} matrix: #{error.message}")
    @logger.error("matrix.json content:")
    @logger.error(JSON.pretty_generate(data))
    raise error
  end

  # Optional slice filter for workflow_dispatch iteration/debugging:
  # MATRIX_ENV_FILTER="linux-musl/arm64" selects a single os/arch pair
  # ("all" or empty keeps every entry)
  def filter_env(env)
    filter = ENV.fetch("MATRIX_ENV_FILTER", "")
    return env if filter.empty? || filter == "all"

    os, arch = filter.split("/", 2)
    selected = env.select { |entry| env_entry_matches?(entry, os, arch) }
    raise "MATRIX_ENV_FILTER '#{filter}' matched no env entries" if selected.empty?

    @logger.info("MATRIX_ENV_FILTER '#{filter}' selected #{selected.size} env entry(ies)")
    selected
  end

  def env_entry_matches?(entry, os, arch)
    return false unless entry["os"] == os

    arch.nil? || arch.empty? || entry["arch"] == arch
  end

  # MATRIX_RUBY_FILTER: "full"/"tidy"/"catalog" select the named
  # matrix.json set; a comma-separated version list ("3.3.7,3.4.2")
  # overrides for slice dispatches; empty falls back to the event-based
  # default. The sets: tidy = push/PR validation; full = the line TIPS
  # (resolution serves the newest compatible runtime — the tips are the
  # steady state, ~35 legs not ~154); catalog = the era back-catalog,
  # published once per era (exact-version pins resolve against those
  # persisted assets; niche patchlevels beyond it are on-demand slices).
  def select_ruby_versions(data)
    filter = ENV.fetch("MATRIX_RUBY_FILTER", "")
    return get_ruby_versions(data, filter) if %w[full tidy catalog].include?(filter)
    return filter.split(",").map(&:strip).reject(&:empty?) unless filter.empty?

    suffix = determine_ruby_suffix
    get_ruby_versions(data, suffix)
  end

  # The ruby matrix rows carry the version's OWN source tarball sha256
  # ({version, src_sha256}) from the pinned tamatebako/ruby release's
  # SHA256SUMS: the build job's .build cache keys on it, so a per-line
  # source change re-spends only that line's legs (fault isolation). The
  # sha is read through TebakoRuntimeBuilder::SourceFetcher -- the same
  # object that verifies the tarball against the same SHA256SUMS at
  # download time, so the cache key and the download verification share
  # one source of truth. select_ruby_versions keeps returning plain
  # version strings (matrix.json sets and MATRIX_RUBY_FILTER slices stay
  # string-shaped).
  def process_ruby_matrix(data)
    @logger.info("Processing ruby matrix...")
    ruby_versions = select_ruby_versions(data)
    rows = ruby_versions.map { |version| { "version" => version, "src_sha256" => src_sha256(version) } }

    @logger.info("Generated ruby matrix: #{JSON.pretty_generate(rows)}")
    write_output("ruby-matrix", rows)
  rescue StandardError => e
    report_matrix_error("ruby", e, data)
  end

  def src_sha256(version)
    source_fetcher.tarball_sha256(version)
  end

  def source_fetcher
    @source_fetcher ||= TebakoRuntimeBuilder::SourceFetcher.new(cache_dir: Dir.mktmpdir("tfs-src-sums"))
  end

  def read_matrix_json
    @logger.info("Reading matrix.json...")
    JSON.parse(File.read(".github/matrix.json"))
  rescue JSON::ParserError
    @logger.error("Invalid JSON in matrix.json")
    raise
  rescue Errno::ENOENT
    @logger.error("matrix.json not found")
    raise
  end

  def run
    data = read_matrix_json
    process_env_matrix(data)
    process_ruby_matrix(data)
    @logger.info("Matrix generation completed successfully")
  rescue StandardError => e
    @logger.fatal("Matrix generation failed: #{e.message}")
    exit 1
  end

  def validate_json_section(data, section)
    raise "No #{section} section found in matrix.json" if data[section].nil?
    raise "Invalid JSON in #{section} section" unless data[section].is_a?(Hash) || data[section].is_a?(Array)

    data[section]
  end

  def write_output(key, value)
    @logger.info("Writing #{key} to GITHUB_OUTPUT")
    github_output = ENV.fetch("GITHUB_OUTPUT") { raise "GITHUB_OUTPUT environment variable not set" }
    File.write(github_output, "#{key}=#{value.to_json}\n", mode: "a")
  end
end

MatrixGenerator.new.run if $PROGRAM_NAME == __FILE__
