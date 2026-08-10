# frozen_string_literal: true

require "spec_helper"

RSpec.describe TebakoRuntimeBuilder::Mlibs do
  let(:ruby_ver) { TebakoRuntimeBuilder::RubyVersion.new("3.3.7") }

  context "on linux-gnu" do
    subject(:mlibs) do
      described_class.new(TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu", "x86_64"), "/deps/lib")
    end

    it "computes the group-wrapped static library list" do
      expected = "-Wl,--start-group " \
                 "-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state " \
                 "-l:libtfs.a " \
                 "-l:libdwarfs_reader.a -l:libdwarfs_common.a -l:libdwarfs_metadata_legacy.a " \
                 "-l:libdwarfs_decompressor.a -l:libflatbuffers.a -l:libzip.a " \
                 "-l:libfmt.a -l:libxxhash.a -l:libboost_filesystem.a -l:libboost_chrono.a " \
                 "-l:liblz4.a -l:libz.a -l:libzstd.a " \
                 "-l:libbrotlienc.a -l:libbrotlidec.a -l:libbrotlicommon.a -l:liblzma.a -l:libbz2.a " \
                 "-Wl,--end-group " \
                 "-l:libacl.a -l:libssl.a -l:libcrypto.a " \
                 "-l:libgdbm.a -l:libreadline.a -l:libtinfo.a -l:libffi.a " \
                 "-l:libncurses.a -l:libjemalloc.a -l:libcrypt.a -l:libanl.a " \
                 "-l:libyaml.a -l:libutil.a " \
                 "-l:libstdc++.a -lgcc_eh -l:liblzma.a " \
                 "-l:librt.a -ldl -lpthread -lm"
      expect(mlibs.compute(ruby_ver)).to eq(expected)
    end

    it "substitutes an empty libyaml reference for ruby < 3.2" do
      rv31 = TebakoRuntimeBuilder::RubyVersion.new("3.1.6")
      expect(mlibs.compute(rv31)).to include("-l:libanl.a  -l:libutil.a")
    end
  end

  context "on linux-musl" do
    subject(:mlibs) do
      described_class.new(TebakoRuntimeBuilder::Platform.new("x86_64-linux-musl", "x86_64"), "/deps/lib")
    end

    it "uses the musl tail (no -lm, no libutil/libtinfo/libanl)" do
      result = mlibs.compute(ruby_ver)
      expect(result).to start_with("-Wl,--start-group -Wl,--push-state,--whole-archive")
      expect(result).to include("-l:libjemalloc.a -l:libcrypt.a -l:libyaml.a -l:librt.a")
      expect(result).to end_with("-l:liblzma.a -ldl -lpthread")
      expect(result).not_to include("-l:libutil.a")
    end
  end

  context "on linux-gnu with a staged rust link unit (the v2 link)" do
    subject(:mlibs) do
      described_class.new(TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu", "x86_64"), "/deps/lib")
    end

    let(:root) { Dir.mktmpdir }

    before do
      FileUtils.touch(File.join(root, "libtebako_driver.a"))
      FileUtils.touch(File.join(root, "libtfs.a"))
      FileUtils.mkdir_p(File.join(root, "closure"))
      FileUtils.touch(File.join(root, "closure", "libfmt.a"))
      @prev_libdir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)
      ENV["TEBAKO_RUST_LIBDIR"] = root
    end

    after do
      @prev_libdir.nil? ? ENV.delete("TEBAKO_RUST_LIBDIR") : ENV["TEBAKO_RUST_LIBDIR"] = @prev_libdir
      FileUtils.remove_entry(root)
    end

    it "group-wraps the scoped staticlibs + closure ahead of the platform tail" do
      result = mlibs.compute(ruby_ver)
      expect(result).to start_with(
        "-Wl,--start-group " \
        "-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state #{root}/libtebako_driver.a"
      )
      expect(result).to include("#{root}/closure/libfmt.a -Wl,--end-group -l:libacl.a")
    end

    it "appends -l:libz.a (ruby's zlib need — the gated dwarfs manifest ships no zlib)" do
      expect(mlibs.compute(ruby_ver)).to end_with("-l:libz.a")
    end

    it "dedupes the closure archives the platform set already covers (the pacman_covered class)" do
      FileUtils.touch(File.join(root, "closure", "libjemalloc.a"))
      FileUtils.touch(File.join(root, "closure", "libssl.a"))
      FileUtils.touch(File.join(root, "closure", "liblzma.a"))
      result = mlibs.compute(ruby_ver)
      expect(result).not_to include("closure/libjemalloc.a")
      expect(result).not_to include("closure/libssl.a")
      expect(result).not_to include("closure/liblzma.a")
      expect(result).to include("#{root}/closure/libfmt.a")
    end
  end

  context "on msys" do
    subject(:mlibs) do
      described_class.new(TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64"), "/deps/lib")
    end

    it "prepends -Wl,-Bstatic only with compression and group-wraps the fs TU + import lib" do
      expect(mlibs.compute(ruby_ver,
                           with_compression: true)).to start_with("-Wl,-Bstatic -Wl,--start-group -l:libtebako-fs.a")
      expect(mlibs.compute(ruby_ver, with_compression: false)).to start_with("-Wl,--start-group -l:libtebako-fs.a")
      expect(mlibs.compute(ruby_ver)).to include("-Wl,--end-group")
    end

    it "keeps the driver, the closure and the import-lib literal OUT of MAINLIBS (the exe side, issue 40)" do
      result = mlibs.compute(ruby_ver)
      expect(result).to include("-l:libtebako-fs.a")
      expect(result).not_to include("--whole-archive")
      expect(result).not_to include(".dll.a")
      expect(result).to include("-lws2_32")
      expect(result).to include("-lpsapi")
      expect(result).to include("-lntdll")
      expect(result).not_to include("-l:libtfs.a")
      expect(result).not_to include("-l:libbz2.a")
    end

    it "computes miniruby's FULL static set (driver + closure + system libs, issue 40)" do
      result = mlibs.compute_minilibs(ruby_ver)
      expect(result).to start_with("-Wl,--start-group -Wl,--push-state,--whole-archive -l:libtebako-fs.a")
      expect(result).to include("-l:libtfs.a")
      expect(result).to include("-l:libbz2.a")
      expect(result).to include("-lws2_32")
      expect(result).to include("-lntdll")
    end

    it "carries the closure and the windows system libs in SOLIBS (the DLL side, issue 40)" do
      result = mlibs.compute_solibs(ruby_ver)
      expect(result).to start_with("-Wl,--start-group -l:libtfs.a")
      expect(result).to include("-l:libbz2.a")
      expect(result).to include("-l:libz.a")
      expect(result).to include("-lshell32")
      expect(result).to include("-lntdll")
      expect(result).not_to include("libtebako-fs.a")
      # The DLL is self-contained on a bare windows machine: the fiddle /
      # dl / psych deps link STATICALLY. 0.16.3's DLL imported
      # libdl.dll / libffi-8.dll / libyaml-0-2.dll — present nowhere but
      # an msys2 install, so the runtime could not start (exit 127, the
      # loader mis-naming api-ms-win-crt-utility).
      expect(result).to include("-l:libffi.a")
      expect(result).to include("-l:libdl.a")
      expect(result).to include("-l:libyaml.a")
    end

    context "with tagged boost archives in the vcpkg triplet" do
      subject(:mlibs) do
        described_class.new(TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64"),
                            File.join(root, "deps", "lib"))
      end

      let(:root) { Dir.mktmpdir }

      before do
        FileUtils.mkdir_p(File.join(root, "deps", "lib"))
        triplet_lib = File.join(root, "deps", "vcpkg_installed", "x64-mingw-static", "lib")
        FileUtils.mkdir_p(triplet_lib)
        FileUtils.touch(File.join(triplet_lib, "libboost_filesystem-gcc16-mt-x64-1_90.a"))
        FileUtils.touch(File.join(triplet_lib, "libboost_chrono-gcc16-mt-x64-1_90.a"))
      end

      after do
        FileUtils.remove_entry(root)
      end

      it "resolves the boost references to the tagged archives by full path (in the DLL's SOLIBS)" do
        triplet_lib = File.join(root, "deps", "vcpkg_installed", "x64-mingw-static", "lib")
        result = mlibs.compute_solibs(ruby_ver)
        expect(result).to include("#{triplet_lib}/libboost_filesystem-gcc16-mt-x64-1_90.a")
        expect(result).to include("#{triplet_lib}/libboost_chrono-gcc16-mt-x64-1_90.a")
        expect(result).not_to include("-l:libboost_filesystem.a")
        expect(result).not_to include("-l:libboost_chrono.a")
      end
    end
    context "with a staged rust link unit (the v2 link)" do
      subject(:mlibs) do
        described_class.new(TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64"), "/deps/lib")
      end

      let(:root) { Dir.mktmpdir }

      before do
        FileUtils.touch(File.join(root, "libtebako_driver.a"))
        FileUtils.touch(File.join(root, "libtfs.a"))
        FileUtils.mkdir_p(File.join(root, "closure"))
        FileUtils.touch(File.join(root, "closure", "libfmt.a"))
        @prev_libdir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)
        ENV["TEBAKO_RUST_LIBDIR"] = root
      end

      after do
        @prev_libdir.nil? ? ENV.delete("TEBAKO_RUST_LIBDIR") : ENV["TEBAKO_RUST_LIBDIR"] = @prev_libdir
        FileUtils.remove_entry(root)
      end

      it "links the fs TU shim archive plainly (no --whole-archive, no import-lib literal, issue 40)" do
        result = mlibs.compute(ruby_ver)
        expect(result).to start_with(
          "-Wl,-Bstatic -Wl,--start-group " \
          "-l:libtebako-fs.a -Wl,--end-group"
        )
      end

      it "rides the scoped driver + libtfs.a + closure in the DLL's SOLIBS, never the exe's MAINLIBS" do
        solibs = mlibs.compute_solibs(ruby_ver)
        expect(solibs).to include("#{root}/libtebako_driver.a")
        expect(solibs).to include("#{root}/libtfs.a")
        expect(solibs).to include("#{root}/closure/libfmt.a")
        mainlibs = mlibs.compute(ruby_ver)
        expect(mainlibs).not_to include("#{root}/libtebako_driver.a")
        expect(mainlibs).not_to include("#{root}/libtfs.a")
        expect(mainlibs).not_to include("#{root}/closure/libfmt.a")
      end

      it "links miniruby with the whole-archive minimal stub + the driver archive (issue 40)" do
        minilibs = mlibs.compute_minilibs(ruby_ver)
        # the stub is the only C-visible tebako_main (the driver's own is
        # not a C export); its minimal content keeps the pull collision-free
        expect(minilibs).to include("-Wl,--push-state,--whole-archive -l:libtebako-fs.a -Wl,--pop-state")
        expect(minilibs).to include("#{root}/libtebako_driver.a")
        expect(minilibs).to include("#{root}/libtfs.a")
      end

      it "dedupes the pacman-covered closure archives (re-provided from pacman in the DLL link)" do
        FileUtils.touch(File.join(root, "closure", "libssl.a"))
        solibs = mlibs.compute_solibs(ruby_ver)
        expect(solibs).not_to include("closure/libssl.a")
        expect(solibs).to include("-l:libssl.a")
      end
    end
  end

  context "on darwin" do
    subject(:mlibs) do
      described_class.new(TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64"),
                          File.join(root, "deps", "lib"),
                          prefix_resolver: ->(package) { "/brew/#{package}" })
    end

    let(:root) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(root, "deps", "lib"))
      FileUtils.mkdir_p(File.join(root, "deps", "vcpkg_installed", "arm64-osx", "lib"))
    end

    after do
      FileUtils.remove_entry(root)
    end

    it "computes the full-path static library list" do
      # NB: the vcpkg paths keep the non-normalized 'deps/lib/../' form, as
      # the gem's PatchLibraries produced them (the linker resolves them)
      vcpkg = File.join(root, "deps", "lib", "..", "vcpkg_installed", "arm64-osx", "lib")
      expected = "-Wl,-ld_classic -ltebako-fs " \
                 "#{root}/deps/lib/libtfs.a " \
                 "/brew/openssl@3/lib/libssl.a /brew/openssl@3/lib/libcrypto.a " \
                 "/brew/zlib/lib/libz.a /brew/gdbm/lib/libgdbm.a /brew/readline/lib/libreadline.a " \
                 "/brew/libffi/lib/libffi.a /brew/ncurses/lib/libncurses.a /brew/lz4/lib/liblz4.a " \
                 "/brew/xz/lib/liblzma.a /brew/libyaml/lib/libyaml.a " \
                 "#{vcpkg}/libdwarfs_reader.a #{vcpkg}/libdwarfs_common.a #{vcpkg}/libdwarfs_metadata_legacy.a " \
                 "#{vcpkg}/libdwarfs_decompressor.a #{vcpkg}/libflatbuffers.a #{vcpkg}/libzip.a " \
                 "#{vcpkg}/libfmt.a #{vcpkg}/libxxhash.a #{vcpkg}/libzstd.a " \
                 "#{vcpkg}/libbrotlidec.a #{vcpkg}/libbrotlienc.a #{vcpkg}/libbrotlicommon.a " \
                 "#{vcpkg}/libbz2.a #{vcpkg}/libboost_filesystem.a #{vcpkg}/libboost_chrono.a " \
                 "-lc++ -lc++abi"
      expect(mlibs.compute(ruby_ver)).to eq(expected)
    end
  end
end
