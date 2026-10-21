# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "spec_helper"

# The env image's spawn surface (spec 30 §2): the declarations are DERIVED
# from the layout tree's actual bin/ inventory — never a hand-kept list —
# and the read-back gate proves both directions against the packed image.
RSpec.describe TebakoRuntimeBuilder::Entrypoints do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:gnu) { TebakoRuntimeBuilder::Platform.new("x86_64-linux-gnu", "x86_64") }
  let(:msys) { TebakoRuntimeBuilder::Platform.new("x64-mingw-ucrt", "x86_64") }
  let(:tree) { File.join(@dir, "s") }
  let(:bin) { File.join(tree, "bin") }

  def write_script(name, body = "puts :ok\n")
    FileUtils.mkdir_p(bin)
    path = File.join(bin, name)
    File.write(path, "#!/usr/bin/env ruby\n#{body}")
    path
  end

  def write_file(name, content)
    FileUtils.mkdir_p(bin)
    path = File.join(bin, name)
    File.write(path, content)
    path
  end

  describe "#declarations" do
    it "derives the surface from the POSIX bin inventory (name = basename, path = /bin/<name>)" do
      write_script("gem")
      write_script("irb")
      write_script("rake")

      expect(described_class.new(platform: gnu).declarations(tree)).to eq(
        [
          { "name" => "gem", "path" => "/bin/gem" },
          { "name" => "irb", "path" => "/bin/irb" },
          { "name" => "rake", "path" => "/bin/rake" }
        ]
      )
    end

    it "excludes the installed interpreter (the runtime executable is the interpreter)" do
      write_script("gem")
      write_file("ruby", "\x7fELF")
      write_file("rubyw", "\x7fELF")

      names = described_class.new(platform: gnu).declarations(tree).map { |decl| decl["name"] }
      expect(names).to eq(["gem"])
    end

    it "does not declare a non-script file — the read-back gate names it as a stray instead" do
      write_script("gem")
      write_file("not-a-script", "binary")

      expect(described_class.new(platform: gnu).declarations(tree).map { |decl| decl["name"] }).to eq(["gem"])
    end

    it "declares the msys .cmd shape with ruby's -x (rbinstall's cmdtype='cmd' polyglot)" do
      polyglot = <<~CMD
        :""||{ ""=> %q<-*- ruby -*-
        @"%~dp0ruby.exe" -x "%~f0" %*
        @exit /b %ERRORLEVEL%
        };{ #
        bindir="${0%/*}" #
        exec "$bindir/ruby.exe" "-x" "$0" "$@" #
        >,
        #!/usr/bin/env ruby
      CMD
      write_file("gem.cmd", polyglot)
      write_file("ruby.exe", "MZ")
      write_file("libwinpthread-1.dll", "MZ")

      expect(described_class.new(platform: msys).declarations(tree)).to eq(
        [{ "name" => "gem", "path" => "/bin/gem.cmd", "args_default" => ["-x"] }]
      )
    end

    # The rubygems gem-executable install (rake/irb/minitest …) lands an
    # extensionless ruby script plus a .bat launcher — the published
    # v0.17.1 windows image's /bin holds exactly this shape. The script is
    # the entry; the launcher is its twin, never a second command.
    it "declares the msys extensionless gem-executable shape without args_default" do
      write_script("minitest")
      write_file("minitest.bat", "@ECHO OFF\r\n@ruby.exe \"%~dpn0\" %*\r\n")
      write_file("ruby.exe", "MZ")

      expect(described_class.new(platform: msys).declarations(tree)).to eq(
        [{ "name" => "minitest", "path" => "/bin/minitest" }]
      )
    end

    # The same install shape in its batch-polyglot spelling: rubygems'
    # WindowsScript writes an UNSUFFIXED <name> whose head is the same
    # `:""||{` prolog (the published v0.17.1 windows image's
    # /bin/minitest is exactly this, 703 B). It is not a shebang script,
    # so it declares ruby's -x; the .bat twin stays excluded.
    it "declares the unsuffixed msys polyglot (rubygems WindowsScript) with ruby's -x" do
      polyglot = <<~CMD
        :""||{ ""=> %q<-*- ruby -*-
        @"%~dp0ruby" -x "%~f0" %*
        @exit /b %ERRORLEVEL%
        };{ #
        bindir="${0%/*}" #
        exec "$bindir/ruby" "-x" "$0" "$@" #
        >,
        }
        #!/usr/bin/env -S ruby
      CMD
      write_file("minitest", polyglot)
      write_file("minitest.bat", "@ECHO OFF\r\n@ruby.exe \"%~dpn0\" %*\r\n")

      expect(described_class.new(platform: msys).declarations(tree)).to eq(
        [{ "name" => "minitest", "path" => "/bin/minitest", "args_default" => ["-x"] }]
      )
    end

    it "fails closed by name when bin/ holds no command script" do
      FileUtils.mkdir_p(bin)
      write_file("ruby.exe", "MZ")

      expect { described_class.new(platform: msys).declarations(tree) }
        .to raise_error(TebakoRuntimeBuilder::Error, /no command script in bin/)
    end

    it "fails closed by name when the layout tree carries no bin/" do
      expect { described_class.new(platform: gnu).declarations(tree) }
        .to raise_error(TebakoRuntimeBuilder::Error, %r{carries no bin/ directory})
    end
  end

  describe "#stage" do
    it "normalizes the staged scripts' mode and answers the declarations" do
      path = write_script("gem")
      FileUtils.chmod(0o644, path)

      declarations = described_class.new(platform: gnu).stage(tree)

      expect(File.stat(path).mode & 0o777).to eq(0o755)
      expect(declarations).to eq([{ "name" => "gem", "path" => "/bin/gem" }])
    end
  end

  describe ".canonical" do
    it "spells an absent args_default as [] and sorts by name (the writer's re-render shape)" do
      declarations = [{ "name" => "rake", "path" => "/bin/rake" },
                      { "name" => "gem", "path" => "/bin/gem", "args_default" => ["-x"] }]

      expect(described_class.canonical(declarations)).to eq(
        [{ "name" => "gem", "path" => "/bin/gem", "args_default" => ["-x"] },
         { "name" => "rake", "path" => "/bin/rake", "args_default" => [] }]
      )
    end
  end

  describe "#verify!" do
    let(:surface) { described_class.new(platform: msys) }

    it "accepts the declared files plus the interpreter and alias-channel exclusions" do
      declared = [{ "name" => "gem", "path" => "/bin/gem.cmd", "args_default" => ["-x"] }]
      entries = %w[gem.cmd ruby.exe libwinpthread-1.dll libgcc_s_seh-1.dll libstdc++-6.dll]

      expect(surface.verify!(declared: declared, image_entries: entries)).to eq(declared)
    end

    it "accepts the interpreter's own versioned shared library (ruby 4's msys shape)" do
      declared = [{ "name" => "gem", "path" => "/bin/gem.cmd", "args_default" => ["-x"] }]
      entries = %w[gem.cmd ruby.exe rubyw.exe aarch64-ucrt-ruby400.dll libwinpthread-1.dll]

      expect(surface.verify!(declared: declared, image_entries: entries)).to eq(declared)
      # older lines spell it through the msvcrt prefix; the gem's own
      # .dll is still a stray.
      older = %w[gem.cmd ruby.exe msvcrt-ruby300.dll]
      expect(surface.verify!(declared: declared, image_entries: older)).to eq(declared)
      expect { surface.verify!(declared: declared, image_entries: %w[gem.cmd ruby.exe evil.dll]) }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not declare: evil\.dll/)
    end

    it "accepts a declared script's .bat launcher twin" do
      declared = [{ "name" => "minitest", "path" => "/bin/minitest" },
                  { "name" => "test-unit", "path" => "/bin/test-unit" }]
      entries = %w[minitest minitest.bat test-unit test-unit.bat ruby.exe libwinpthread-1.dll]

      expect(surface.verify!(declared: declared, image_entries: entries)).to eq(declared)
    end

    it "refuses a launcher twin whose base name is not declared" do
      declared = [{ "name" => "gem", "path" => "/bin/gem.cmd", "args_default" => ["-x"] }]

      expect { surface.verify!(declared: declared, image_entries: %w[gem.cmd minitest.bat]) }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not declare: minitest\.bat/)
    end

    it "refuses a declared path the image does not hold (the declaration lies)" do
      declared = [{ "name" => "gem", "path" => "/bin/gem" }]

      expect { surface.verify!(declared: declared, image_entries: ["rake"]) }
        .to raise_error(TebakoRuntimeBuilder::Error, /declaration lies/)
    end

    it "refuses a declaration whose path is not /bin/<basename>" do
      declared = [{ "name" => "gem", "path" => "/lib/ruby/gems/bin/gem" }]

      expect { surface.verify!(declared: declared, image_entries: ["gem"]) }
        .to raise_error(TebakoRuntimeBuilder::Error, /declaration lies/)
    end

    it "refuses a staged script the manifest does not declare" do
      declared = [{ "name" => "gem", "path" => "/bin/gem.cmd", "args_default" => ["-x"] }]

      expect { surface.verify!(declared: declared, image_entries: %w[gem.cmd rake.cmd]) }
        .to raise_error(TebakoRuntimeBuilder::Error, /does not declare: rake\.cmd/)
    end

    it "refuses repeated command names" do
      declared = [{ "name" => "gem", "path" => "/bin/gem" }, { "name" => "gem", "path" => "/bin/gem2" }]

      expect { surface.verify!(declared: declared, image_entries: %w[gem gem2]) }
        .to raise_error(TebakoRuntimeBuilder::Error, /repeats the name\(s\) gem/)
    end
  end
end
