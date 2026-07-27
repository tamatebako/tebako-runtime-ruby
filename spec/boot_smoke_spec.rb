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
      artifact = described_class::Artifact.new("tebako-runtime-0.15.9-3.3.7-windows-x86_64.exe")
      expect(artifact.platform_id).to eq("windows-x86_64")
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
        expect(run.state("stat")).to eq("ok")
        expect(run.state("lstat")).to eq("ok")
      end

      it "fstats an open memfs file" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("fstat")).to eq("ok")
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

      it "resolves a default gem through $LOAD_PATH" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("load_path_default_gem")).to eq("ok")
        expect(run.detail("load_path_default_gem")).not_to be_empty
      end
    end

    describe "bundler" do
      let(:run) { smoke.run("bundler") }

      it "defines the gem home inside the memfs" do
        # Regression for the image-era Gem.home gap: Gem.home (rubygems
        # < 3.5) resp. its successor Gem.dir must resolve into the image.
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("gem_home")).to eq("ok")
        expect(run.detail("gem_home")).to start_with(smoke.mount_point)
      end

      it "requires bundler" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("require_bundler")).to eq("ok")
        expect(run.detail("require_bundler")).to match(/\A\d+\.\d+\.\d+\z/)
      end

      it "loads default gems" do
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("default_gems_load")).to eq("ok")
      end
    end

    describe "locks" do
      let(:run) { smoke.run("locks") }

      it "flocks a writable path (fcntl/POSIX semantics)" do
        # On msys the flock shim lands as a no-op with item 18; pend until
        # then (a pass here flips the pending and frees the marker).
        pending "msys flock lands as a shim no-op with item 18" if smoke.platform.msys?
        expect(run).to be_booted, boot_failure(run)
        expect(run.state("flock_writable")).to eq("ok")
      end
    end
  end
end
