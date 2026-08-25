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
require "timeout"
require "tmpdir"

module TebakoRuntimeBuilder
  # Runtime boot-smoke driver (roadmap item 19): boots ONE built runtime
  # executable per scenario and has the in-runtime probe
  # (boot_smoke/probe.rb, preloaded into the runtime through RUBYOPT -r so
  # every check runs inside the packaged memfs context) report the
  # syscall-surface facts the spec class asserts on. The class catches the
  # statx/fcntl/flock drift class at build time, per runtime, in seconds.
  #
  # The runtime root (ENV TEBAKO_RUNTIME_ROOT) is the directory holding
  # exactly one tebako-runtime-<tebako>-<ruby>-<platform> executable -- a
  # build leg's runtime-packages/, a tebako-home runtime cache dir -- or
  # the executable path itself. A bare layout tree or a mounted filesystem
  # image carries no interpreter, so it is never a valid root.
  class BootSmoke # rubocop:disable Metrics/ClassLength
    autoload :Artifact,         File.expand_path("boot_smoke/artifact", __dir__)
    autoload :Run,              File.expand_path("boot_smoke/run", __dir__)
    autoload :InterposeFixture, File.expand_path("boot_smoke/interpose_fixture", __dir__)

    SCENARIOS = %w[boot stat io bundler locks native_ext loader_interpose class_e_exec].freeze
    # The scenarios that boot with the spec-22 probe fixture image mounted
    # at /probe (class L's libraries + class E's jar ride the same image).
    INTERPOSE_SCENARIOS = %w[loader_interpose class_e_exec].freeze
    BOOT_TIMEOUT = 60
    IMAGE_SUFFIXES = %w[.tfs .dwarfs].freeze
    # Sidecar markers the artifact set carries next to the executable (the
    # factory's abi facet + era-2 contract card (.contract.yaml) + the
    # store-layout sha256/origin trust markers + the msys shared build's
    # <runtime>.dll, the ruby DLL under its unique package name): support
    # files, never the interpreter.
    MARKER_SUFFIXES = %w[.abi .sha256 .origin .yaml .dll].freeze
    # The materialized bundle's exec-cache spelling (spec 22 §6):
    # <temp>/tebako-exec-<key>/resources/<key>/ssl/cert.pem — the probe's
    # ca_roots detail prints the path (either separator) plus its size.
    MATERIALIZED_CERT_DETAIL =
      %r{tebako-exec-[0-9a-f]{16}[\\/]resources[\\/][0-9a-f]{16}[\\/]ssl[\\/]cert\.pem \(\d+ B\)\z}
    NON_EXECUTABLE_SUFFIXES = (IMAGE_SUFFIXES + MARKER_SUFFIXES).freeze
    # The child env is REPLACED, not inherited: RUBYOPT carries only the
    # probe and the rubygems/gem variables a host ruby setup would
    # otherwise leak in (the msys leg's gem_home resolved to the HOST
    # ucrt64 ruby's gem dir via an inherited GEM_HOME).
    ENV_SCRUBBED = %w[RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP].freeze
    PROBE_PATH = File.expand_path("boot_smoke/probe.rb", __dir__).freeze

    def initialize(runtime_root = ENV.fetch("TEBAKO_RUNTIME_ROOT", nil), platform: Platform.new)
      @runtime_root = runtime_root
      @platform = platform
    end

    attr_reader :platform

    # Absolute path of the single runtime executable under the root
    def executable
      @executable ||= resolve_executable
    end

    # Name model of the runtime artifact (tebako/ruby versions, platform id)
    def artifact
      @artifact ||= Artifact.new(File.basename(executable))
    end

    # The memfs mount point the runtime under test mounts at (host platform
    # == target platform: the executable must run on this host)
    def mount_point
      @platform.fs_mount_point
    end

    # The leg's recorded expectation for the openssl native-extension
    # canary: each boot-smoke step in _build-platform.yml records it per
    # leg as TEBAKO_SMOKE_EXPECT_OPENSSL. openssl is STATICALLY linked
    # into the runtime, so require "openssl" must load on EVERY leg,
    # windows included — a "fail" probe is a broken runtime, always.
    # (Issue 40's dynamic-extension tripwire rides the cparse.so check,
    # never openssl.) Unset defaults to "ok", the only correct state.
    def expected_openssl_state
      ENV.fetch("TEBAKO_SMOKE_EXPECT_OPENSSL", "ok")
    end

    # The leg's expected CA-roots story (0.16.6): the windows runtime's
    # boot shim points SSL_CERT_FILE at the driver's materialized HOST
    # copy of the in-image CA bundle (spec 22 §4 class R —
    # <temp>/tebako-exec-<key>/resources/<key>/ssl/cert.pem; the in-VFS
    # spelling of 0.16.5 could not reach libcrypto's native CRT IO), so
    # the probe's ca_roots detail names the exec-cache path; POSIX
    # runtimes leave it unset (the host's /etc/ssl serves — vcpkg's unix
    # openssl builds with --openssldir=/etc/ssl). Platform-derived, no
    # env plumbing. The windows regex also proves the image's
    # .sha256 sidecar rode along: without it the shim cannot compose the
    # materialized path and exports NOTHING (tebako#437 — the driver owns
    # the variable post-materialization), so the probe reports "unset",
    # which fails the regex just the same.
    def expected_ca_roots_detail
      @platform.msys? ? MATERIALIZED_CERT_DETAIL : "unset"
    end

    # Boot the runtime once with the named scenario preloaded; returns the
    # parsed Run model (never raises for a failed boot -- the model carries
    # the failure; a raise means the driver itself is miswired).
    # mount_root_override: boot with TEBAKO_MOUNT_ROOT set (spec 17 §1) —
    # the probe's expectation (TEBAKO_BOOT_MOUNT_POINT) follows it, so the
    # whole chain (driver mount + rbconfig fallback + layout grant) is
    # asserted end-to-end under the override root.
    # The INTERPOSE_SCENARIOS additionally mount the spec-22 probe fixture
    # image at /probe (the driver triple form; no --tebako-entry — the
    # smoke form still starts the interpreter with the RUBYOPT probe).
    def run(scenario, mount_root_override: nil)
      unless SCENARIOS.include?(scenario)
        raise TebakoRuntimeBuilder::Error.new(
          "unknown boot-smoke scenario '#{scenario}' (known: #{SCENARIOS.join(", ")})", 143
        )
      end

      materialize_ruby_dll
      extra_argv = INTERPOSE_SCENARIOS.include?(scenario) ? interpose_argv : []
      out, err, status = boot(scenario, mount_root_override: mount_root_override, extra_argv: extra_argv)
      Run.new(scenario: scenario, stdout: out, stderr: err, status: status)
    end

    private

    # The msys shared build (issue #40): the exe's PE imports resolve
    # x64-ucrt-ruby<ABI>.dll in the exe's own directory, but the package
    # dir holds the DLL under the unique package name (<runtime>.dll --
    # two same-ABI legs would collide on the PE name). Materialize the
    # PE-named copy next to the exe before booting, mirroring the store
    # entry the product's install assembles (exe + image + DLL under the
    # manifest's install_as name).
    def materialize_ruby_dll
      return unless @platform.msys?

      source = "#{executable.sub(/\.exe\z/, "")}.dll"
      return unless File.file?(source)

      dest = File.join(File.dirname(executable),
                       TebakoRuntimeBuilder::RubyVersion.new(artifact.ruby_version).msys_dll_name)
      FileUtils.cp(source, dest) unless File.file?(dest)
    end

    def resolve_executable
      root = @runtime_root.to_s
      if root.empty? || !File.exist?(root)
        raise TebakoRuntimeBuilder::Error.new(
          "TEBAKO_RUNTIME_ROOT (#{@runtime_root.inspect}) does not point at a runtime root: set it to a directory " \
          "holding one tebako-runtime-<tebako>-<ruby>-<platform> executable, or to the executable itself", 141
        )
      end
      return File.expand_path(root) if File.file?(root)

      resolve_in_directory(root)
    end

    def resolve_in_directory(dir)
      candidates = Dir.glob(File.join(dir, "tebako-runtime-*"))
                      .select { |path| File.file?(path) && !NON_EXECUTABLE_SUFFIXES.include?(File.extname(path)) }
      raise_no_executable!(dir) if candidates.empty?
      raise_several!(dir, candidates) if candidates.length > 1

      File.expand_path(candidates.first)
    end

    def raise_no_executable!(dir)
      raise TebakoRuntimeBuilder::Error.new(
        "no tebako runtime executable under #{dir}: the boot smoke boots the runtime EXECUTABLE " \
        "(a bare layout tree or a mounted filesystem image carries no interpreter)", 141
      )
    end

    def raise_several!(dir, candidates)
      names = candidates.map { |path| File.basename(path) }.join(", ")
      raise TebakoRuntimeBuilder::Error.new(
        "several runtime executables under #{dir} (#{names}): " \
        "point TEBAKO_RUNTIME_ROOT at a single-runtime root or at the executable itself", 141
      )
    end

    # The child env is REPLACED, not inherited: RUBYOPT carries only the
    # probe and the gem/bundler variables a `bundle exec` host would
    # otherwise leak in are scrubbed (the msys leg's gem_home resolved to
    # the HOST ucrt64 ruby's gem dir via an inherited GEM_HOME), so
    # require "bundler"/gem resolution inside the runtime resolve against
    # the image, never the host. The child also boots from an empty
    # scratch cwd: bundler's rubygems plugin otherwise auto-detects the
    # host checkout's Gemfile from the cwd and materializes the host
    # bundle inside the runtime.
    #
    # When the sibling <executable>.tfs exists the handoff mirrors the
    # image-era bootstrap exactly: TEBAKO_RUNTIME_IMAGE names it and the
    # driver mounts it (an image-era executable ships no embedded image and
    # would not boot otherwise; an item-30b embedded executable proves the
    # variable wins over its incbin image). A runtime root without the
    # image boots the v1 embedded way, byte-identical to before.
    # The spec-22 probe fixture mount triple (the image builds once per
    # process, off every other scenario's path).
    def interpose_argv
      ["--tebako-image", "#{InterposeFixture.new(platform: @platform).image}:-:#{InterposeFixture::MOUNT}"]
    end

    def boot(scenario, mount_root_override: nil, extra_argv: [])
      Dir.mktmpdir("tebako-boot-smoke") do |cwd|
        return Timeout.timeout(BOOT_TIMEOUT) do
          Open3.capture3(boot_env(scenario, mount_root_override: mount_root_override),
                         executable, *extra_argv, chdir: cwd)
        end
      end
    rescue Timeout::Error
      # The runtime child may outlive the killed wait; the boot is a hard
      # failure either way -- a hung runtime must not stall a CI leg.
      ["", "boot-smoke: runtime did not exit within #{BOOT_TIMEOUT}s", nil]
    end

    def boot_env(scenario, mount_root_override: nil)
      env = ENV_SCRUBBED.to_h { |key| [key, nil] }
      image = "#{executable}.tfs"
      env["TEBAKO_RUNTIME_IMAGE"] = image if File.file?(image)
      env["TEBAKO_MOUNT_ROOT"] = mount_root_override if mount_root_override
      # The support-DLL alias expectation (spec 22 §2.1, msys only): flowed
      # from the single owner (SupportDlls::NAMES), so the probe judges the
      # booted runtime against exactly the set this checkout stages and
      # declares. POSIX legs set nothing — the probe reports unsupported.
      names = TebakoRuntimeBuilder::SupportDlls::NAMES.join(",")
      env["TEBAKO_SMOKE_EXPECT_SUPPORT_DLLS"] = names if @platform.msys?
      env.merge("RUBYOPT" => "-r#{PROBE_PATH}",
                "TEBAKO_BOOT_PROBE" => scenario,
                "TEBAKO_BOOT_MOUNT_POINT" => mount_root_override || mount_point)
    end
  end
end
