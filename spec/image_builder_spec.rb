# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "yaml"

# The image-content repair ImageBuilder applies for the ruby 3.4 line:
# backport_bundler_erofs_degradation rewrites the layout tree's bundled
# bundler so ProcessLock degrades to no-lock on the read-only memfs (the
# bundler 2.6.0-2.6.5 gap fixed upstream in 2.6.6). Fixture indentation is
# significant: the backport anchors on the bundled file's exact
# SystemCallError catch-all line.

# SharedHelpers.filesystem_access as bundled by ruby 3.4.0-3.4.2
# (bundler 2.6.2): no Errno::EROFS branch.
BUNDLER_262_SHAPE = <<~'RUBY'
  module Bundler
    module SharedHelpers
      def filesystem_access(path, action = :write, &block)
        yield(path.dup)
      rescue Errno::EACCES => e
        raise unless e.message.include?(path.to_s) || action == :create

        raise PermissionError.new(path, action)
      rescue Errno::EEXIST, Errno::ENOENT
        raise
      rescue SystemCallError => e
        raise GenericSystemCallError.new(e, "There was an error accessing `#{path}`.")
      end
    end
  end
RUBY

# The upstream-fixed shape (bundler >= 2.6.6 / 4.x): EROFS maps to
# ReadOnlyFileSystemError < PermissionError already.
BUNDLER_266_SHAPE = <<~'RUBY'
  module Bundler
    module SharedHelpers
      def filesystem_access(path, action = :write, &block)
        yield(path.dup)
      rescue Errno::EACCES => e
        raise unless e.message.include?(path.to_s) || action == :create

        raise PermissionError.new(path, action)
      rescue Errno::EROFS
        raise ReadOnlyFileSystemError.new(path, action)
      rescue Errno::EEXIST, Errno::ENOENT
        raise
      rescue SystemCallError => e
        raise GenericSystemCallError.new(e, "There was an error accessing `#{path}`.")
      end
    end
  end
RUBY

