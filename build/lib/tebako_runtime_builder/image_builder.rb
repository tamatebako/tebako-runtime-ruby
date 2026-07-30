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
  #
  # The mkdwarfs step (fs.bin, the image incbin embeds) runs only for the
  # v1 embedded shape (embed: true). Image-era builds (the default, item
  # 30b) skip it: the executable carries zero-size incbin symbols and the
  # standalone <runtime>.tfs the ImagePackager writes from the same layout
  # tree is the runtime's only filesystem image.
  #
  # For the ruby 3.4 line the layout tree's bundled bundler is repaired on
  # the way in: see backport_bundler_erofs_degradation.
  class ImageBuilder # rubocop:disable Metrics/ClassLength
    # Anchor for the bundler EROFS backport below: the SystemCallError
    # catch-all of SharedHelpers.filesystem_access, indented exactly as in
    # the bundled file (unique there).
    BUNDLER_RESCUE_ANCHOR = "    rescue SystemCallError => e\n"

    # The backported branch. Upstream (bundler >= 2.6.6) raises
    # ReadOnlyFileSystemError < PermissionError here; the backport raises
    # the PermissionError the bundled bundler already defines -- the class
    # ProcessLock rescues.
    BUNDLER_EROFS_BRANCH =
      "    rescue Errno::EROFS\n      " \
      "raise PermissionError.new(path, action) # tebako backport (bundler < 2.6.6)\n"

    def initialize(platform, ruby_ver, stash_dir, data_src_dir, data_pre_dir, data_bin_file, deps_bin_dir, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   embed: true)
      @platform = platform
      @ruby_ver = ruby_ver
      @stash_dir = stash_dir
      @data_src_dir = data_src_dir
      @data_pre_dir = data_pre_dir
      @data_bin_file = data_bin_file
      @deps_bin_dir = deps_bin_dir
      @embed = embed

      @tbd = File.join(@data_src_dir, "bin")
      @tgd = File.join(@data_src_dir, "lib", "ruby", "gems", @ruby_ver.api_version)
      @tld = File.join(@data_src_dir, "local")
    end

    def build(stub_dir)
      init
      backport_bundler_erofs_degradation
      deploy(stub_dir)
      mkdwarfs if @embed
    end

    private

    # Recreate the packaging environment from the stash
    def init
      puts "-- Running init script"

      puts "   ... creating packaging environment at #{@data_src_dir}"
      recreate([@data_src_dir, @data_pre_dir, File.dirname(@data_bin_file)])
      FileUtils.cp_r "#{@stash_dir}/.", @data_src_dir
    end

    # bundler 2.6.0-2.6.5 (the 2.6.2 ruby 3.4.0-3.4.2 bundles) moved
    # ProcessLock under SharedHelpers.filesystem_access and narrowed its
    # rescue to PermissionError, but that filesystem_access shape carries no
    # Errno::EROFS branch: the read-only memfs answers the lockfile create
    # with EROFS (the io.c tfs_open contract), which lands in the
    # SystemCallError catch-all and escapes ProcessLock as
    # GenericSystemCallError. bundler <= 2.5 rescued EROFS in ProcessLock
    # itself; bundler >= 2.6.6 / 4.x maps it to ReadOnlyFileSystemError <
    # PermissionError (the upstream fix this backports, reduced to the
    # PermissionError the bundled bundler already carries). With the
    # mapping, ProcessLock degrades to no-lock on the memfs like every
    # supported line. Content-gated both ways: a layout tree whose bundler
    # already tolerates EROFS (or predates the 2.6 shape and its anchor)
    # passes through untouched, and the gate restricts the repair to the
    # affected ruby line.
    def backport_bundler_erofs_degradation
      return unless @ruby_ver.ruby34only?

      bundler_helpers_candidates.each do |helpers|
        next unless File.file?(helpers)

        content = File.read(helpers)
        next if content.include?("rescue Errno::EROFS") || !content.include?(BUNDLER_RESCUE_ANCHOR)

        puts "   ... backporting the EROFS process-lock degradation into #{helpers.sub("#{@data_src_dir}/", "")}"
        File.write(helpers, content.sub(BUNDLER_RESCUE_ANCHOR, BUNDLER_EROFS_BRANCH + BUNDLER_RESCUE_ANCHOR))
      end
    end

    # Candidate locations: the default-gem install lands bundler's lib files
    # in the stdlib dir (lib/ruby/<api>/bundler/, the gems/ dir keeps only
    # exe/); the gems/ glob covers layouts that hold the full gem there.
    def bundler_helpers_candidates
      candidates = [File.join(@data_src_dir, "lib", "ruby", @ruby_ver.api_version, "bundler", "shared_helpers.rb")]
      candidates += Dir.glob(File.join(@tgd, "gems", "bundler-*/lib/bundler/shared_helpers.rb"))
      candidates.uniq.sort
    end

    def deploy(stub_dir)
      puts "-- Running deploy script"

      check_toolchain_ruby!
      TebakoRuntimeBuilder::BuildHelpers.with_env(deploy_env) do
        install_gem("tebako-runtime")
        deploy_stub(stub_dir)
      end
      deploy_preload
      TebakoRuntimeBuilder::Stripper.strip(@platform, @data_src_dir)
    end

    # The v2 preload shim rides the env image at /lib/tebako/ (the ruby
    # spawn hook materializes it into spawned children — spec 07 §8). It
    # ships inside the link unit (tools/stage_link_unit); its absence
    # only means an older link unit — the exec path degrades to
    # VFS-less children with a note, never a hard failure.
    def deploy_preload
      libdir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)
      return if libdir.nil?

      name = @platform.macos? ? "libtfs_preload.dylib" : "libtfs_preload.so"
      src = File.join(libdir, name)
      unless File.file?(src)
        puts "   ... no #{name} in TEBAKO_RUST_LIBDIR (#{libdir}) — spawned children of memfs binaries get no VFS (an older link unit)"
        return
      end
      dest = File.join(@data_src_dir, "lib", "tebako")
      FileUtils.mkdir_p(dest)
      FileUtils.cp(src, File.join(dest, name))
      puts "   ... preload shim: #{File.join(dest, name)}"
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
