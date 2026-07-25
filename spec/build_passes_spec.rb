# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"

RSpec.describe TebakoRuntimeBuilder::BuildPasses do
  let(:root) { Dir.mktmpdir }
  let(:ruby_src) { File.join(root, "src") }
  let(:deps_lib_dir) { File.join(root, "deps", "lib") }

  before do
    FileUtils.mkdir_p(File.join(ruby_src, "template"))
    FileUtils.mkdir_p(deps_lib_dir)
  end

  after do
    FileUtils.remove_entry(root)
  end

  describe ".prepare" do
    before do
      File.write(File.join(ruby_src, "template", "Makefile.in"),
                 "SOLIBS = @SOLIBS@\nMAINLIBS = @TEBAKO_MLIBS@\nARCHMINIOBJS = @MINIOBJS@\n")
    end

    it "substitutes @TEBAKO_MLIBS@ and builds the toolchain stub library" do
      described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tebako_memfs__", "cc")

      makefile_in = File.read(File.join(ruby_src, "template", "Makefile.in"))
      expect(makefile_in).not_to include("@TEBAKO_MLIBS@")
      expect(makefile_in).to include("MAINLIBS = -Wl,--start-group -Wl,--push-state,--whole-archive -l:libtebako-fs.a")

      stub = File.join(deps_lib_dir, "libtebako-fs.a")
      expect(File.file?(stub)).to be(true)
      symbols, = Open3.capture2e("nm", "-g", stub)
      %w[_tebako_main _tebako_mount_point _tebako_is_running_miniruby _tebako_original_pwd].each do |symbol|
        expect(symbols).to include(symbol)
      end
    end

    it "fails loudly when the placeholder is absent (not a pre-patched tree)" do
      File.write(File.join(ruby_src, "template", "Makefile.in"), "MAINLIBS = @MAINLIBS@\n")
      expect { described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tebako_memfs__", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /not a tebako pre-patched ruby source tree/)
    end

    it "is idempotent across rebuild re-runs (substitutes from the .tebako-orig copy)" do
      described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tebako_memfs__", "cc")
      expect do
        described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tebako_memfs__", "cc")
      end.not_to raise_error
      makefile_in = File.read(File.join(ruby_src, "template", "Makefile.in"))
      expect(makefile_in).to include("MAINLIBS = -Wl,--start-group")
    end

    it "fails when template/Makefile.in does not exist" do
      FileUtils.rm(File.join(ruby_src, "template", "Makefile.in"))
      expect { described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tebako_memfs__", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not exist/)
    end

    it "skips the template substitution on msys (MAINLIBS comes via config.status there)" do
      File.write(File.join(ruby_src, "template", "Makefile.in"), "MAINLIBS = @MAINLIBS@\n")
      expect do
        described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/__tebako_memfs__", "cc")
      end.not_to raise_error
      expect(File.read(File.join(ruby_src, "template", "Makefile.in"))).to eq("MAINLIBS = @MAINLIBS@\n")
      expect(File.file?(File.join(deps_lib_dir, "libtebako-fs.a"))).to be(true)
    end
  end

  describe ".postconfigure" do
    let(:config_status) { File.join(ruby_src, "config.status") }

    it "substitutes the linux MAINLIBS line for ruby 3.3+" do
      File.write(config_status,
                 "S[\"COMMON_LIBS\"]=\"\"\n" \
                 "S[\"MAINLIBS\"]=\"-lz -lrt -lrt -ldl -lcrypt -lm -lpthread \"\n" \
                 "S[\"ENABLE_SHARED\"]=\"no\"\n")
      described_class.postconfigure("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7")
      contents = File.read(config_status)
      expect(contents).to include("S[\"MAINLIBS\"]=\"-Wl,--start-group")
      expect(contents).not_to include("-lz -lrt -lrt -ldl -lcrypt -lm -lpthread")
    end

    it "substitutes the darwin MAINLIBS line" do
      File.write(config_status, "S[\"MAINLIBS\"]=\"-ldl -lobjc -lpthread \"\n")
      described_class.postconfigure("arm64-darwin23", ruby_src, deps_lib_dir, "3.3.7")
      expect(File.read(config_status)).to include("S[\"MAINLIBS\"]=\"-ltebako-fs ")
    end

    it "is a no-op for ruby < 3.3 off msys" do
      original = "S[\"MAINLIBS\"]=\"-lz -lrt -lrt -ldl -lcrypt -lm -lpthread \"\n"
      File.write(config_status, original)
      described_class.postconfigure("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.2.7")
      expect(File.read(config_status)).to eq(original)
    end

    it "warns instead of raising when no pattern matches" do
      File.write(config_status, "S[\"MAINLIBS\"]=\"unexpected\"\n")
      expect do
        described_class.postconfigure("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7")
      end.to output(/Warning: no config.status MAINLIBS pattern matched/).to_stdout
    end
  end

  describe ".overlay" do
    let(:pass2_dir) { File.join(root, "pass2-tree", "tfs-ruby-3.3.7-src") }
    let(:work_dir) { File.join(root, "work") }
    let(:tarball) { File.join(root, "tfs-ruby-3.3.7-src-msys-pass2.tar.gz") }

    before do
      FileUtils.mkdir_p(File.join(pass2_dir, "cygwin"))
      File.write(File.join(pass2_dir, "cygwin", "GNUmakefile.in"), "pass2 variant\n")
      File.write(File.join(pass2_dir, "main.c"), "same content\n")

      # the built pass-1 tree: one differing file, one identical file, one
      # build artifact the overlay must preserve
      FileUtils.mkdir_p(File.join(ruby_src, "cygwin"))
      File.write(File.join(ruby_src, "cygwin", "GNUmakefile.in"), "pass1 variant\n")
      File.write(File.join(ruby_src, "main.c"), "same content\n")
      File.write(File.join(ruby_src, "tebako.def"), "EXPORTS\n  ruby_api\n")
      File.write(File.join(ruby_src, "ruby.obj"), "object-bytes")

      Dir.chdir(root) do
        system("tar -czf #{tarball} -C pass2-tree tfs-ruby-3.3.7-src") || raise("tar failed")
      end
    end

    it "replaces only content-differing files and preserves build artifacts" do
      same_mtime = File.mtime(File.join(ruby_src, "main.c"))
      sleep 0.05
      described_class.overlay(tarball, Digest::SHA256.file(tarball).hexdigest, ruby_src, work_dir)

      expect(File.read(File.join(ruby_src, "cygwin", "GNUmakefile.in"))).to eq("pass2 variant\n")
      expect(File.mtime(File.join(ruby_src, "main.c"))).to eq(same_mtime)
      expect(File.file?(File.join(ruby_src, "tebako.def"))).to be(true)
      expect(File.binread(File.join(ruby_src, "ruby.obj"))).to eq("object-bytes")
    end

    it "rejects a tarball whose sha256 does not match" do
      expect { described_class.overlay(tarball, "0" * 64, ruby_src, work_dir) }
        .to raise_error(TebakoRuntimeBuilder::Error, /expected SHA256/)
    end
  end
end
