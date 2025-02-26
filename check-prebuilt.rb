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
require "date"
require "json"
require "octokit"
require "open-uri"
require "thor"

class PrebuiltMatrix < Thor
  RUNTIME_REPO = "tamatebako/tebako-runtime-ruby"
  PLATFORMS = %w[macos ubuntu windows-msys alpine].freeze

  desc "generate VERSION", "Generate build matrix for given version"
  method_option :force_rebuild, type: :boolean, default: false, desc: "Force rebuild all packages"
  def generate(version)
    builder = RuntimeBuilder.new(version, options[:force_rebuild])
    builder.build_matrix
  end
end

class RuntimeBuilder
  RUNTIME_REPO = PrebuiltMatrix::RUNTIME_REPO
  PLATFORMS = PrebuiltMatrix::PLATFORMS

  def initialize(version, force_rebuild: false)
    @client = if ENV["GITHUB_TOKEN"]
                Octokit::Client.new(access_token: ENV["GITHUB_TOKEN"])
              else
                Octokit::Client.new
              end
    @force_rebuild = force_rebuild
    @tebako_version = version
  end

  def build_matrix
    matrix = { "include" => build_combinations }
    File.write("build-matrix.json", matrix.to_json)
  end

  private

  def read_matrix_file(platform)
    url = "https://raw.githubusercontent.com/tamatebako/tebako/v#{@tebako_version}/.github/matrices/#{platform}.json"
    JSON.parse(URI.open(url).read)["full"]
  end

  def find_release_info(filename)
    releases = @client.releases(RUNTIME_REPO)
    releases.each do |release|
      assets = @client.release_assets(RUNTIME_REPO, release.id)
      asset = assets.find { |a| a.name == filename }
      return { "url" => asset.browser_download_url } if asset
    end
    nil
  rescue Octokit::Unauthorized
    warn "Warning: Invalid GitHub token or no access to #{RUNTIME_REPO}"
    nil
  rescue Octokit::TooManyRequests
    warn "Warning: GitHub API rate limit exceeded"
    nil
  rescue Octokit::Error => e
    warn "Warning: GitHub API error: #{e.message}"
    nil
  end

  def load_matrices
    PLATFORMS.to_h { |platform| [platform, read_matrix_file(platform)] }
  end

  def tag_environments_with_platforms(matrices)
    matrices.flat_map do |platform, data|
      data["env"].map { |env| env.merge("platform" => platform.sub("-msys", "")) }
    end
  end

  def build_config(ruby_ver, env_config, arch = nil)
    platform = env_config["platform"]
    os = env_config["os"]
    platform_name, arch_info = get_platform_info(platform, os, env_config, arch)
    ext = platform == "windows" ? ".exe" : ""
    filename = "tebako-ruby-#{@tebako_version}-#{ruby_ver}-#{platform_name}-#{arch_info}#{ext}"

    {
      "ruby_ver" => ruby_ver,
      "env" => env_config.merge("arch" => arch_info),
      "platform" => platform,
      "platform_name" => platform_name,
      "arch" => arch_info,
      "filename" => filename
    }
  end

  def get_platform_info(platform, os, env_config, arch = nil)
    case platform
    when "macos"
      version = os.match(/macos-(\d+)/)[1]
      ["macos#{version}", arch || "x86_64"]
    when "windows"
      %w[windows x64]
    when "ubuntu"
      version = os.match(/ubuntu-(\d+\.\d+)/)[1]
      ["ubuntu#{version}", arch || "x86_64"]
    when "alpine"
      ["alpine#{env_config["ALPINE_VER"]}", arch || "x86_64"]
    end
  end

  def build_combinations
    matrices = load_matrices
    ruby_versions = matrices.values.map { |m| m["ruby"] }.flatten.uniq
    env_configs = tag_environments_with_platforms(matrices)

    ruby_versions.each_with_object([]) do |ruby_ver, combinations|
      env_configs.each do |env_config|
        case env_config["platform"]
        when "macos", "ubuntu", "alpine"
          # Generate both x86_64 and arm64 for macOS, Ubuntu, and Alpine
          combinations << build_config(ruby_ver, env_config, "x86_64")
          combinations << build_config(ruby_ver, env_config, "arm64")
        else
          combinations << build_config(ruby_ver, env_config)
        end
        combinations.last["release"] = find_release_info(combinations.last["filename"])
      end
    end
  end
end

PrebuiltMatrix.start(ARGV) if __FILE__ == $PROGRAM_NAME
