# frozen_string_literal: true

require "spec_helper"
require "fileutils"

# A fake tfs CLI: logs its argv (one arg per line) to $FAKE_ARGS_LOG
# and creates the file named after -o.
FAKE_TFS_SCRIPT = <<~SH
  #!/bin/sh
  printf '%s\\n' "$@" > "$FAKE_ARGS_LOG"
  out=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; fi
    prev="$a"
  done
  [ -n "$out" ] && : > "$out"
SH

RSpec.describe TebakoRuntimeBuilder::ImagePackager do
  let(:platform) { TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64") }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def fake_tfs
    File.join(@dir, "tfs").tap do |path|
      File.write(path, FAKE_TFS_SCRIPT)
      FileUtils.chmod(0o755, path)
    end
  end

  def layout_dir
    File.join(@dir, "s").tap do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "ruby"), "fake")
    end
  end

  def image_path
    File.join(@dir, "out", "tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs")
  end

  def args_log
    File.read(File.join(@dir, "args.log")).lines.map(&:chomp)
  end

  def with_env(vars)
    old = vars.to_h { |key,| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "packs the layout via tfs mkimage (no --format flag: the CLI default is limnifs, spec 20 §6)" do
    packager = described_class.new(platform, tfs: fake_tfs)

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log")) do
      packager.package(layout_dir, image_path)
    end

    expect(File.file?(image_path)).to be(true)
    expect(args_log).to eq(["mkimage", layout_dir, "-o", image_path])
  end

  it "packs windows/arm64 exactly like every other host (limnifs is the only first-class image)" do
    arm64 = TebakoRuntimeBuilder::Platform.new("aarch64-mingw-ucrt", "aarch64")
    packager = described_class.new(arm64, tfs: fake_tfs)

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log")) do
      packager.package(layout_dir, image_path)
    end

    expect(args_log).to eq(["mkimage", layout_dir, "-o", image_path])
  end

  it "replaces a stale image from a previous run" do
    tfs = fake_tfs
    FileUtils.mkdir_p(File.dirname(image_path))
    File.write(image_path, "stale")
    packager = described_class.new(platform, tfs: tfs)

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log")) do
      packager.package(layout_dir, image_path)
    end

    expect(File.read(image_path)).to eq("")
  end

  it "fails loudly when the layout tree is missing" do
    packager = described_class.new(platform, tfs: fake_tfs)

    expect { packager.package(File.join(@dir, "no-such-layout"), image_path) }
      .to raise_error(TebakoRuntimeBuilder::Error) { |error| expect(error.error_code).to eq(131) }
  end
end

RSpec.describe TebakoRuntimeBuilder::TfsTool do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def with_env(vars)
    old = vars.to_h { |key,| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  describe ".resolve_requested" do
    let(:platform) { TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64") }

    it "resolves a direct executable path" do
      tfs = File.join(@dir, "tfs-custom")
      File.write(tfs, "#!/bin/sh\n")
      FileUtils.chmod(0o755, tfs)

      expect(described_class.resolve_requested(tfs, platform)).to eq(tfs)
    end

    it "resolves a bare name off PATH" do
      bin = File.join(@dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "tfs"), "#!/bin/sh\n")
      FileUtils.chmod(0o755, File.join(bin, "tfs"))

      with_env("PATH" => bin) do
        expect(described_class.resolve_requested("tfs", platform)).to eq(File.join(bin, "tfs"))
      end
    end

    it "tries the .exe spelling on msys hosts" do
      msys = TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x64")
      bin = File.join(@dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "tfs.exe"), "MZ")
      FileUtils.chmod(0o755, File.join(bin, "tfs.exe"))

      with_env("PATH" => bin) do
        expect(described_class.resolve_requested("tfs", msys)).to eq(File.join(bin, "tfs.exe"))
      end
    end

    it "fails closed when the request does not resolve (never a silent fallback)" do
      with_env("PATH" => @dir) do
        expect { described_class.resolve_requested("no-such-tfs", platform) }
          .to raise_error(TebakoRuntimeBuilder::Error) do |error|
            expect(error.error_code).to eq(131)
            expect(error.message).to include("no-such-tfs")
          end
      end
    end
  end

  it "names the CLI asset after the release pin and the platform" do
    platform = TebakoRuntimeBuilder::Platform.new("arm64-darwin23", "arm64")
    tool = described_class.new(cache_dir: @dir, release: "v2.8.16", platform: platform)

    expect(tool.asset_name).to eq("tfs-2.8.16-macos-arm64")
  end
end

RSpec.describe TebakoRuntimeBuilder::Builder do
  def builder(output)
    described_class.new(repo_root: REPO_ROOT, ruby_version: "3.3.7", tebako_version: "9.9.9",
                        prefix: File.join(Dir.pwd, ".build"), output: output)
  end

  it "names the image after the output package with the .tfs extension" do
    expect(builder("/tmp/pkg/tebako-runtime-9.9.9-3.3.7-macos-arm64").image_output)
      .to eq("/tmp/pkg/tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs")
  end

  it "strips the .exe suffix when naming the image" do
    expect(builder("/tmp/pkg/tebako-runtime-9.9.9-3.3.7-windows-ucrt64.exe").image_output)
      .to eq("/tmp/pkg/tebako-runtime-9.9.9-3.3.7-windows-ucrt64.tfs")
  end

  it "derives the default image name from the default package name" do
    b = builder(nil)
    expect(b.image_output).to eq("#{b.default_output.sub(/\.exe\z/, "")}.tfs")
    expect(File.basename(b.image_output)).to match(/\Atebako-runtime-9\.9\.9-3\.3\.7-.+\.tfs\z/)
  end
end
