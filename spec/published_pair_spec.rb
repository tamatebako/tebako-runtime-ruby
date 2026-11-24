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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "open3"
require "tmpdir"

# The published-pair acceptance (tebako#1125's class; the
# tebako-runtime-r#6 shape): explicit opt-in ONLY (run with
# `bundle exec rspec --tag published_pair` — the default suite never
# fetches the registry). The build-tree boot smoke cannot see this
# flow: what it boots is the freshly built pair off
# TEBAKO_RUNTIME_IMAGE; what a user runs is the registry default's
# bytes, fetched + verified + mounted by the real machinery. So the
# acceptance installs the registry default's ruby pair through the
# contract-pinned tebako CLI (add-registry + install into a scratch
# TEBAKO_HOME), proves the shim dispatch answers, and then runs the
# tebako#1125 native-open probe against the INSTALLED bytes — the
# published 0.17.15 macos pair answered every ruby-level check while
# dyld stripped its boot-head insertion on macOS 14 (the missing
# allow-dyld-environment-variables grant; tolerated by the macos-15
# runners, so no build leg could see it). publish.yml's acceptance
# jobs run this spec per platform once the registry row lands on main;
# the macos-arm64 leg pins macos-14 on purpose (the stripping canary).
#
# Knobs (all optional):
#   TEBAKO_PUBLISHED_PAIR_CLI       the tebako CLI (default: TEBAKO_CLI,
#                                   then tebako on PATH)
#   TEBAKO_PUBLISHED_PAIR_REGISTRY  the registry ref (default: this
#                                   factory's live registry)
#   TEBAKO_PUBLISHED_PAIR_HOME      TEBAKO_HOME for the install
#                                   (default: a mktmpdir, cleaned up)
#   TEBAKO_SMOKE_RUBY_HEADERS / TEBAKO_SMOKE_TFS
#                                   the native-open fixture's toolchain
#                                   (as in the boot smoke)
RSpec.describe "the published-pair acceptance (tebako#1125)", :published_pair do
  def default_registry
    "tfs:github:tamatebako/tebako-runtime-ruby"
  end

  def cli_env(home)
    # The child env is REPLACED, not inherited (the boot smoke's lesson):
    # any tebako/preload leftover the host setup leaks in would steer the
    # install or the dispatch away from the scratch store under test.
    env = TebakoRuntimeBuilder::BootSmoke::ENV_SCRUBBED.to_h { |key| [key, nil] }
    ENV.each_key { |key| env[key] = nil if key.start_with?("TEBAKO_") }
    env.merge("TEBAKO_HOME" => home)
  end

  def resolve_cli
    candidate = ENV.fetch("TEBAKO_PUBLISHED_PAIR_CLI", nil) || ENV.fetch("TEBAKO_CLI", nil) || "tebako"
    found = executable_file?(candidate) ? File.expand_path(candidate) : search_path_for(candidate)
    return found if found

    raise TebakoRuntimeBuilder::Error.new(
      "no tebako CLI resolvable (#{candidate}) — the published-pair acceptance drives the real install " \
      "machinery (TEBAKO_PUBLISHED_PAIR_CLI / TEBAKO_CLI; tamatebako/tebako's releases ship the per-platform CLI)", 141
    )
  end

  def executable_file?(path)
    File.file?(path) && File.executable?(path)
  end

  def search_path_for(candidate)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      path = File.join(dir, candidate)
      return path if executable_file?(path)
    end
    nil
  end

  # The install steps are GATES: a red add-registry/install leaves the
  # exec probes nothing to run against — name the step and stop there.
  def cli_gate(name, argv)
    out, err, status = Open3.capture3(cli_env(home), cli, *argv)
    expect(status&.exitstatus).to eq(0),
                                  "published-pair: #{name} failed (exit #{status&.exitstatus.inspect})\n" \
                                  "stdout: #{out}\nstderr: #{err}"
  end

  # The scratch store is GROUP-level state: RSpec runs each example in a
  # fresh instance (an @ivar memo would mint one tmpdir PER EXAMPLE and
  # the after(:all) cleanup would see only the before(:all) instance's),
  # so the home lives on the group class — one install serves all three
  # examples (the later examples' install gates are idempotent no-ops
  # against it) and the cleanup removes exactly that one tree.
  class << self
    attr_accessor :shared_home
  end

  def home
    self.class.shared_home ||= ENV.fetch("TEBAKO_PUBLISHED_PAIR_HOME", nil) ||
                               Dir.mktmpdir("tebako-ruby-published-pair")
  end

  def cli
    @cli ||= resolve_cli
  end

  def registry
    ENV.fetch("TEBAKO_PUBLISHED_PAIR_REGISTRY", default_registry)
  end

  # The installed pair's runtime dir: exactly one entry under the scratch
  # store's runtimes/ (a fresh install into a fresh home).
  def installed_runtime_dir
    entries = Dir.glob(File.join(home, "runtimes", "*")).select { |dir| File.directory?(dir) }
    names = entries.map { |dir| File.basename(dir) }
    expect(entries.length).to eq(1),
                              "published-pair: expected exactly one installed runtime under #{home}/runtimes, " \
                              "found #{names.empty? ? "none" : names.join(", ")}"
    entries.first
  end

  # The store entry holds the exe amid its marker/signature sidecars
  # (.sha256/.origin/.yaml/.asc/.json — newer CLIs seal the pair with
  # signature files the boot smoke's suffix filter predates), so the
  # acceptance hands BootSmoke the exe path itself, never the directory.
  def sidecar_suffixes
    %w[.tfs .dwarfs .abi .sha256 .origin .yaml .dll .asc .json].freeze
  end

  def installed_exe
    Dir.glob(File.join(installed_runtime_dir, "tebako-runtime-*")).find do |path|
      File.file?(path) && File.executable?(path) &&
        sidecar_suffixes.none? { |suffix| path.end_with?(suffix) }
    end
  end

  def smoke
    @smoke ||= TebakoRuntimeBuilder::BootSmoke.new(installed_exe)
  end

  before(:all) do
    home # resolve the scratch home before any example mutates it
  end

  after(:all) do
    home_dir = self.class.shared_home
    next unless home_dir && !ENV.fetch("TEBAKO_PUBLISHED_PAIR_HOME", nil) && File.directory?(home_dir)

    FileUtils.remove_entry(home_dir)
  end

  before do
    next if RSpec.configuration.inclusion_filter.rules.key?(:published_pair) ||
            ENV.fetch("TEBAKO_PUBLISHED_PAIR", nil) == "1"

    skip "the published-pair acceptance is an explicit opt-in " \
         "(bundle exec rspec --tag published_pair — it installs the registry default's pair over the network)"
  end

  it "installs the registry default's pair through the real machinery" do
    cli_gate("add-registry #{registry}", ["add-registry", registry])
    cli_gate("install ruby (the registry default)", %w[install ruby])
    expect(installed_exe).not_to be_nil, "published-pair: no runtime exe under #{installed_runtime_dir}"
    expect(File.file?("#{installed_exe}.tfs")).to be(true),
                                                  "published-pair: the env image #{installed_exe}.tfs did not install"
  end

  it "answers through the materialized shim (the dispatch proof)" do
    cli_gate("install ruby (idempotent)", %w[install ruby])
    shim = File.join(home, "shims", "ruby")
    expect(File.file?(shim)).to be(true), "published-pair: no #{shim} after a green install"
    out, err, status = Open3.capture3(cli_env(home), shim, "--version")
    expect(status&.exitstatus).to eq(0),
                                  "published-pair: shim ruby --version failed\nstdout: #{out}\nstderr: #{err}"
    expect(out).to match(/ruby \d+\.\d+\.\d+/), "published-pair: ruby --version printed #{out.inspect}"
  end

  it "serves the unpatched native extension raw-open probe against the published bytes (tebako#1125)" do
    skip "the native-open scenario is POSIX-only (windows class L is its own phase)" if smoke.platform.msys?

    cli_gate("install ruby (idempotent)", %w[install ruby])
    run = smoke.run("native_open")
    expect(run).to be_booted, "expected the installed pair to boot and report — #{run.failure_summary}"
    expect(run.state("native_open_ext_load")).to eq("ok"), "detail: #{run.detail("native_open_ext_load")}"
    expect(run.state("env_image_raw_open")).to eq(smoke.expected_native_open_state),
                                               "detail: #{run.detail("env_image_raw_open")}"
    expect(run.state("payload_image_raw_open")).to eq(smoke.expected_native_open_state),
                                                   "detail: #{run.detail("payload_image_raw_open")}"
    # The entitlement plane's verdict against the PUBLISHED bytes: the
    # profile this factory now ships (allow-dyld-environment-variables)
    # is what lets the boot-head insertion survive a stripping macOS —
    # the published 0.17.15 pair failed exactly here on macOS 14.
    expect(run.state("boot_head_insertion")).to eq(smoke.expected_boot_head_insertion_state),
                                                "detail: #{run.detail("boot_head_insertion")}"
  end
end
