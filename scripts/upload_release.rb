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

require "bundler/setup"
require "octokit"
require "digest"
require "json"
require "pathname"

RUNTIME_REPO = "tamatebako/tebako-runtime-ruby"

# Upload release manager for tebako build workflow
class ReleaseManager # rubocop:disable Metrics/ClassLength
  def initialize
    validate_environment
    @client = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: true)
    @version = ENV.fetch("TEBAKO_VERSION")
    @tag = "v#{@version}"
    @release_title = "Tebako runtime packages #{@tag}"
  end

  def build_manifest_entries(packages)
    packages.sort_by { |package| package.basename.to_s }.map { |package| manifest_entry(package) }
  end

  def categorize_packages(filenames)
    sections = initialize_sections
    filenames.each do |filename|
      platform = %w[windows macos linux-gnu linux-musl].find { |p| filename.include?(p) }
      sections[platform] << filename if platform
    end
    sections
  end

  def expected_package_names
    env_json = ENV.fetch("EXPECTED_ENV_MATRIX", nil)
    ruby_json = ENV.fetch("EXPECTED_RUBY_MATRIX", nil)
    return [] unless env_json && ruby_json

    envs = JSON.parse(env_json)
    rubies = JSON.parse(ruby_json)
    envs.product(rubies).map { |env, ruby| "tebako-runtime-#{@version}-#{ruby}-#{env["os"]}-#{env["arch"]}" }
  rescue JSON::ParserError => e
    puts "::warning::Could not compute expected package list: #{e.message}"
    []
  end

  # Metadata files (SHA256SUMS.txt, manifest.json) are always overwritten,
  # regardless of FORCE_REBUILD, so they never go stale on partial releases.
  def force_upload(release, file)
    filename = file.basename.to_s
    remove_existing_asset(release, filename) if find_asset(release, filename)
    perform_upload(release, file, filename)
  end

  def generate_manifest(entries)
    path = Pathname.new("manifest.json")
    path.write("#{JSON.pretty_generate(entries)}\n")
    path
  end

  def generate_release_notes(sections)
    body = <<~BODY
      ## Tebako runtime packages

      Release version: #{@tag}
      Build date: #{Time.now.strftime("%Y-%m-%d")}

    BODY

    sections.each do |platform, files|
      body += generate_section(platform, files)
    end
    body += "\nChecksums: see the `SHA256SUMS.txt` asset.\n"
    body += "Machine-readable package index: see the `manifest.json` asset.\n"
    body
  end

  def generate_section(platform, files)
    return "" if files.empty?

    section = "\n### #{platform_display_name(platform)} executables\n"
    files.each { |file| section += "- #{file}\n" }
    section
  end

  def generate_sha256sums(entries)
    path = Pathname.new("SHA256SUMS.txt")
    path.write("#{entries.map { |entry| "#{entry[:sha256]}  #{entry[:filename]}" }.join("\n")}\n")
    path
  end

  def get_or_create_release # rubocop:disable Naming/AccessorMethodName
    puts "Looking for release with tag: #{@tag}"
    @client.release_for_tag(RUNTIME_REPO, @tag)
  rescue Octokit::NotFound
    puts "Creating new release for tag: #{@tag}"
    @client.create_release(RUNTIME_REPO, @tag,
                           name: @release_title,
                           body: generate_release_notes(initialize_sections))
  end

  def initialize_sections
    { "windows" => [], "macos" => [], "linux-gnu" => [], "linux-musl" => [] }
  end

  def manifest_entry(package)
    filename = package.basename.to_s
    ruby_version, platform = parse_package_filename(filename)
    {
      tebako_version: @version,
      ruby_version: ruby_version,
      platform: platform,
      filename: filename,
      sha256: Digest::SHA256.file(package).hexdigest,
      size_bytes: package.size
    }
  end

  def parse_package_filename(filename)
    match = /\Atebako-runtime-#{Regexp.escape(@version)}-(\d+\.\d+\.\d+)-(.+?)(?:\.exe)?\z/.match(filename)
    unless match
      puts "::warning::Cannot infer ruby/platform from package filename: #{filename}"
      return [nil, nil]
    end

    [match[1], match[2]]
  end

  def perform_upload(release, package, filename, attempts: 4)
    puts "Uploading #{filename}"
    @client.upload_asset(
      release.url,
      package.to_s,
      content_type: "application/octet-stream",
      name: filename
    )
  rescue Octokit::UnprocessableEntity, Net::WriteTimeout, Net::ReadTimeout,
         Faraday::TimeoutError, Faraday::ConnectionFailed => e
    attempts -= 1
    raise if attempts <= 0

    # GitHub asset deletion is only eventually consistent (same-name
    # re-upload right after a delete can 422), and multi-MB asset streams
    # hit transient network timeouts. Back off and retry.
    puts "#{e.class} uploading #{filename}; retrying in 5s (#{attempts} attempt(s) left)"
    sleep 5
    retry
  end

  def platform_display_name(platform)
    case platform
    when "windows" then "Windows"
    when "macos" then "macOS"
    when "linux-gnu" then "Linux GNU"
    when "linux-musl" then "Linux musl"
    else platform.capitalize
    end
  end

  def process_release
    release = get_or_create_release
    puts "Working with release ID: #{release.id}"

    packages = validate_packages_directory
    report_missing_packages(packages)
    sections = upload_and_categorize(release, packages)
    upload_metadata(release, packages)
    release_body = generate_release_notes(sections)
    @client.update_release(release.url, body: release_body)
    puts "Successfully updated release notes"
  end

  def report_missing_packages(packages)
    found = packages.map { |package| package.basename.to_s.sub(/\.exe\z/, "") }
    missing = expected_package_names - found
    return if missing.empty?

    puts "::warning::Release incomplete: #{missing.size} expected runtime package(s) are missing"
    missing.sort.each { |name| puts "::warning::Missing runtime package: #{name}" }
    puts "Continuing release update with #{found.size} available package(s)"
  end

  def remove_existing_asset(release, filename)
    puts "Deleting existing asset #{filename}"
    existing = find_asset(release, filename)
    @client.delete_release_asset(existing.id) if existing
  end

  # release.assets is an embedded array capped at 30 entries; with 100+
  # packages the target asset is often beyond it. Fetch the full asset
  # list through the release's own assets rel (auto-paginated) — building
  # the URL by hand from the release id produces a malformed path on
  # octokit 7.
  def find_asset(release, filename)
    release.rels[:assets].get.data.find { |a| a.name == filename }
  end

  def run
    process_release
  rescue StandardError => e
    puts "Error: #{e.message}"
    puts e.backtrace
    exit 1
  end

  def upload_and_categorize(release, packages)
    uploaded_files = packages.map { |package| upload_package(release, package) }
    categorize_packages(uploaded_files)
  end

  def upload_metadata(release, packages)
    entries = build_manifest_entries(packages)
    [generate_sha256sums(entries), generate_manifest(entries)].each do |file|
      puts "Uploading metadata file #{file.basename} (always overwritten)"
      force_upload(release, file)
    end
  end

  def upload_package(release, package)
    filename = package.basename.to_s
    puts "Processing #{filename}..."

    if existing_asset = find_asset(release, filename)
      if ENV["FORCE_REBUILD"] != "true"
        puts "Skipping upload of existing asset #{filename} (FORCE_REBUILD not set)"
        return filename
      end
      remove_existing_asset(release, filename)
    end

    perform_upload(release, package, filename)
    filename
  end

  def validate_environment
    %w[GITHUB_TOKEN TEBAKO_VERSION].each do |var|
      raise "#{var} environment variable is required" unless ENV[var]
    end
  end

  def validate_packages_directory
    packages_dir = Pathname.new("runtime-packages")
    raise "No runtime packages directory found" unless packages_dir.directory?

    packages = packages_dir.glob("*")
    raise "No packages found in runtime-packages directory" if packages.empty?

    puts "Found packages:\n#{packages.map(&:basename).join("\n")}"
    packages
  end
end

ReleaseManager.new.run if $PROGRAM_NAME == __FILE__
