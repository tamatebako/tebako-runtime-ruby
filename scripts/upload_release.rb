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

# The Platform model owns the (os, arch) → release platform id lookup
# (HOST_IDS, mirroring tpkg::Platform in tebako-rs) — expected asset names
# are built through it, never by formula.
$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_runtime_builder"

RUNTIME_REPO = "tamatebako/tebako-runtime-ruby"

# The bootstrap <-> runtime contract version (roadmap 45) emitted into every
# manifest entry. contract.yml at the repo root is the release pipeline's
# single source of truth; the compiled-in TEBAKO_CONTRACT_VERSION in the
# runtime driver is CI-locked to agree with it (scripts/check_contract_version.rb).
CONTRACT_YML = Pathname.new(File.expand_path("../contract.yml", __dir__)).freeze

# Upload release manager for tebako build workflow
class ReleaseManager # rubocop:disable Metrics/ClassLength
  # The era-2 release card (spec 18 C2): every runtime package carries a
  # builder-emitted `<package>.contract.yaml` sidecar (contract_era,
  # image_layout, mount_root, built_from) that manifest_entry folds into
  # the manifest.json entry. A package without it — or one declaring an
  # era this pipeline does not speak — is refused by name (fail closed;
  # S11/S16): a manifest entry never goes out under-declared.
  CONTRACT_SIDECAR_SUFFIX = ".contract.yaml"
  CONTRACT_ERA = 2

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

  # The per-platform manifest merge: the previous manifest's entries for
  # OTHER platforms persist verbatim; this run's entries replace only
  # their own platform's. A release never loses coverage because one
  # platform republished (and the fold-by-download machinery is dead —
  # the release IS the store: its assets persist, the manifest merges).
  def merged_manifest_entries(new_entries)
    covered = new_entries.map { |entry| entry[:platform] }.uniq
    kept = previous_manifest_entries.reject { |entry| covered.include?(entry[:platform]) }
    (kept + new_entries).sort_by { |entry| entry[:filename].to_s }
  end

  # The release's existing manifest.json, symbolized (entry[:image]
  # included), [] when absent/unreadable (a named warning, never a
  # crash — the completeness gate is the arbiter).
  def previous_manifest_entries
    @previous_manifest_entries ||= begin
      data = read_previous_manifest
      data.is_a?(Array) ? data.map { |entry| deep_symbolize(entry) } : []
    rescue StandardError => e
      puts "::warning::could not read the previous manifest.json (#{e.class}: #{e.message}) — merging nothing"
      []
    end
  end

  # The release's existing manifest.json as parsed JSON; nil when the tag
  # has no release or the release carries no manifest asset.
  def read_previous_manifest
    release = find_release
    asset = release && find_asset(release, "manifest.json")
    asset && with_transient_retries { download_asset_json(asset) }
  end

  def deep_symbolize(value)
    case value
    when Hash then value.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = deep_symbolize(v) }
    when Array then value.map { |item| deep_symbolize(item) }
    else value
    end
  end

  def download_asset_json(asset)
    JSON.parse(with_transient_retries { @client.get(asset.browser_download_url) }.to_s)
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

    JSON.parse(env_json).product(expected_ruby_versions(ruby_json)).map do |env, ruby|
      platform = TebakoRuntimeBuilder::Platform.host_id_for(env["os"], env["arch"])
      "tebako-runtime-#{@version}-#{ruby}-#{platform}"
    end
  rescue JSON::ParserError => e
    puts "::warning::Could not compute expected package list: #{e.message}"
    []
  end

  # The prepare job's ruby matrix rows are {version, src_sha256} objects
  # (src_sha256 keys the .build cache); plain string rows from older runs
  # stay accepted.
  def expected_ruby_versions(ruby_json)
    JSON.parse(ruby_json).map { |row| row.is_a?(Hash) ? row.fetch("version") : row }
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

  # The read-only lookup (the manifest merge + the idempotent skip read the
  # existing release): nil when the tag has no release, never creates one.
  def find_release
    with_transient_retries { @client.release_for_tag(RUNTIME_REPO, @tag) }
  rescue Octokit::NotFound
    nil
  end

  def initialize_sections
    { "windows" => [], "macos" => [], "linux-gnu" => [], "linux-musl" => [] }
  end

  def manifest_entry(package, image = nil)
    ruby_version, platform = parse_package_filename(package.basename.to_s)
    contract = contract_sidecar(package)
    filename = package.basename.to_s
    sha256 = Digest::SHA256.file(package).hexdigest
    # The idempotent upload skip reads these (same name + same sha = kept).
    current_shas[filename] = sha256
    current_shas[image_name_for(package)] = Digest::SHA256.file(image).hexdigest if image
    {
      tebako_version: @version,
      contract_era: contract.fetch("contract_era"),
      contract_version: @contract_version,
      ruby_version: ruby_version,
      platform: platform,
      filename: filename,
      sha256: sha256,
      size_bytes: package.size,
      mount_root: contract.fetch("mount_root"),
      image_layout: contract.fetch("image_layout"),
      built_from: contract.fetch("built_from")
    }.tap do |entry|
      # The additive abi line (spec 05 §5): the runtime's own platform
      # string, emitted by build_runtime as <package>.abi. Consumers that
      # predate the key ignore it (the compat window).
      sidecar = Pathname.new("#{package.sub(%r{\.exe\z}, '')}.abi")
      entry[:abi] = sidecar.read.strip if sidecar.file?
      entry[:image] = image_entry(image) if image
    end
  end

  def current_shas
    @current_shas ||= {}
  end

  # The package's builder-emitted contract sidecar (the era-2 release
  # card's provenance half), fail-closed: a missing file, missing keys,
  # or a declared era this pipeline does not speak are named refusals —
  # never a silently under-declared manifest entry (spec 18 C2/S11/S16).
  def contract_sidecar(package)
    path = Pathname.new("#{package.sub(%r{\.exe\z}, '')}#{CONTRACT_SIDECAR_SUFFIX}")
    unless path.file?
      raise "runtime package #{package.basename} carries no #{CONTRACT_SIDECAR_SUFFIX} contract sidecar — " \
            "it was built by a pre-era factory; rebuild it with the current tebako-runtime-ruby (spec 18 C2)"
    end

    data = YAML.load_file(path)
    data = nil unless data.is_a?(Hash)
    missing = %w[contract_era mount_root image_layout built_from] - (data || {}).keys
    unless missing.empty?
      raise "contract sidecar #{path.basename} is missing #{missing.join(", ")} — " \
            "rebuild the package with the current tebako-runtime-ruby (spec 18 C2)"
    end

    era = data.fetch("contract_era")
    unless era == CONTRACT_ERA
      raise "contract sidecar #{path.basename} declares contract_era #{era.inspect} but this release pipeline " \
            "speaks #{CONTRACT_ERA} — upgrade tebako-runtime-ruby"
    end

    data
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
    # Entries BEFORE uploads: the sha256s they compute feed the idempotent
    # upload skip (same name + same sha = no re-upload), and the merged
    # manifest keeps every other platform's entries.
    entries = merged_manifest_entries(build_manifest_entries(packages))
    return audit_release(release) if audit_only?

    publish_release(release, packages, entries)
    verify_completeness(release)
  end

  # AUDIT_ONLY (the 04 audit / a publish dry run): no uploads, no notes —
  # the release is only verified against the expected matrix.
  def audit_release(release)
    puts "AUDIT mode: no uploads — verifying the release against the expected matrix only"
    verify_completeness(release)
    nil
  end

  def publish_release(release, packages, entries)
    sections, image_sections = upload_and_categorize(release, packages, entries)
    upload_metadata(release, entries)
    release_body = generate_release_notes(sections, image_sections)
    with_transient_retries { @client.update_release(release.url, body: release_body) }
    puts "Successfully updated release notes"
  end

  def audit_only?
    ENV["AUDIT_ONLY"] == "true"
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

  # The release notes list the MERGED set (every platform's entries), not
  # just this run's uploads — a per-platform publish must not shrink the
  # documented catalog.
  def upload_and_categorize(release, packages, entries)
    packages.each { |package| upload_package(release, package) }
    [categorize_packages(entries.map { |entry| entry[:filename] }),
     categorize_images(entries.filter_map { |entry| entry.dig(:image, :filename) })]
  end

  def upload_metadata(release, entries)
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

  # An asset with the same name AND the same sha256 (the previous
  # manifest's entry) is kept — an unchanged artifact never re-uploads.
  def skip_existing_asset?(release, filename)
    return false unless find_asset(release, filename)
    return false if replace_existing_asset?(release, filename)

    puts "Skipping upload of existing asset #{filename} (unchanged)"
    true
  end

  # FORCE_REBUILD always replaces. Otherwise a same-named asset whose
  # previous-manifest sha256 differs from the current content's has moved —
  # delete it so the caller re-uploads (GitHub deletion is only eventually
  # consistent; the upload retry absorbs the 422s). Same sha — or no
  # previous entry at all (an unreadable manifest fails conservative) —
  # keeps the asset.
  def replace_existing_asset?(release, filename)
    if ENV["FORCE_REBUILD"] == "true"
      remove_existing_asset(release, filename)
      return true
    end
    previous = previous_manifest_entries.find { |entry| entry[:filename] == filename }
    current = current_shas[filename]
    return false unless previous && previous[:sha256] && current && previous[:sha256] != current

    puts "Re-uploading #{filename}: content changed (#{previous[:sha256][0, 12]}… → #{current[0, 12]}…)"
    remove_existing_asset(release, filename)
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

    # `.abi` sidecars (the runtime's platform string) and `.contract.yaml`
    # sidecars (the era-2 release card provenance) are manifest inputs read
    # by manifest_entry — never packages of their own.
    packages = packages_dir.glob("*").reject do |p|
      p.extname == ".abi" || p.basename.to_s.end_with?(CONTRACT_SIDECAR_SUFFIX)
    end
    raise "No packages found in runtime-packages directory" if packages.empty?

    puts "Found packages:\n#{packages.map(&:basename).join("\n")}"
    packages
  end
end

ReleaseManager.new.run if $PROGRAM_NAME == __FILE__
