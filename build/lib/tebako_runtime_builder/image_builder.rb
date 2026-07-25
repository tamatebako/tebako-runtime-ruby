# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
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

require "fileutils"
require "open3"

module TebakoRuntimeBuilder
  # Builds the runtime package filesystem image (fs.bin) from the stashed
  # pristine ruby environment -- the runtime-mode subset of the gem's
  # Packager.init + DeployHelper (simple_script scenario) + Packager.mkdwarfs.
  #
  # The image content is the stashed ruby installation plus /local/stub.rb
  # (the runtime's compiled-in entry point) and the tebako-runtime gem, which
  # the patched gem_prelude.rb requires at interpreter startup. For the
  # supported ruby matrix (>= 3.1.6) the gem's deploy gates
  # (DeployHelper#configure: '@needs_bundler = true unless ruby31?',
  # #update_rubygems: 'return if ruby31?') make the rubygems update and the
  # bundler install no-ops, so they are not carried here.
  class ImageBuilder # rubocop:disable Metrics/ClassLength
    def initialize(platform, ruby_ver, stash_dir, data_src_dir, data_pre_dir, data_bin_file, deps_bin_dir) # rubocop:disable Metrics/ParameterLists
      @platform = platform
      @ruby_ver = ruby_ver
      @stash_dir = stash_dir
      @data_src_dir = data_src_dir
      @data_pre_dir = data_pre_dir
      @data_bin_file = data_bin_file
      @deps_bin_dir = deps_bin_dir

      @tbd = File.join(@data_src_dir, "bin")
      @tgd = File.join(@data_src_dir, "lib", "ruby", "gems", @ruby_ver.api_version)
      @tld = File.join(@data_src_dir, "local")
    end

    def build(stub_dir)
      init
      deploy(stub_dir)
      mkdwarfs
    end

    private

    # Recreate the packaging environment from the stash
    def init
      puts "-- Running init script"

      puts "   ... creating packaging environment at #{@data_src_dir}"
      recreate([@data_src_dir, @data_pre_dir, File.dirname(@data_bin_file)])
      FileUtils.cp_r "#{@stash_dir}/.", @data_src_dir
    end

    def deploy(stub_dir)
      puts "-- Running deploy script"

      check_toolchain_ruby!
      TebakoRuntimeBuilder::BuildHelpers.with_env(deploy_env) do
        install_gem("tebako-runtime")
        deploy_stub(stub_dir)
      end
      TebakoRuntimeBuilder::Stripper.strip(@platform, @data_src_dir)
    end

    # The deploy gem commands run the toolchain ruby from the recreated
    # environment. On msys/mingw, configure forces LOAD_RELATIVE, so the
    # toolchain ruby prepends its exe dir to the compiled-in absolute prefix
    # and every load-path entry comes out doubled (o/sD:/a/.../o/s/lib/...).
    # deploy_env therefore carries the real lib dirs in RUBYLIB, which lands
    # ahead of the compiled entries; this gate probes with that same env so
    # it validates exactly what the deploy pass gets. When stdlib still does
    # not resolve, every gem command fails with a misleading 'cannot load
    # such file -- rubygems/gem_runner' -- fail loud with the evidence instead.
    def check_toolchain_ruby! # rubocop:disable Metrics
      ruby = File.join(@tbd, "ruby#{@platform.exe_suffix}")
      begin
        strings, = Open3.capture2e("strings", ruby)
        puts "   ... compiled-in paths in #{ruby}:"
        puts strings.lines.grep(%r{__tebako_memfs__|o/sD:|tebako-runtime-ruby}).first(12)
      rescue StandardError => e
        puts "   ... strings failed: #{e.message}"
      end

      # Host-side snapshot of the recreated environment: definitive when the
      # toolchain ruby is too broken to even run the probe (or is absent).
      puts "   ... host view of the packaging environment:"
      [@tbd, File.join(@data_src_dir, "lib", "ruby"),
       File.join(@data_src_dir, "lib", "ruby", @ruby_ver.api_version)].each do |d|
        puts "     #{d}: #{Dir.exist?(d) ? Dir.children(d).first(12).join(", ") : "(missing)"}"
      end

      probe = <<~RUBY
        puts $LOAD_PATH
        begin
          puts "rbconfig prefix: \#{RbConfig::CONFIG["prefix"] rescue "n/a"}"
          puts "rbconfig RUBY_EXEC_PREFIX: \#{RbConfig::CONFIG["RUBY_EXEC_PREFIX"] rescue "n/a"}"
        rescue Exception
          nil
        end
        begin
          require "rubygems"
          puts "RUBYGEMS-OK"
        rescue Exception => e
          puts "\#{e.class}: \#{e.message}"
          puts e.backtrace.first(8)
        end
      RUBY
      # --disable-gems: a broken rbconfig otherwise kills the interpreter in
      # gem_prelude before the probe prints anything. capture2e directly (not
      # run_with_capture): a failing probe must report, not raise.
      probe_out, = Open3.capture2e(deploy_env, ruby, "--disable-gems", "-e", probe)
      if probe_out.include?("RUBYGEMS-OK")
        puts "   ... toolchain ruby loads rubygems fine"
        return
      end

      api = @ruby_ver.api_version
      rubygems_rb = File.join(@data_src_dir, "lib", "ruby", api, "rubygems.rb")
      present = File.file?(rubygems_rb)
      listing = Dir.exist?(File.dirname(rubygems_rb)) ? Dir.children(File.dirname(rubygems_rb)).first(20) : []
      puts "   ... toolchain ruby cannot load rubygems (host sees the file present: #{present}):"
      puts probe_out
      puts "   ... #{File.dirname(rubygems_rb)} contains: #{listing.join(", ")}" if listing.any?
      verconf = File.join(@deps_bin_dir, "..", "src", "_ruby_#{@ruby_ver.ruby_version}", "verconf.h")
      if File.file?(verconf)
        puts "   ... verconf.h defines:"
        puts File.readlines(verconf).grep(/RUBY_EXEC_PREFIX|RUBY_LIB_PREFIX/)
      end
      tree_rbconfig = File.join(@deps_bin_dir, "..", "src", "_ruby_#{@ruby_ver.ruby_version}", "rbconfig.rb")
      if File.file?(tree_rbconfig)
        puts "   ... build-tree rbconfig prefix lines (#{tree_rbconfig}):"
        puts File.readlines(tree_rbconfig).grep(/CONFIG\["prefix"\]|CONFIG\["RUBY_EXEC_PREFIX"\]|TOPDIR|DESTDIR =/)
      end
      arch_rbconfig = Dir.glob(File.join(@data_src_dir, "lib", "ruby", api, "*", "rbconfig.rb")).first
      if arch_rbconfig
        puts "   ... installed rbconfig prefix lines (#{arch_rbconfig}):"
        puts File.readlines(arch_rbconfig).grep(/CONFIG\["prefix"\]|CONFIG\["RUBY_EXEC_PREFIX"\]|TOPDIR|DESTDIR =/)
      end
      begin
        strings, = Open3.capture2e("strings", ruby)
        puts "   ... compiled-in paths in #{ruby}:"
        puts strings.lines.grep(%r{/__tebako_memfs__|o/sD:|/lib/ruby}).first(12)
      rescue StandardError
        nil
      end
      raise TebakoRuntimeBuilder::Error.new("toolchain ruby cannot load rubygems from #{@data_src_dir}", 130)
    end

    def deploy_env
      env = {
        "GEM_HOME" => @tgd,
        "GEM_PATH" => @tgd,
        "GEM_SPEC_CACHE" => File.join(@data_src_dir, "spec_cache"),
        "TEBAKO_PASS_THROUGH" => "1"
      }
      env["RUBYLIB"] = toolchain_rubylib if @platform.msys?
      env
    end

    # On msys/mingw the toolchain ruby is always LOAD_RELATIVE (configure
    # forces it) and its compiled-in prefix is absolute, so its load path
    # comes out doubled: <exe dir>D:/a/.../o/s/lib/... Ship the real lib
    # dirs via RUBYLIB -- prepended ahead of the compiled entries -- so
    # rbconfig/rubygems/stdlib resolve. Entries are joined with ";" because
    # the consumer is a win32 ruby. The arch dir is located through the
    # installed rbconfig.rb: lib/ruby/<api> also holds plain stdlib dirs
    # (bigdecimal/, rubygems/, ...), so a directory scan cannot pick it out.
    def toolchain_rubylib # rubocop:disable Metrics
      lib_ruby = File.join(@data_src_dir, "lib", "ruby")
      api = @ruby_ver.api_version
      rbconfig = Dir.glob(File.join(lib_ruby, api, "*", "rbconfig.rb")).first
      arch = rbconfig ? File.basename(File.dirname(rbconfig)) : nil
      roots = %w[site_ruby vendor_ruby].map { |b| File.join(lib_ruby, b, api) } << File.join(lib_ruby, api)
      roots.flat_map { |r| arch ? [r, File.join(r, arch)] : [r] }
           .select { |d| File.directory?(d) }.join(";")
    end

    def install_gem(name, ver = nil)
      puts "   ... installing #{name} gem#{" version #{ver}" if ver}"

      gem_command = File.join(@tbd, "gem#{".cmd" if @platform.msys?}")
      params = [gem_command, "install", name.to_s]
      params += ["-v", ver.to_s] if ver
      params += ["--no-document", "--install-dir", @tgd, "--bindir", @tbd]
      params += ["--platform", "ruby"] if @platform.msys?
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture_v(params)
    end

    # simple_script scenario: the fs root (the generated stub) lands at /local
    def deploy_stub(stub_dir)
      puts "   ... collecting stub.rb from #{stub_dir}"
      FileUtils.mkdir_p(@tld)
      FileUtils.cp_r(File.join(stub_dir, "."), @tld)

      entry = File.join(@tld, "stub.rb")
      puts "   ... target entry point will be at #{File.join(@platform.fs_mount_point, "/local/stub.rb")}"
      return if File.exist?(entry)

      raise TebakoRuntimeBuilder::Error.new("Entry point stub.rb does not exist or is not accessible", 106)
    end

    def mkdwarfs
      puts "-- Running mkdwarfs script"
      FileUtils.chmod("a+x", Dir.glob(File.join(@deps_bin_dir, "mkdwarfs*")))
      params = [File.join(@deps_bin_dir, "mkdwarfs"), "-o", @data_bin_file, "-i", @data_src_dir, "--no-progress"]
      TebakoRuntimeBuilder::BuildHelpers.run_with_capture_v(params)
    end

    def recreate(dirs)
      dirs.each do |dirname|
        FileUtils.rm_rf(dirname, secure: true)
        FileUtils.mkdir_p(dirname)
      end
    end
  end
end
