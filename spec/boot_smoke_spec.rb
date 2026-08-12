# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Runtime boot-smoke class (roadmap item 19): boots ONE built runtime
# executable per example and asserts the memfs syscall surface from inside
# the packaged context -- the statx/fcntl/flock drift class, caught per
# runtime at build time, before tebako-rs users boot the package.
#
# The boot is the spec-17 smoke form (spec 17 §1: "With images but NO
# --tebako-entry at all, the boot mounts and starts the interpreter with
# its own args"): TEBAKO_RUNTIME_IMAGE names the leg's own .tfs and the
# probe preloaded through RUBYOPT executes inside the packaged context.
# Beyond the syscall surface the class gates the upload on:
#   * code execution FROM the mount (the default-gem require resolves
#     inside the memfs -- "boots + runs ruby from the image"),
#   * the openssl native-extension canary (issue #40; each leg records
#     its expectation as TEBAKO_SMOKE_EXPECT_OPENSSL in
#     _build-platform.yml and the class fails on any drift, either way),
#   * the deploy-direction IO.copy_stream (the io.c zero-copy EBADF
#     class -- only a real run exposes it),
#   * the era-2 release card next to the package plus the driver's
#     compiled-in contract version export, pinned against contract.yml
#     (the manifest entry's contract fields, validated BEFORE upload --
#     the corrupt-manifest incident class).
#
# Point TEBAKO_RUNTIME_ROOT at a runtime root (a directory holding exactly
# one tebako-runtime-* executable, e.g. a build leg's runtime-packages/, or
# the executable path itself) and run:
#   bundle exec rspec --tag boot_smoke
# Without the variable the integration examples skip in a plain run and
# fail loudly when the class is targeted explicitly. CI runs the tag per
# freshly built runtime before the artifact upload.
RSpec.describe TebakoRuntimeBuilder::BootSmoke, :boot_smoke do
  describe "artifact resolution" do
    it "parses the runtime artifact name" do
      artifact = described_class::Artifact.new("tebako-runtime-0.15.9-3.3.7-linux-gnu-x86_64")
      expect(artifact.tebako_version).to eq("0.15.9")
      expect(artifact.ruby_version).to eq("3.3.7")
      expect(artifact.platform_id).to eq("linux-gnu-x86_64")
      expect(artifact.ruby_major).to eq(3)
    end

    it "parses a windows .exe artifact name" do
      artifact = described_class::Artifact.new("tebako-runtime-0.15.9-3.3.7-windows-ucrt64.exe")
      expect(artifact.platform_id).to eq("windows-ucrt64")
    end

    it "rejects a name that is not a runtime artifact" do
      expect { described_class::Artifact.new("tfs-ruby-3.3.7-src.tar.gz") }
        .to raise_error(TebakoRuntimeBuilder::Error, /not a tebako runtime artifact name/)
    end

    it "resolves the single runtime executable in a directory, ignoring images" do
      Dir.mktmpdir do |dir|
        exe = File.join(dir, "tebako-runtime-0.15.9-3.3.7-macos-arm64")
        FileUtils.touch(exe)
        FileUtils.touch("#{exe}.tfs")
        expect(described_class.new(dir).executable).to eq(exe)
      end
    end

    it "ignores the sidecar markers (abi facet, era-2 contract card, trust markers, the package-named ruby DLL)" do
      Dir.mktmpdir do |dir|
        exe = File.join(dir, "tebako-runtime-0.15.9-3.1.6-windows-ucrt64")
        FileUtils.touch(exe)
        FileUtils.touch("#{exe}.tfs")
        FileUtils.touch("#{exe}.abi")
        FileUtils.touch("#{exe}.contract.yaml")
        FileUtils.touch("#{exe}.sha256")
        FileUtils.touch("#{exe}.origin")
        FileUtils.touch("#{exe}.dll")
        expect(described_class.new(dir).executable).to eq(exe)
      end
    end

    it "fails loudly when the root holds no runtime executable" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(dir).executable }
          .to raise_error(TebakoRuntimeBuilder::Error, /no tebako runtime executable/)
      end
    end

    it "fails loudly when the root holds several runtime executables" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "tebako-runtime-0.15.9-3.3.7-macos-arm64"))
        FileUtils.touch(File.join(dir, "tebako-runtime-0.15.9-4.0.6-macos-arm64"))
        expect { described_class.new(dir).executable }
          .to raise_error(TebakoRuntimeBuilder::Error, /several runtime executables/)
      end
    end
  end

  describe TebakoRuntimeBuilder::BootSmoke::InterposeFixture do
    def with_env(vars)
      old = vars.to_h { |key, _| [key, ENV.fetch(key, nil)] }
      vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    it "names every tried path when no stashed ruby headers resolve" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          with_env("TEBAKO_SMOKE_RUBY_HEADERS" => nil) do
            # a POSIX platform pin: the header-resolution naming is the
            # behavior under test, and on an msys host the leg's own
            # platform is refused by the phase-1 POSIX gate first
            fixture = described_class.new(platform: TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu"))
            expect { fixture.image }.to raise_error(TebakoRuntimeBuilder::Error, /no stashed ruby headers.*tried:/m)
          end
        end
      end
    end

    it "honors an explicit TEBAKO_SMOKE_RUBY_HEADERS miss with the same named error" do
      Dir.mktmpdir do |dir|
        with_env("TEBAKO_SMOKE_RUBY_HEADERS" => dir) do
          fixture = described_class.new(platform: TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu"))
          expect { fixture.image }.to raise_error(TebakoRuntimeBuilder::Error, /no stashed ruby headers/)
        end
      end
    end

    it "refuses the windows leg by name in phase 1" do
      fixture = described_class.new(platform: TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt"))
      expect { fixture.image }.to raise_error(TebakoRuntimeBuilder::Error, /POSIX-only in spec 22 phase 1/)
    end
  end

  describe "against a built runtime" do
    def boot_failure(run)
      "expected the runtime to boot and report -- #{run.failure_summary}"
    end

    before do
      next if ENV.fetch("TEBAKO_RUNTIME_ROOT", nil).to_s != ""

      message = "TEBAKO_RUNTIME_ROOT is not set -- point it at a runtime root " \
                "(a directory holding one tebako-runtime-* executable, or the executable itself)"
      skip(message) unless RSpec.configuration.inclusion_filter.rules.key?(:boot_smoke)

      raise(TebakoRuntimeBuilder::Error.new(message, 144))
    end

    let(:smoke) { described_class.new }
    let(:artifact) { smoke.artifact }

    # contract.yml at the repo root is the release pipeline's source of
    # truth for the contract_version every manifest entry emits
    # (scripts/upload_release.rb); the exe's compiled-in export must agree.
    def contract_yml_version
      YAML.load_file(File.join(REPO_ROOT, "contract.yml")).fetch("contract_version")
    end

    describe "boot" do
      let(:run) { smoke.run("boot") }

      it "boots ruby and prints the expected RUBY_VERSION" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("ruby_version")).to eq("ok")
        expect(run.detail("ruby_version")).to eq(artifact.ruby_version)
      end

      it "exports the compiled-in contract version, matching contract.yml (roadmap 45)" do
        # The manifest entry emits contract.yml's contract_version; the
        # fs-TU's tebako_main shim exports the linked driver's compiled-in
        # constant into the runtime's environment at boot. Pinning the two
        # here closes the stale-link-unit hole the compute job's
        # source-level check cannot see: a cached link unit carrying an
        # older driver would ship a manifest that mis-declares the
        # contract the binary speaks.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("contract_version")).to eq("ok"),
                                                 "probe contract_version detail: #{run.detail("contract_version")}"
        expect(run.detail("contract_version")).to eq(contract_yml_version.to_s)
      end
    end

    describe "the TEBAKO_MOUNT_ROOT override (spec 17 §1)" do
      # The full chain end-to-end: the driver mounts the env image at the
      # override, the layout's mount_root_override grant permits it, and
      # rbconfig's ENV fallback puts the interpreter's load paths under
      # the override root. POSIX legs: the windows drive-form override
      # rides the same code path; its leg proof rides with the windows
      # catalog campaign (the msys smoke covers the A:/t default).
      let(:run) { smoke.run("io", mount_root_override: "/rt-override") }

      it "mounts the env image at the override and the interpreter follows" do
        skip "the drive-form override proof rides with the windows catalog campaign" if smoke.platform.msys?

        expect(run).to be_booted, boot_failure(run)
        expect(run.state("load_path_default_gem")).to eq("ok")
        expect(run.detail("load_path_default_gem")).to start_with("/rt-override")
      end
    end

    describe "stat family" do
      let(:run) { smoke.run("stat") }

      it "stats and lstats a memfs path" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("stat")).to eq("ok"), "probe stat detail: #{run.detail("stat")}"
        expect(run.state("lstat")).to eq("ok"), "probe lstat detail: #{run.detail("lstat")}"
      end

      it "fstats an open memfs file" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("fstat")).to eq("ok"), "probe fstat detail: #{run.detail("fstat")}"
        expect(run.detail("fstat")).to match(/size=[1-9]\d*\z/)
      end

      it "exercises the birthtime/btime path" do
        # The ruby-4.0-linux statx case (tamatebako/ruby 4a04a8a): btime
        # either resolves or comes back unsupported -- never a syscall
        # error. ruby < 4.0 on linux routes File.birthtime through an
        # unshimmed statx(2) on the memfs path (ENOENT); whether that
        # surfaces depends on the build host's statx fallback, so treat
        # the syscall-error shape as a skip (never a hard pend: a pass
        # flips pending into a failure). Any "fail" on >= 4.0 is a real
        # regression (tfs_statx covers it).
        expect(run).to be_booted, boot_failure(run)
        state = run.state("birthtime")
        if state == "fail" && smoke.platform.linux? && artifact.ruby_major < 4
          skip "ruby #{artifact.ruby_version} linux routes File.birthtime " \
               "through an unshimmed statx(2) (ENOENT) — shim coverage starts at 4.0"
        end
        expect(%w[ok unsupported]).to include(state)
      end

      it "answers File.exist? on present and missing memfs paths" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("exist")).to eq("ok")
      end

      it "answers File.readable? and iterates a memfs directory" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("readable")).to eq("ok")
        expect(run.state("dir_iteration")).to eq("ok")
      end
    end

    describe "IO" do
      let(:run) { smoke.run("io") }

      it "reads a file from the runtime image" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("read_image_file")).to eq("ok")
        expect(run.detail("read_image_file")).to eq("#!/usr/bin/env ruby")
      end

      it "reads stdlib files from the image byte-exactly" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("read_stdlib_files")).to eq("ok"),
                                                  "probe read_stdlib_files detail: #{run.detail("read_stdlib_files")}"
      end

      it "executes a default gem's code from the mount through $LOAD_PATH" do
        # The spec-17 smoke form's point: not just that the interpreter
        # starts, but that it runs code OUT OF THE IMAGE -- the resolved
        # feature path must live under the mount point, never on the host.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("load_path_default_gem")).to eq("ok")
        expect(run.detail("load_path_default_gem")).to start_with(smoke.mount_point)
      end

      it "copies a file out of the image byte-exactly (the deploy direction)" do
        # IO.copy_stream from a memfs fd to a host file is the deploy
        # path: ruby's io.c zero-copy syscall (copy_file_range/fcopyfile)
        # must degrade to read/write on the memfs fd. The unguarded EBADF
        # is invisible to every static check -- only this real run exposes
        # it (the 0.16.2 deploy incident; guarded in tamatebako/ruby
        # v0.2.15). A "fail" here is a broken runtime: the upload must
        # not happen.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("copy_stream")).to eq("ok"),
                                            "probe copy_stream detail: #{run.detail("copy_stream")}"
      end

      it "declares the era-2 image layout at /lib/tebako/layout.yaml (spec 18 C3)" do
        # The env image's own declaration: the mount root the exe compiled
        # in (TEBAKO_BOOT_MOUNT_POINT is the same expectation host-side),
        # the era-2 contract set, and the interpreter api line — a pre-era
        # image or a mismatched exe↔image pair fails by name here, at
        # build time, ahead of the driver's exit-78 verdict.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("layout_yaml")).to eq("ok"), "probe layout_yaml detail: #{run.detail("layout_yaml")}"
      end
    end

    describe "bundler" do
      let(:run) { smoke.run("bundler") }

      it "defines the gem home inside the memfs" do
        # Regression for the image-era Gem.home gap: Gem.home (rubygems
        # < 3.5) resp. its successor Gem.dir must resolve into the image.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("gem_home")).to eq("ok"), "probe gem_home detail: #{run.detail("gem_home")}"
        expect(run.detail("gem_home")).to start_with(smoke.mount_point)
      end

      it "requires bundler" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("require_bundler")).to eq("ok"),
                                                "probe require_bundler detail: #{run.detail("require_bundler")}"
        expect(run.detail("require_bundler")).to match(/\A\d+\.\d+\.\d+\z/)
      end

      it "tolerates bundler's process lock on the read-only memfs" do
        # The boot gap's second half: ProcessLock targets the read-only
        # gem home; supported bundlers degrade to no-lock, the drifted
        # builds escaped with an unrescued EBADF.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("process_lock")).to eq("ok"), "probe process_lock detail: #{run.detail("process_lock")}"
      end

      it "loads default gems" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("default_gems_load")).to eq("ok"),
                                                  "probe default_gems_load detail: #{run.detail("default_gems_load")}"
      end
    end

    describe "locks" do
      let(:run) { smoke.run("locks") }

      it "flocks a writable path (fcntl/POSIX semantics)" do
        # The probe's writable path is a HOST temp file, so flock passes
        # through to the host CRT flock unchanged on every platform -- the
        # memfs no-op shim (item 18) covers memfs fds, which this check
        # never touches. (Introduced pending on msys before any msys leg
        # could boot; the first bootable msys runtime proved it stale.)
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("flock_writable")).to eq("ok"),
                                               "probe flock_writable detail: #{run.detail("flock_writable")}"
      end
    end

    describe "native extensions" do
      let(:run) { smoke.run("native_ext") }

      it "loads a dynamic native extension from the image (issue 40)" do
        # The windows runtime binds PE extensions against
        # x64-ucrt-ruby<ABI>.dll next to the exe (the store-entry shape):
        # racc's cparse.so extracts from the memfs and LoadLibrarys against
        # the DLL. Elsewhere the runtime's own exts are static and the
        # probe reports unsupported -- there is nothing to bind.
        expect(run).to be_booted, boot_failure(run)
        state = run.state("load_native_extension")
        if smoke.platform.msys?
          expect(state).to eq("ok"), "probe load_native_extension detail: #{run.detail("load_native_extension")}"
          expect(run.detail("load_native_extension")).to end_with("cparse.so")
        else
          expect(state).to eq("unsupported"),
                           "probe load_native_extension detail: #{run.detail("load_native_extension")}"
        end
      end
      it "loads openssl on every leg (it is statically linked into the runtime)" do
        # openssl is STATICALLY linked into the runtime, so require
        # "openssl" must load on EVERY leg before the artifacts leave it
        # (owner directive), windows included — a "fail" probe is a broken
        # runtime, always. Issue 40's dynamic-extension tripwire rides the
        # cparse.so check (load_native_extension), never openssl; this
        # canary exists to catch a regression that drops the static
        # openssl link.
        expect(run).to be_booted, boot_failure(run)
        state = run.state("require_openssl")
        expect(state).to eq(smoke.expected_openssl_state),
                         "openssl canary: the probe reports '#{state}' (#{run.detail("require_openssl")}) but this " \
                         "leg records '#{smoke.expected_openssl_state}' (TEBAKO_SMOKE_EXPECT_OPENSSL in " \
                         "_build-platform.yml). A POSIX leg reporting 'fail' is a broken runtime -- the upload " \
                         "must not happen. A windows leg flipping to 'ok' means the issue-#40 fix landed: flip " \
                         "the recorded value to 'ok' in the same PR to enforce it from then on."
      end
    end

    describe "the loader interposition (spec 22 phase 1, class L)" do
      # The per-gem ffi/fiddle adapters' deletion gate: a VFS-resident
      # native library must load through fiddle AND through a hand-rolled
      # C extension's own dlopen with no adapter involved, and a failed
      # materialization must surface the tebako verdict line. The probe
      # fixture (BootSmoke::InterposeFixture) builds a probe payload
      # image at boot-smoke time from the leg's own stashed headers and
      # mounts it at /probe for this scenario. POSIX-only in phase 1.
      let(:run) { smoke.run("loader_interpose") }

      it "loads a VFS-resident library through Fiddle.dlopen, closure included" do
        skip "the loader-interpose scenario is POSIX-only in spec 22 phase 1" if smoke.platform.msys?

        expect(run).to be_booted, boot_failure(run)
        expect(run.state("fiddle_vfs_dlopen")).to eq("ok"),
                                                  "probe fiddle_vfs_dlopen detail: #{run.detail("fiddle_vfs_dlopen")}"
        expect(run.detail("fiddle_vfs_dlopen")).to include("probe_answer=42")
      end

      it "a hand-rolled C extension self-dlopens the VFS library (no adapter can mask it)" do
        skip "the loader-interpose scenario is POSIX-only in spec 22 phase 1" if smoke.platform.msys?

        expect(run).to be_booted, boot_failure(run)
        expect(run.state("cext_self_dlopen")).to eq("ok"),
                                                 "probe cext_self_dlopen detail: #{run.detail("cext_self_dlopen")}"
        expect(run.detail("cext_self_dlopen")).to include("ProbeExt.answer=42")
      end

      it "a failed materialization raises through the dlerror channel (the verdict line post-adapter)" do
        skip "the loader-interpose scenario is POSIX-only in spec 22 phase 1" if smoke.platform.msys?

        expect(run).to be_booted, boot_failure(run)
        expect(run.state("named_error")).to eq("ok"),
                                            "probe named_error detail: #{run.detail("named_error")}"
      end
    end

    describe "the era-2 release card (spec 18 C2, gated pre-upload)" do
      # Host-side validation of the manifest entry's contract fields
      # BEFORE the artifacts leave the leg -- the 0.16.2 corrupt-manifest
      # incident class. The publish pipeline re-validates fail-closed
      # (scripts/upload_release.rb#contract_sidecar); catching it here
      # fails the ONE leg instead of the whole matrix at publish time.
      let(:card_path) { "#{smoke.executable.sub(/\.exe\z/, "")}.contract.yaml" }
      let(:card) { File.file?(card_path) ? YAML.load_file(card_path) : nil }

      it "ships the contract sidecar next to the package" do
        expect(File.file?(card_path)).to be(true),
                                         "missing #{card_path} -- a pre-era or corrupt build; the release pipeline " \
                                         "refuses it by name at publish time (spec 18 C2/S11), after the whole " \
                                         "matrix spent itself"
      end

      it "declares the era-2 contract set this factory speaks" do
        expect(card).to be_a(Hash), "contract sidecar #{card_path} is missing or not a mapping"
        card_era = TebakoRuntimeBuilder::Builder::CONTRACT_CARD.fetch("contract_era")
        image_layout = TebakoRuntimeBuilder::Builder::CONTRACT_CARD.fetch("image_layout")
        expect(card.fetch("contract_era", nil)).to eq(card_era)
        expect(card.fetch("image_layout", nil)).to eq(image_layout)
        %w[mount_root built_from].each do |key|
          expect(card[key]).not_to be_nil,
                                   "contract sidecar misses '#{key}' -- the manifest entry would ship under-declared"
        end
      end

      it "declares the mount root this platform's runtime compiled in" do
        # The manifest's mount_root flows from this card; the image's own
        # layout.yaml (the layout_yaml probe) and the driver's exit-78
        # pair-check pin the same value against the exe's compiled-in
        # root, so agreement here closes the triangle.
        expect(card).to be_a(Hash), "contract sidecar #{card_path} is missing or not a mapping"
        expect(card["mount_root"]).to eq(smoke.mount_point)
      end

      it "names the build provenance (built_from release + verified sources)" do
        expect(card).to be_a(Hash), "contract sidecar #{card_path} is missing or not a mapping"
        built_from = card["built_from"]
        expect(built_from).to be_a(Hash), "built_from is missing or not a mapping"
        expect(built_from["release"].to_s).not_to be_empty
        sources = built_from["sources"]
        expect(sources).to be_a(Array), "built_from.sources is missing or not an array"
        expect(sources).not_to be_empty
        sources.each do |source|
          expect(source["name"].to_s).not_to be_empty
          expect(source["sha256"].to_s).to match(/\A[0-9a-f]{64}\z/)
        end
      end
    end
  end
end
