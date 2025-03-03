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

# Matrix generator for tebako build workflow
class MatrixGenerator
  def initialize
    @logger = Logger.new($stdout)
    @logger.formatter = proc do |severity, _, _, msg|
      "#{severity}: #{msg}\n"
    end
  end

  def determine_ruby_suffix
    event_name = ENV.fetch("GITHUB_EVENT_NAME", "unknown")
    suffix = event_name == "pull_request" ? "tidy" : "full"
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
    @logger.info("Generated env matrix:")
    @logger.info(JSON.pretty_generate(env))
    write_output("env-matrix", env)
  rescue StandardError => e
    @logger.error("Error processing env matrix: #{e.message}")
    @logger.error("matrix.json content:")
    @logger.error(JSON.pretty_generate(data))
    raise
  end

  def process_ruby_matrix(data)
    @logger.info("Processing ruby matrix...")
    suffix = determine_ruby_suffix
    ruby_versions = get_ruby_versions(data, suffix)

    @logger.info("Generated ruby matrix for #{suffix}: #{JSON.pretty_generate(ruby_versions)}")
    write_output("ruby-matrix", ruby_versions)
  rescue StandardError => e
    @logger.error("Error processing ruby matrix: #{e.message}")
    @logger.error("matrix.json content:")
    @logger.error(JSON.pretty_generate(data))
    raise
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
