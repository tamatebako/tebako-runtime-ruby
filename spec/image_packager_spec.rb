# frozen_string_literal: true

require "spec_helper"
require "fileutils"

# A fake image tool: logs its argv (one arg per line) to $FAKE_ARGS_LOG
# and creates the file named after -o.
FAKE_TOOL_SCRIPT = <<~SH
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

  def layout_dir
    File.join(@dir, "s").tap do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "ruby"), "fake")
    end
  end

  def deps_bin_dir
    File.join(@dir, "deps", "bin").tap { |dir| FileUtils.mkdir_p(dir) }
  end

  def image_path
    File.join(@dir, "out", "tebako-runtime-9.9.9-3.3.7-macos-arm64.tfs")
  end

  def fake_tool(dir, name)
    File.join(dir, name).tap do |path|
      File.write(path, FAKE_TOOL_SCRIPT)
      FileUtils.chmod(0o755, path)
    end
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

  it "packs the layout via tfs mkimage when tfs resolves (the in-process writer — no mkdwarfs handoff)" do
    tfs = fake_tool(@dir, "tfs")
    fake_tool(deps_bin_dir, "mkdwarfs")
    packager = described_class.new(platform, deps_bin_dir, tfs: tfs)

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log")) do
      packager.package(layout_dir, image_path)
    end

    expect(File.file?(image_path)).to be(true)
    expect(args_log).to eq(["mkimage", "--format", "dwarfs", layout_dir, "-o", image_path])
  end

  it "uses tfs from PATH when nothing is requested explicitly" do
    bin = File.join(@dir, "path-bin")
    FileUtils.mkdir_p(bin)
    fake_tool(bin, "tfs")
    fake_tool(deps_bin_dir, "mkdwarfs")
    packager = described_class.new(platform, deps_bin_dir)

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log"), "PATH" => bin, "TEBAKO_TFS" => nil) do
      packager.package(layout_dir, image_path)
    end

    expect(args_log.first(3)).to eq(["mkimage", "--format", "dwarfs"])
  end

  it "falls back to the deps mkdwarfs when no tfs resolves" do
    fake_tool(deps_bin_dir, "mkdwarfs")
    empty = File.join(@dir, "empty-path")
    FileUtils.mkdir_p(empty)
    packager = described_class.new(platform, deps_bin_dir)

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log"), "PATH" => empty, "TEBAKO_TFS" => nil) do
      packager.package(layout_dir, image_path)
    end

    expect(File.file?(image_path)).to be(true)
    expect(args_log).to eq(["-i", layout_dir, "-o", image_path, "--no-progress", "--force"])
  end

  it "replaces a stale image from a previous run" do
    fake_tool(@dir, "tfs")
    fake_tool(deps_bin_dir, "mkdwarfs")
    FileUtils.mkdir_p(File.dirname(image_path))
    File.write(image_path, "stale")
    packager = described_class.new(platform, deps_bin_dir, tfs: File.join(@dir, "tfs"))

    with_env("FAKE_ARGS_LOG" => File.join(@dir, "args.log")) do
      packager.package(layout_dir, image_path)
    end

    expect(File.read(image_path)).to eq("")
  end

  it "fails loudly when an explicitly requested tfs does not resolve" do
    packager = described_class.new(platform, deps_bin_dir, tfs: File.join(@dir, "no-such-tfs"))

    expect { packager.package(layout_dir, image_path) }
      .to raise_error(TebakoRuntimeBuilder::Error) { |error| expect(error.error_code).to eq(131) }
  end

  it "fails loudly when neither tfs nor the deps mkdwarfs is available" do
    empty = File.join(@dir, "empty-path")
    FileUtils.mkdir_p(empty)
    packager = described_class.new(platform, deps_bin_dir)

    with_env("PATH" => empty, "TEBAKO_TFS" => nil) do
      expect { packager.package(layout_dir, image_path) }
        .to raise_error(TebakoRuntimeBuilder::Error) do |error|
          expect(error.error_code).to eq(131)
          expect(error.message).to include("no image tool available")
        end
    end
  end

  it "fails loudly when the layout tree is missing" do
    packager = described_class.new(platform, deps_bin_dir)

    expect { packager.package(File.join(@dir, "no-such-layout"), image_path) }
      .to raise_error(TebakoRuntimeBuilder::Error) { |error| expect(error.error_code).to eq(131) }
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
