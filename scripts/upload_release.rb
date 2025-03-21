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
require "json"
require "pathname"

RUNTIME_REPO = "tamatebako/tebako-runtime-ruby"

# Upload release manager for tebako build workflow
class ReleaseManager # rubocop:disable Metrics/ClassLength
  def initialize
    validate_environment
    @client = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
    @version = ENV.fetch("TEBAKO_VERSION")
    @tag = "v#{@version}"
    @release_title = "Tebako runtime packages #{@tag}"
  end

  def categorize_packages(filenames)
    sections = initialize_sections
    filenames.each do |filename|
      platform = %w[windows macos linux-gnu linux-musl].find { |p| filename.include?(p) }
      sections[platform] << filename if platform
    end
    sections
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
    body
  end

  def generate_section(platform, files)
    return "" if files.empty?

    section = "\n### #{platform_display_name(platform)} executables\n"
    files.each { |file| section += "- #{file}\n" }
    section
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

  def perform_upload(release, package, filename)
    puts "Uploading #{filename}"
    @client.upload_asset(
      release.url,
      package.to_s,
      content_type: "application/octet-stream",
      name: filename
    )
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
    sections = upload_and_categorize(release, packages)
    release_body = generate_release_notes(sections)
    @client.update_release(release.url, body: release_body)
    puts "Successfully updated release notes"
  end

  def remove_existing_asset(release, filename)
    puts "Deleting existing asset #{filename}"
    existing = release.assets.find { |a| a.name == filename }
    @client.delete_release_asset(existing.id)
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

  def upload_package(release, package)
    filename = package.basename.to_s
    puts "Processing #{filename}..."

    if existing_asset = release.assets.find { |a| a.name == filename }
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
