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
require "yaml"

RUNTIME_REPO = "tamatebako/tebako-runtime-ruby"

# The bootstrap <-> runtime contract version (roadmap 45) emitted into every
# manifest entry. contract.yml at the repo root is the release pipeline's
# single source of truth; the compiled-in TEBAKO_CONTRACT_VERSION in the
# runtime driver is CI-locked to agree with it (scripts/check_contract_version.rb).
CONTRACT_YML = Pathname.new(File.expand_path("../contract.yml", __dir__)).freeze

# Upload release manager for tebako build workflow
class ReleaseManager # rubocop:disable Metrics/ClassLength
  def initialize(client: nil)
    validate_environment
    @client = client || Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"), auto_paginate: true)
    @version = ENV.fetch("TEBAKO_VERSION")
    @tag = "v#{@version}"
    @release_title = "Tebako runtime packages #{@tag}"
    @contract_version = load_contract_version
  end

  # Fail closed: a release whose manifest cannot name the runtime contract
  # version never ships (the bootstrap negotiates on this field).
  def load_contract_version
    data = YAML.load_file(CONTRACT_YML)
    version = data.is_a?(Hash) ? data["contract_version"] : nil
    return version if version.is_a?(Integer) && version.positive?

    raise "#{CONTRACT_YML} does not define a positive integer contract_version (roadmap 45)"
  end

  # One manifest entry per runtime PACKAGE (the executable). A sibling
  # filesystem image (<package>.tfs, item 30) is folded into the
  # package's entry as an additive `image` key -- top-level entries stay
  # one-per-package so existing consumers (which match on ruby_version /
  # platform / filename) are unaffected, and a .tfs file never becomes
  # a top-level entry of its own. The additive `contract_version` key
  # (roadmap 45) follows the same compat rule.
  def build_manifest_entries(packages)
    executables, images = packages.partition { |package| !image_file?(package) }
    executables.sort_by { |package| package.basename.to_s }.map do |package|
      image = images.find { |candidate| candidate.basename.to_s == image_name_for(package) }
      manifest_entry(package, image)
    end
  end

  def categorize_packages(filenames)
    categorize(filenames, images: false)
  end

  def categorize_images(filenames)
    categorize(filenames, images: true)
  end

  def categorize(filenames, images:)
    sections = initialize_sections
    filenames.each do |filename|
      next unless filename.end_with?(".tfs") == images

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

  def generate_release_notes(sections, image_sections = nil)
    body = <<~BODY
      ## Tebako runtime packages

      Release version: #{@tag}
      Build date: #{Time.now.strftime("%Y-%m-%d")}

    BODY

    body += sections_markup(sections)
    body += sections_markup(image_sections, kind: "filesystem images") if image_sections
    body += "\nChecksums: see the `SHA256SUMS.txt` asset.\n"
    body += "Machine-readable package index: see the `manifest.json` asset.\n"
    body
  end

  def sections_markup(sections, kind: "executables")
    sections.map { |platform, files| generate_section(platform, files, kind: kind) }.join
  end

  def generate_section(platform, files, kind: "executables")
    return "" if files.empty?

    section = "\n### #{platform_display_name(platform)} #{kind}\n"
    files.each { |file| section += "- #{file}\n" }
    section
  end

  # Both the executable and its filesystem image are checksummed; each image
  # line directly follows its package's line.
  def generate_sha256sums(entries)
    path = Pathname.new("SHA256SUMS.txt")
    path.write("#{sha256sum_lines(entries).join("\n")}\n")
    path
  end

  def sha256sum_lines(entries)
    entries.flat_map do |entry|
      lines = ["#{entry[:sha256]}  #{entry[:filename]}"]
      image = entry[:image]
      lines << "#{image[:sha256]}  #{image[:filename]}" if image
      lines
    end
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

  def manifest_entry(package, image = nil)
    ruby_version, platform = parse_package_filename(package.basename.to_s)
    {
      tebako_version: @version,
      contract_version: @contract_version,
      ruby_version: ruby_version,
      platform: platform,
      filename: package.basename.to_s,
      sha256: Digest::SHA256.file(package).hexdigest,
      size_bytes: package.size
    }.tap do |entry|
      # The additive abi line (spec 05 §5): the runtime's own platform
      # string, emitted by build_runtime as <package>.abi. Consumers that
      # predate the key ignore it (the compat window).
      sidecar = Pathname.new("#{package.sub(%r{\.exe\z}, '')}.abi")
      entry[:abi] = sidecar.read.strip if sidecar.file?
      entry[:image] = image_entry(image) if image
    end
  end

  # The additive image metadata: name, sha256, size (consumers ignoring the
  # `image` key keep working; item 30's compat rule).
  def image_entry(image)
    {
      filename: image.basename.to_s,
      sha256: Digest::SHA256.file(image).hexdigest,
      size_bytes: image.size
    }
  end

  def image_file?(package)
    package.basename.to_s.end_with?(".tfs")
  end

  def image_name_for(package)
    "#{package.basename.to_s.sub(/\.exe\z/, "")}.tfs"
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
    upload_once(release, package, filename)
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

  def upload_once(release, package, filename)
    @client.upload_asset(release.url, package.to_s,
                         content_type: "application/octet-stream",
                         name: filename)
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
    sections, image_sections = upload_and_categorize(release, packages)
    upload_metadata(release, packages)
    release_body = generate_release_notes(sections, image_sections)
    with_transient_retries { @client.update_release(release.url, body: release_body) }
    puts "Successfully updated release notes"
    verify_completeness(release)
  end

  def report_missing_packages(packages)
    executables, images = package_names(packages)
    report_missing_executables(executables)
    report_image_gaps(executables, images)
  end

  def package_names(packages)
    executables, images = packages.partition { |package| !image_file?(package) }
    [
      executables.map { |package| package.basename.to_s.sub(/\.exe\z/, "") },
      images.map { |package| package.basename.to_s.sub(/\.tfs\z/, "") }
    ]
  end

  def report_missing_executables(found)
    missing = expected_package_names - found
    return if missing.empty?

    puts "::warning::Release incomplete: #{missing.size} expected runtime package(s) are missing"
    missing.sort.each { |name| puts "::warning::Missing runtime package: #{name}" }
    puts "Continuing with #{found.size} available package(s); the completeness check at " \
         "the end of the publish fails the run if these are still missing"
  end

  # The release job runs with always(), so packages from failed matrix legs
  # simply never land -- the publish must not LOOK complete when it is not.
  # After all uploads, re-list the release assets (paginated) and compare
  # against the full expected set: every matrix package (windows names may
  # carry .exe), every package's filesystem image, and the two metadata
  # files. Any gap fails the run loudly; without an expected matrix there
  # is nothing to verify against (warn and pass).
  def verify_completeness(release)
    expected = expected_asset_names
    if expected.empty?
      puts "::warning::No expected matrix available; release completeness is not verifiable"
      return
    end

    missing = missing_assets(release, expected)
    return if missing.empty?

    puts "::error::Release #{@tag} is incomplete: #{missing.size} expected asset(s) missing"
    missing.sort.each { |name| puts "::error::Missing asset: #{name}" }
    raise "Release #{@tag} is incomplete (#{missing.size} missing asset(s))"
  end

  # Windows executables may or may not carry the .exe suffix (the artifact
  # naming is still settling), so a package expectation matches both.
  def missing_assets(release, expected)
    present = with_transient_retries { release.rels[:assets].get.data.map(&:name) }
    expected.reject { |name| present.include?(name) || present.include?("#{name}.exe") }
  end

  def expected_asset_names
    packages = expected_package_names
    return [] if packages.empty?

    packages + packages.map { |name| "#{name}.tfs" } + %w[SHA256SUMS.txt manifest.json]
  end

  def report_image_gaps(executables, images)
    (executables - images).sort.each do |name|
      puts "::warning::Runtime package #{name} has no filesystem image (#{name}.tfs); " \
           "the package stays consumable but the image-era lean flow cannot use it"
    end
    (images - executables).sort.each do |name|
      puts "::warning::Filesystem image #{name}.tfs has no matching runtime package; " \
           "it is uploaded but carries no manifest entry"
    end
  end

  def remove_existing_asset(release, filename)
    puts "Deleting existing asset #{filename}"
    existing = find_asset(release, filename)
    with_transient_retries { @client.delete_release_asset(existing.id) } if existing
  end

  # release.assets is an embedded array capped at 30 entries; with 100+
  # packages the target asset is often beyond it. Fetch the full asset
  # list through the release's own assets rel (auto-paginated) — building
  # the URL by hand from the release id produces a malformed path on
  # octokit 7.
  def find_asset(release, filename)
    with_transient_retries { release.rels[:assets].get.data.find { |a| a.name == filename } }
  end

  # GET/DELETE/PUT calls other than the asset upload share the same
  # transient network failure modes; retry them (they are idempotent).
  def with_transient_retries(attempts: 4)
    yield
  rescue Net::WriteTimeout, Net::ReadTimeout, Faraday::TimeoutError, Faraday::ConnectionFailed => e
    attempts -= 1
    raise if attempts <= 0

    puts "#{e.class}; retrying in 5s (#{attempts} attempt(s) left)"
    sleep 5
    retry
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
    [categorize_packages(uploaded_files), categorize_images(uploaded_files)]
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
    return filename if skip_existing_asset?(release, filename)

    perform_upload(release, package, filename)
    filename
  end

  # An asset with the same name is kept unless FORCE_REBUILD asks for a
  # re-upload (delete first; GitHub deletion is only eventually consistent,
  # the upload retry absorbs the resulting 422s).
  def skip_existing_asset?(release, filename)
    return false unless find_asset(release, filename)

    if ENV["FORCE_REBUILD"] == "true"
      remove_existing_asset(release, filename)
      return false
    end
    puts "Skipping upload of existing asset #{filename} (FORCE_REBUILD not set)"
    true
  end

  def validate_environment
    %w[GITHUB_TOKEN TEBAKO_VERSION].each do |var|
      raise "#{var} environment variable is required" unless ENV[var]
    end
  end

  def validate_packages_directory
    packages_dir = Pathname.new("runtime-packages")
    raise "No runtime packages directory found" unless packages_dir.directory?

    # `.abi` sidecars are manifest inputs (the runtime's platform string,
    # read by manifest_entry) — never packages of their own.
    packages = packages_dir.glob("*").reject { |p| p.extname == ".abi" }
    raise "No packages found in runtime-packages directory" if packages.empty?

    puts "Found packages:\n#{packages.map(&:basename).join("\n")}"
    packages
  end
end

ReleaseManager.new.run if $PROGRAM_NAME == __FILE__
