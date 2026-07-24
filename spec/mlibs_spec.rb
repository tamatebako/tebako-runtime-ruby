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
                 "-l:libtfs.a -l:libtebako_dirent_helper_c.a " \
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

  context "on msys" do
    subject(:mlibs) do
      described_class.new(TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64"), "/deps/lib")
    end

    it "prepends -Wl,-Bstatic only with compression" do
      expect(mlibs.compute(ruby_ver, with_compression: true)).to start_with("-Wl,-Bstatic -Wl,--push-state")
      expect(mlibs.compute(ruby_ver, with_compression: false)).to start_with("-Wl,--push-state")
    end

    it "carries the windows system libs" do
      expect(mlibs.compute(ruby_ver)).to include("-lws2_32")
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
      expected = "-ltebako-fs " \
                 "#{root}/deps/lib/libtfs.a #{root}/deps/lib/libtebako_dirent_helper_c.a " \
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
