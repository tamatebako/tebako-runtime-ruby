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

# This factory's tebako-release declaration (ecosystem invariant 10: the
# release machinery's single owner is tamatebako/tebako-release —
# the gem the Gemfile pins at contract.yml's release_tooling tag). This
# file declares THIS factory's identity + policy through the gem's
# adapter seam; the machinery itself is never copied here. The
# tebako-release exe loads this file before dispatching (upload|sign).

$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_runtime_builder"

# The factory's release policy, delegated to the version/capability
# models that own each grammar (TebakoRuntimeBuilder::RubyVersion,
# TebakoRuntimeBuilder::Capabilities — spec 00 §10's single-owner rule;
# nothing here re-derives a name or a grammar).
class RubyReleaseAdapter < TebakoRelease::Adapter
  # The (version × arch) capability floor, mirrored from the build
  # matrix's exclude-matrix (the gate's single owner is
  # RubyVersion#msys_arm64_capable?): a windows/arm64 leg exists only
  # for a capable ruby — an incapable pair is never built, so the audit
  # must never expect it (the v0.16.27 arm64 audit, run 35683750004,
  # demanded 42 assets for rubies the architecture does not serve).
  def capable_pair?(os, arch, version)
    !(os == "windows" && arch == "arm64" &&
      !TebakoRuntimeBuilder::RubyVersion.new(version).msys_arm64_capable?)
  end

  # The additive capabilities display line of a manifest entry (yjit /
  # zjit — versions catalog plan 04): display metadata owned by this
  # factory, never a selector axis. Sourced from the same truth table
  # boot smoke asserts (Capabilities), so manifest and smoke can never
  # disagree.
  def capabilities(version:, platform_id:)
    TebakoRuntimeBuilder::Capabilities.for(
      ruby_version: version, platform_id: platform_id
    )
  end

  # The PE name the store materializes next to a windows exe so its
  # imports resolve (x64-ucrt-ruby<XY>0.dll — RubyVersion#msys_dll_name
  # is the name's single owner). Only the msys legs stage a DLL beside
  # the package, so the uploader consults this facet only there.
  def dll_install_name(version, host_id)
    TebakoRuntimeBuilder::RubyVersion.new(version).msys_dll_name(host_id)
  end

  # Spec 36: this factory publishes the bundle era — one <stem>.tar.gz
  # per leg (exe + env image + DLL + in-bundle SHA256SUMS) instead of
  # the per-file enumeration. Opt-in is deliberate and factory-scoped:
  # the bundle-era resolver ships downstream first (spec 36 §4's compat
  # window), and pre-bundle releases stay installable forever.
  def bundle_publish?
    true
  end
end

TebakoRelease.configure(
  repo: "tamatebako/tebako-runtime-ruby",
  language: "ruby",
  title_prefix: "Tebako Ruby runtime packages",
  contract_yml: File.expand_path("../contract.yml", __dir__),
  adapter: RubyReleaseAdapter.new
)
