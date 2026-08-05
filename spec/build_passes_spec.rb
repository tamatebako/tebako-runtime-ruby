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

  # An msys ruby source tree fixture carrying the anchors the prepare
  # hot-patches act on (dir.c: the glob hint; io.c: the fd_is_text block —
  # the stat wire-layout hot-patch is gone: the released source carries
  # the pinned tebako_stat ABI from tamatebako/ruby v0.2.13), plus the
  # shared-build set (issue 40): the mkexports rule in cygwin/GNUmakefile.in
  # and the miniruby dependency line in common.mk.
  def write_msys_source_fixtures(dir)
    glob = TebakoRuntimeBuilder::BuildPasses::MSYS_GLOB_OPENDIR_ANCHOR
    fd_text = TebakoRuntimeBuilder::BuildPasses::MSYS_FD_IS_TEXT_ANCHOR
    File.write(File.join(dir, "dir.c"), "#{glob}\n")
    File.write(File.join(dir, "io.c"), "tfs_close\n#{fd_text}\n")
    FileUtils.mkdir_p(File.join(dir, "cygwin"))
    File.write(File.join(dir, "cygwin", "GNUmakefile.in"),
               "rule-a\n#{TebakoRuntimeBuilder::BuildPasses::MSYS_DLL_EXPORTS_ANCHOR}rule-b\n")
    File.write(File.join(dir, "common.mk"),
               "line-a\n#{TebakoRuntimeBuilder::BuildPasses::MSYS_MINIRUBY_DEP_ANCHOR}line-b\n")
  end

  # A libtfs.a the DLL export fragment derives from (issue 40): one defined
  # tebako_* function, one data symbol (nm runs for real, as on the legs).
  def write_libtfs_fixture(dir)
    FileUtils.mkdir_p(dir)
    src = File.join(dir, "fixture.c")
    obj = File.join(dir, "fixture.o")
    File.write(src, "int tebako_fs_mount(void) { return 0; }\nint tebako_fs_state;\n")
    TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["cc", "-c", src, "-o", obj])
    TebakoRuntimeBuilder::BuildHelpers.run_with_capture(["ar", "rcs", File.join(dir, "libtfs.a"), obj])
  end

  describe ".prepare" do
    before do
      File.write(File.join(ruby_src, "template", "Makefile.in"),
                 "SOLIBS = @SOLIBS@\nMAINLIBS = @TEBAKO_MLIBS@\nARCHMINIOBJS = @MINIOBJS@\n")
    end

    it "substitutes @TEBAKO_MLIBS@ and builds the toolchain stub library" do
      described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tfs__", "cc")

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
      expect { described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tfs__", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /not a tebako pre-patched ruby source tree/)
    end

    it "is idempotent across rebuild re-runs (substitutes from the .tebako-orig copy)" do
      described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tfs__", "cc")
      expect do
        described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tfs__", "cc")
      end.not_to raise_error
      makefile_in = File.read(File.join(ruby_src, "template", "Makefile.in"))
      expect(makefile_in).to include("MAINLIBS = -Wl,--start-group")
    end

    it "fails when template/Makefile.in does not exist" do
      FileUtils.rm(File.join(ruby_src, "template", "Makefile.in"))
      expect { described_class.prepare("x86_64-linux-gnu", ruby_src, deps_lib_dir, "3.3.7", "/__tfs__", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not exist/)
    end

    it "skips the template substitution on msys (MAINLIBS comes via config.status there)" do
      File.write(File.join(ruby_src, "template", "Makefile.in"), "MAINLIBS = @MAINLIBS@\n")
      write_msys_source_fixtures(ruby_src)
      write_libtfs_fixture(deps_lib_dir)
      expect do
        described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc")
      end.not_to raise_error
      expect(File.read(File.join(ruby_src, "template", "Makefile.in"))).to eq("MAINLIBS = @MAINLIBS@\n")
      expect(File.file?(File.join(deps_lib_dir, "libtebako-fs.a"))).to be(true)
    end
  end

  describe ".prepare msys shared build (issue 40)" do
    before do
      write_msys_source_fixtures(ruby_src)
      write_libtfs_fixture(deps_lib_dir)
      described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc")
    end

    it "writes the DLL export fragment from the libtfs archive (functions bare, data marked)" do
      fragment = File.read(File.join(ruby_src, "tebako-dll-exports.def"))
      expect(fragment).to include("tebako_fs_mount\n")
      expect(fragment).to include("tebako_fs_state DATA\n")
    end

    it "appends the fragment to the mkexports rule in cygwin/GNUmakefile.in" do
      gnu_makefile_in = File.read(File.join(ruby_src, "cygwin", "GNUmakefile.in"))
      expect(gnu_makefile_in).to include("cat tebako-dll-exports.def >> $@ # tebako patched (issue 40)")
    end

    it "makes miniruby depend on the DLL import library in common.mk" do
      common_mk = File.read(File.join(ruby_src, "common.mk"))
      expect(common_mk).to include("$(ALLOBJS) $(ARCHFILE) $(LIBRUBY) # tebako patched (issue 40)")
    end

    it "anchors the ruby 4.0 spelled-out miniruby line too" do
      File.write(File.join(ruby_src, "common.mk"),
                 "miniruby$(EXEEXT): config.status $(NORMALMAINOBJ) $(MINIOBJS) $(COMMONOBJS) $(ARCHFILE)\n")
      described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "4.0.6", "A:/t", "cc")
      common_mk = File.read(File.join(ruby_src, "common.mk"))
      expect(common_mk).to include("$(COMMONOBJS) $(ARCHFILE) $(LIBRUBY) # tebako patched (issue 40)")
    end

    it "is idempotent across the msys pass-2 overlay prepare re-run" do
      expect do
        described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc")
      end.not_to raise_error
      gnu_makefile_in = File.read(File.join(ruby_src, "cygwin", "GNUmakefile.in"))
      expect(gnu_makefile_in.scan("tebako-dll-exports.def").length).to eq(1)
      common_mk = File.read(File.join(ruby_src, "common.mk"))
      expect(common_mk.scan("$(LIBRUBY)").length).to eq(1)
    end

    it "fails loudly when the mkexports anchor drifted" do
      File.write(File.join(ruby_src, "cygwin", "GNUmakefile.in"), "no mkexports rule here\n")
      expect { described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /mkexports rule anchor/)
    end

    it "fails loudly when the libtfs archive defines no tebako_* symbols" do
      FileUtils.rm(File.join(deps_lib_dir, "libtfs.a"))
      expect { described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /no libtfs.a to derive the DLL export fragment/)
    end
  end

  describe ".prepare msys dir.c glob_opendir guard" do
    let(:dir_c) { File.join(ruby_src, "dir.c") }
    let(:anchor) { "        if ((capacity = dirp->nfiles) > 0) {" }

    before do
      write_msys_source_fixtures(ruby_src)
      write_libtfs_fixture(deps_lib_dir)
    end

    it "guards the nfiles capacity hint against libtfs dir handles" do
      described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc")

      contents = File.read(dir_c)
      expect(contents).to include("!tebako_fs_dir_is_embedded((tebako_dir_t) dirp) /* tebako patch */ && " \
                                  "(capacity = dirp->nfiles) > 0")
      expect(contents.scan("dirp->nfiles").length).to eq(1)
    end

    it "is idempotent across the msys pass-2 overlay prepare re-run" do
      described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc")
      expect do
        described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc")
      end.not_to raise_error
      expect(File.read(dir_c).scan("dirp->nfiles").length).to eq(1)
    end

    it "fails loudly when the anchor is absent (the pre-patched tree changed)" do
      File.write(dir_c, "#ifdef _WIN32\n        if ((capacity = 16) > 0) {\n#endif\n")
      expect { described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /capacity-hint anchor/)
    end

    it "fails when dir.c does not exist" do
      FileUtils.rm(dir_c)
      expect { described_class.prepare("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7", "A:/t", "cc") }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not exist/)
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

    it "substitutes MAINLIBS (exe side) and SOLIBS (the DLL closure) on msys (issue 40)" do
      File.write(config_status,
                 "S[\"MAINLIBS\"]=\"#{described_class::MSYS_MAINLIBS_LINE}\"\n" \
                 "S[\"SOLIBS\"]=\"$(MAINLIBS)\"\n")
      described_class.postconfigure("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7")
      contents = File.read(config_status)
      # the exe side: driver + import library + system libs, never the closure
      expect(contents).to include("libx64-ucrt-ruby330.dll.a")
      expect(contents).not_to include("S[\"MAINLIBS\"]=\"#{described_class::MSYS_MAINLIBS_LINE}\"")
      # the DLL side: the closure replaces the $(MAINLIBS) reference
      expect(contents).to include("S[\"SOLIBS\"]=\"-Wl,--start-group -l:libtfs.a")
      expect(contents).not_to include("S[\"SOLIBS\"]=\"$(MAINLIBS)\"")
    end

    it "is idempotent for the msys MAINLIBS+SOLIBS pair" do
      File.write(config_status,
                 "S[\"MAINLIBS\"]=\"#{described_class::MSYS_MAINLIBS_LINE} \"\n" \
                 "S[\"SOLIBS\"]=\"$(MAINLIBS)\"\n")
      described_class.postconfigure("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7")
      expect do
        described_class.postconfigure("x64-mingw-ucrt", ruby_src, deps_lib_dir, "3.3.7")
      end.not_to output(/Warning/).to_stdout
    end
  end

  describe ".toolchain" do
    let(:data_src_dir) { File.join(root, "o", "s") }
    let(:stash_dir) { File.join(root, "deps", "stash") }

    before do
      # The rbconfig the pass rewrites (memfs prefix, as the pre-patched
      # mkconfig bakes it); make invocations are stubbed out
      File.write(File.join(ruby_src, "rbconfig.rb"),
                 %(  CONFIG["prefix"] = (TOPDIR || DESTDIR + "/__tfs__")\n) +
                   %(  CONFIG["RUBY_EXEC_PREFIX"] = "/__tfs__"\n))
      allow(TebakoRuntimeBuilder::BuildHelpers).to receive(:run_with_capture).and_return("")
    end

    it "cleans a reused packaging prefix before the install" do
      stale = File.join(data_src_dir, "lib", "ruby", "3.3.0", "stale-from-another-ruby.rb")
      FileUtils.mkdir_p(File.dirname(stale))
      File.write(stale, "stale")

      described_class.toolchain(ruby_src, data_src_dir, stash_dir, deps_lib_dir)

      expect(File.exist?(stale)).to be(false)
      expect(File.exist?(File.join(stash_dir, "lib", "ruby", "3.3.0", "stale-from-another-ruby.rb"))).to be(false)
      expect(TebakoRuntimeBuilder::BuildHelpers).to have_received(:run_with_capture)
        .with(["make", "install", "-j1", "DESTDIR="])
    end

    it "stashes exactly what the install left in the prefix" do
      FileUtils.mkdir_p(data_src_dir)

      described_class.toolchain(ruby_src, data_src_dir, stash_dir, deps_lib_dir)

      rewritten = File.read(File.join(ruby_src, "rbconfig.rb"))
      expect(rewritten).to include("DESTDIR + \"#{data_src_dir}\"")
      expect(File.directory?(stash_dir)).to be(true)
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
