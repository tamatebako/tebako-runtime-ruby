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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "yaml"

module TebakoRuntimeBuilder
  # The env image's L1 payload manifest (spec 03 §1, spec 22 §4): the
  # /__tpkg__/manifest.yaml the driver reads post-mount. Its first job is
  # the class-R `materialize:` declaration — the windows CA bundle
  # (CaBundle) must exist on the HOST for libcrypto's own native IO, so
  # the msys image declares /ssl/cert.pem and the driver extracts it per
  # boot to <TEBAKO_EXEC_CACHE>/resources/<image-key>/ssl/cert.pem (the
  # boot shim's SSL_CERT_FILE export names that path — build/CMakeLists.txt).
  # POSIX images declare nothing: they ship no bundle (vcpkg's unix openssl
  # builds with --openssldir=/etc/ssl, which the host supplies).
  #
  # The grammar is owned by docs/spec/schemas/payload-manifest.yaml
  # (tamatebako/tebako, mirrored by tpkg's PayloadManifest): a malformed
  # manifest is a named boot refusal (exit 65) on EVERY leg, so this
  # emitter sticks to the locked capability truth tables and digest shapes
  # exactly. identity.digest follows the spec 03 §7 fixed-point rule:
  # blob_sha256 is zeroed inside the image (the real digest lives one tier
  # out — SHA256SUMS/the store sidecar), tree_hash is the zero placeholder
  # until the CAS lands (the openjdk-feedstock precedent).
  class ImageManifest
    # In-image location the driver reads (tpkg::PAYLOAD_MANIFEST_PATH).
    PATH = File.join("__tpkg__", "manifest.yaml").freeze

    # The materialize declaration, msys only (the class doc): the in-image
    # absolute spelling of CaBundle's deploy target.
    MATERIALIZE = ["/#{CaBundle::IN_IMAGE_PATH}"].freeze

    def initialize(platform:, ruby_version:, tebako_version:, patch_set:, src_sha256:)
      @platform = platform
      @ruby_version = ruby_version
      @tebako_version = tebako_version
      @patch_set = patch_set
      @src_sha256 = src_sha256
    end

    # Write the manifest into the assembled layout tree (before the image
    # is packed); returns the written path.
    def deploy(tree_root)
      path = File.join(tree_root, PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(to_h))
      path
    end

    def to_h
      manifest = {
        "schema_version" => 1,
        "identity" => identity,
        "provides" => provides
      }
      if @platform.msys?
        manifest["materialize"] = MATERIALIZE.dup
        # The toolchain support-DLL set (spec 22 §2.1's alias channel):
        # declared from the single owner (SupportDlls) — the deploy pass
        # stages exactly these names into /bin or dies by name, so the
        # declaration is truthful by construction.
        manifest["library_aliases"] = TebakoRuntimeBuilder::SupportDlls.alias_declarations
      end
      manifest
    end

    private

    def identity # rubocop:disable Metrics/MethodLength -- one declarative block per spec 03 §2.1; splitting it scatters the grammar
      {
        "schema_version" => 1,
        # The spec-18 contract field: this image is an era-2 artifact (the
        # same declaration lib/tebako/layout.yaml carries on the C3 edge).
        "era" => 2,
        "kind" => "runtime",
        "name" => "tebako-runtime-ruby",
        "version" => @tebako_version,
        "producer" => { "tool" => "tebako-runtime-ruby", "tool_version" => @tebako_version },
        "created" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source" => { "src_sha256" => @src_sha256 },
        "digest" => {
          "tree_hash" => "sha256:#{"0" * 64}",
          "blob_sha256" => "0" * 64
        },
        "signing" => { "state" => "unsigned" },
        "encryption" => { "state" => "none" }
      }
    end

    # kind=runtime PROVIDES (spec 03 §2.2): the engine line the dispatcher
    # matches runtime_requirements against, the source provenance, and the
    # locked runtime capability triple. abi_line is the ruby major.minor
    # (the "~> x.y.z" line native-extension payloads pin).
    def provides # rubocop:disable Metrics/MethodLength -- one declarative block per spec 03 §2.2; splitting it scatters the grammar
      ruby = TebakoRuntimeBuilder::RubyVersion.new(@ruby_version)
      {
        "provides" => {
          "engine" => "ruby",
          "version" => @ruby_version,
          "abi_line" => ruby.major_minor.join("."),
          "platform" => @platform.tpkg_triplet
        },
        "built_from" => { "src_sha256" => @src_sha256, "patch_set" => @patch_set },
        "capabilities" => { "exec" => true, "read" => true, "runtime" => true }
      }
    end
  end
end
