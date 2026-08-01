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
    def layout_for(ruby_version, mount_point: "/__tfs__")
      rv = TebakoRuntimeBuilder::RubyVersion.new(ruby_version)
      platform = TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64")
      described_class.new(platform, rv, File.join(@dir, "stash"), data_src_dir, File.join(@dir, "pre"),
                          File.join(@dir, "out", "fs.bin"), File.join(@dir, "deps", "bin"),
                          mount_point: mount_point, embed: false).deploy_layout
      YAML.load_file(File.join(data_src_dir, "lib", "tebako", "layout.yaml"))
    end

    it "writes the era-2 layout declaration into the image tree" do
      expect(layout_for("3.3.7")).to eq(
        "schema" => "layout",
        "schema_version" => 1,
        "era" => 2,
        "image_layout" => 1,
        "mount_root" => "/__tfs__",
        "interpreter" => { "name" => "ruby", "api_version" => "3.3.0" }
      )
    end

    it "flows the msys drive-letter mount root and the 4.0 api line" do
      expect(layout_for("4.0.6", mount_point: "A:/t")).to include(
        "mount_root" => "A:/t",
        "interpreter" => { "name" => "ruby", "api_version" => "4.0.0" }
      )
    end
  end
end
