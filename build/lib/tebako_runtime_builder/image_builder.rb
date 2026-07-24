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
  class ImageBuilder
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

      TebakoRuntimeBuilder::BuildHelpers.with_env(deploy_env) do
        install_gem("tebako-runtime")
        deploy_stub(stub_dir)
      end
      TebakoRuntimeBuilder::Stripper.strip(@platform, @data_src_dir)
    end

    def deploy_env
      {
        "GEM_HOME" => @tgd,
        "GEM_PATH" => @tgd,
        "GEM_SPEC_CACHE" => File.join(@data_src_dir, "spec_cache"),
        "TEBAKO_PASS_THROUGH" => "1"
      }
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
