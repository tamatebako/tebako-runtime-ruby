# frozen_string_literal: true

require "spec_helper"

# Runtime boot-smoke class (roadmap item 19): boots ONE built runtime
# executable per example and asserts the memfs syscall surface from inside
# the packaged context -- the statx/fcntl/flock drift class, caught per
# runtime at build time, before tebako-rs users boot the package.
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

    it "ignores the sidecar markers (abi facet + era-2 contract card + sha256/origin trust markers)" do
      Dir.mktmpdir do |dir|
        exe = File.join(dir, "tebako-runtime-0.15.9-3.1.6-windows-ucrt64")
        FileUtils.touch(exe)
        FileUtils.touch("#{exe}.tfs")
        FileUtils.touch("#{exe}.abi")
        FileUtils.touch("#{exe}.contract.yaml")
        FileUtils.touch("#{exe}.sha256")
        FileUtils.touch("#{exe}.origin")
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

    describe "boot" do
      let(:run) { smoke.run("boot") }

      it "boots ruby and prints the expected RUBY_VERSION" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("ruby_version")).to eq("ok")
        expect(run.detail("ruby_version")).to eq(artifact.ruby_version)
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

      it "resolves a default gem through $LOAD_PATH" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("load_path_default_gem")).to eq("ok")
        expect(run.detail("load_path_default_gem")).not_to be_empty
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
  end
end