RSpec.describe TebakoRuntimeBuilder::ImageBuilder do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def builder_for(ruby_version)
    rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_version)
    platform = TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64")
    described_class.new(platform, rv, File.join(@dir, "stash"), data_src_dir, File.join(@dir, "pre"),
                        File.join(@dir, "out", "fs.bin"), File.join(@dir, "deps", "bin"),
                        mount_point: "/__tfs__", embed: false)
  end

  def data_src_dir
    File.join(@dir, "s")
  end

  # The default-gem install lands bundler's lib files in the stdlib dir;
  # the gems/ dir of a default gem keeps only exe/.
  def write_bundler_helpers(content)
    helpers = File.join(data_src_dir, "lib", "ruby", "3.4.0", "bundler", "shared_helpers.rb")
    FileUtils.mkdir_p(File.dirname(helpers))
    File.write(helpers, content)
    helpers
  end

  def backport(ruby_version)
    builder_for(ruby_version).send(:backport_bundler_erofs_degradation)
  end

  it "inserts the EROFS degradation ahead of the catch-all on the ruby 3.4 line" do
    helpers = write_bundler_helpers(BUNDLER_262_SHAPE)

    backport("3.4.2")

    patched = File.read(helpers)
    expect(patched).to include(described_class::BUNDLER_EROFS_BRANCH)
    branch_at = patched.index(described_class::BUNDLER_EROFS_BRANCH)
    anchor_at = patched.index(described_class::BUNDLER_RESCUE_ANCHOR)
    expect(branch_at + described_class::BUNDLER_EROFS_BRANCH.length).to eq(anchor_at)
  end

  it "also reaches a bundler held fully under the gems dir" do
    helpers = File.join(data_src_dir, "lib", "ruby", "gems", "3.4.0", "gems",
                        "bundler-2.6.2", "lib", "bundler", "shared_helpers.rb")
    FileUtils.mkdir_p(File.dirname(helpers))
    File.write(helpers, BUNDLER_262_SHAPE)

    backport("3.4.2")

    expect(File.read(helpers)).to include(described_class::BUNDLER_EROFS_BRANCH)
  end

  it "keeps the patched file valid Ruby" do
    helpers = write_bundler_helpers(BUNDLER_262_SHAPE)

    backport("3.4.1")

    expect { RubyVM::InstructionSequence.compile(File.read(helpers)) }.not_to raise_error
  end

  it "leaves an already EROFS-tolerant bundler untouched" do
    helpers = write_bundler_helpers(BUNDLER_266_SHAPE)

    backport("3.4.2")

    expect(File.read(helpers)).to eq(BUNDLER_266_SHAPE)
  end

  it "leaves other ruby lines untouched even with the affected bundler shape" do
    helpers = write_bundler_helpers(BUNDLER_262_SHAPE)

    backport("3.3.7")
    backport("4.0.6")

    expect(File.read(helpers)).to eq(BUNDLER_262_SHAPE)
  end

  it "is a no-op when the layout tree carries no bundler" do
    expect { backport("3.4.2") }.not_to raise_error
  end

  # Spec 18 C3/S17: the env image declares itself at /lib/tebako/layout.yaml —
  # the driver reads exactly this file post-mount (missing → era-1 refusal;
  # mount_root ≠ the exe's compiled-in root → exit 78). mount_root flows
  # from the tarball manifest through the deploy pass; the interpreter api
  # line comes from the built ruby version.
  describe "#deploy_layout" do
    def layout_for(ruby_version, mount_point: "/__tfs__", mount_root_override: false, platform: nil)
      rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_version)
      platform ||= TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64")
      described_class.new(platform, rv, File.join(@dir, "stash"), data_src_dir, File.join(@dir, "pre"),
                          File.join(@dir, "out", "fs.bin"), File.join(@dir, "deps", "bin"),
                          mount_point: mount_point, embed: false,
                          mount_root_override: mount_root_override).deploy_layout
      YAML.load_file(File.join(data_src_dir, "lib", "tebako", "layout.yaml"))
    end

    it "writes the era-2 layout declaration into the image tree" do
      expect(layout_for("3.3.7")).to eq(
        "schema" => "layout",
        "schema_version" => 1,
        "era" => 2,
        "image_layout" => 1,
        "mount_root" => "/__tfs__",
        "interpreter_api_version" => "3.3.0"
      )
    end

    it "emits the override grant only for a source declaring the capability (spec 17 §1)" do
      expect(layout_for("4.0.6", mount_point: "A:/t", mount_root_override: true)).to include(
        "mount_root" => "A:/t",
        "mount_root_override" => true,
        "interpreter_api_version" => "4.0.0"
      )
      expect(layout_for("4.0.6", mount_point: "A:/t")).not_to have_key("mount_root_override")
    end

    # The runtime's own PE module basename (schema_minor 3): MSYS builds
    # declare it — flowed from RubyVersion#msys_dll_name, the name's
    # single owner (invariant 10) — so the driver can export
    # TEBAKO_RUNTIME_DLL for the tfs PE closure walk's exclusion (spec 22
    # §2.1). POSIX builds omit the key.
    it "emits runtime_dll for MSYS builds only, flowed from RubyVersion#msys_dll_name" do
      msys = TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64")
      expect(layout_for("3.4.8", platform: msys)).to include(
        "runtime_dll" => "x64-ucrt-ruby340.dll",
        "interpreter_api_version" => "3.4.0"
      )
      expect(layout_for("4.0.6", platform: msys)).to include("runtime_dll" => "x64-ucrt-ruby400.dll")
      expect(layout_for("3.4.8")).not_to have_key("runtime_dll")
      expect(layout_for("3.4.8", platform: TebakoRuntimeBuilder::Platform.new("x86_64-linux-musl", "x86_64")))
        .not_to have_key("runtime_dll")
    end
  end

  # Spec 22 §3: when the link unit provides the preload shim, deploy_preload
  # stages it at lib/tebako/ and the layout declares exactly that in-image
  # path (schema_minor 2 — the driver refuses a declaration whose file the
  # image does not hold); an older link unit (no shim) declares nothing.
  describe "#deploy_preload" do
    def rust_libdir(with_shim: true)
      dir = File.join(@dir, "rustlib")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "libtfs_preload.dylib"), "shim") if with_shim
      dir
    end

    def staged_layout(libdir)
      builder = builder_for("3.3.7")
      TebakoRuntimeBuilder::BuildHelpers.with_env("TEBAKO_RUST_LIBDIR" => libdir) do
        builder.deploy_preload
      end
      builder.deploy_layout
      YAML.load_file(File.join(data_src_dir, "lib", "tebako", "layout.yaml"))
    end

    it "stages the shim and declares its in-image path in the layout" do
      layout = staged_layout(rust_libdir)

      expect(File.file?(File.join(data_src_dir, "lib", "tebako", "libtfs_preload.dylib"))).to be(true)
      expect(layout["preload_shim"]).to eq("lib/tebako/libtfs_preload.dylib")
    end

    it "declares nothing when the link unit carries no shim" do
      expect(staged_layout(rust_libdir(with_shim: false))).not_to have_key("preload_shim")
    end

    it "stages nothing and declares nothing when TEBAKO_RUST_LIBDIR is unset" do
      layout = staged_layout(nil)

      expect(layout).not_to have_key("preload_shim")
      expect(File.exist?(File.join(data_src_dir, "lib", "tebako", "libtfs_preload.dylib"))).to be(false)
    end
  end

  # Spec 22 §2.1 (the packed-mn#251 windows 126): the msys deploy stages
  # the toolchain support-DLL set into the image's bin/ so the manifest's
  # library_aliases: declaration (ImageManifest) never lies. POSIX deploys
  # stage nothing — the alias channel is a windows contract.
  describe "#deploy_support_dlls" do
    def fake_prefix(names)
      root = File.join(@dir, "ucrt64")
      FileUtils.mkdir_p(File.join(root, "bin"))
      names.each { |name| File.write(File.join(root, "bin", name), "pe") }
      root
    end

    def builder_with_dlls(platform, prefixes)
      rv = TebakoRuntimeBuilder::RubyVersion.new("3.3.7")
      described_class.new(platform, rv, File.join(@dir, "stash"), data_src_dir, File.join(@dir, "pre"),
                          File.join(@dir, "out", "fs.bin"), File.join(@dir, "deps", "bin"),
                          mount_point: "A:/t", embed: false,
                          support_dlls: TebakoRuntimeBuilder::SupportDlls.new(prefixes: prefixes))
    end

    it "stages the full set into bin/ on msys" do
      msys = TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64")
      prefix = fake_prefix(TebakoRuntimeBuilder::SupportDlls::NAMES)

      builder_with_dlls(msys, [prefix]).deploy_support_dlls

      TebakoRuntimeBuilder::SupportDlls::NAMES.each do |name|
        expect(File.file?(File.join(data_src_dir, "bin", name))).to be(true)
      end
    end

    it "fails closed by name when the toolchain prefix lacks a member" do
      msys = TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64")
      prefix = fake_prefix(%w[libwinpthread-1.dll])

      expect { builder_with_dlls(msys, [prefix]).deploy_support_dlls }
        .to raise_error(TebakoRuntimeBuilder::Error, /libgcc_s_seh-1\.dll/)
    end

    it "stages nothing off msys" do
      posix = TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64")

      builder_with_dlls(posix, []).deploy_support_dlls

      expect(File.exist?(File.join(data_src_dir, "bin", "libwinpthread-1.dll"))).to be(false)
    end
  end
end
