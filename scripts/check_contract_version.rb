#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
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
require "json_schemer"
require "pathname"
require "yaml"

# Contract version agreement check (roadmap 45). The bootstrap <-> runtime
# contract version lives in TWO representations on purpose:
#   - contract.yml at the repo root -- the release pipeline's source of
#     truth (scripts/upload_release.rb emits it into every manifest.json
#     entry, schema/contract.schema.yml governs the file)
#   - TEBAKO_CONTRACT_VERSION in build/src/tebako-main.cpp -- the constant
#     compiled into the runtime and exported as the env var of the same name
# The two must never drift: a contract bump edits both in the same commit,
# and this check fails the platform build workflows (and the spec
# suite) when they disagree.
class ContractVersionCheck
  REPO_ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
  CONTRACT_YML = REPO_ROOT.join("contract.yml").freeze
  SCHEMA_YML = REPO_ROOT.join("schema", "contract.schema.yml").freeze
  DRIVER_SRC = REPO_ROOT.join("build", "src", "tebako-main.cpp").freeze

  DEFINE_PATTERN = /^\s*#\s*define\s+TEBAKO_CONTRACT_VERSION\s+(\d+)u?\s*$/
  # The Rust form (crates/tebako-driver/src/lib.rs in the tebako product
  # repo — the contract-2 driver, consumed as libtebako_driver.a).
  RUST_PATTERN = /pub const TEBAKO_CONTRACT_VERSION: u32 = (\d+);/

  def initialize(contract_yml: CONTRACT_YML, schema_yml: SCHEMA_YML, driver_src: nil)
    @contract_yml = Pathname.new(contract_yml)
    @schema_yml = Pathname.new(schema_yml)
    @driver_src = Pathname.new(driver_src || ENV["TEBAKO_DRIVER_SRC"] || DRIVER_SRC)
  end

  # Human-readable violations: schema errors against contract.yml, a missing
  # compiled-in constant, or a yaml/driver disagreement. Empty when the
  # contract is well-formed and both representations agree.
  def errors
    violations = schema_errors
    if violations.empty? && driver_version.nil?
      violations << "#{@driver_src} carries no TEBAKO_CONTRACT_VERSION constant -- " \
                    "the runtime must compile its contract version in (roadmap 45)"
    elsif violations.empty? && driver_version != yaml_version
      violations << "contract.yml contract_version is #{yaml_version} but the compiled-in " \
                    "TEBAKO_CONTRACT_VERSION in #{@driver_src} is #{driver_version} -- " \
                    "a contract bump edits both in the same commit (roadmap 45)"
    end
    violations
  end

  def valid?
    errors.empty?
  end

  def yaml_version
    data = YAML.load_file(@contract_yml)
    data.is_a?(Hash) ? data["contract_version"] : nil
  end

  def driver_version
    @driver_src.each_line do |line|
      match = line.match(DEFINE_PATTERN) || line.match(RUST_PATTERN)
      return match[1].to_i if match
    end
    nil
  end

  private

  def schema_errors
    schemer = JSONSchemer.schema(YAML.load_file(@schema_yml))
    schemer.validate(YAML.load_file(@contract_yml)).map do |problem|
      "#{@contract_yml}: #{problem.fetch("error", problem.to_s)}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    check = ContractVersionCheck.new
    if check.valid?
      puts "contract version #{check.yaml_version}: contract.yml and the compiled-in TEBAKO_CONTRACT_VERSION agree"
    else
      check.errors.each { |error| puts "::error::#{error}" }
      exit 1
    end
  rescue StandardError => e
    puts "::error::contract version check failed: #{e.message}"
    exit 1
  end
end
