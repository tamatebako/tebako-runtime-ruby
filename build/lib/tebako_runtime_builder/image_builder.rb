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
require "yaml"

module TebakoRuntimeBuilder
  # Builds the runtime package filesystem image (fs.bin) from the stashed
  # pristine ruby environment -- the runtime-mode subset of the gem's
  # Packager.init + DeployHelper (simple_script scenario) + Packager.mkdwarfs.
  #
  # The image content is the stashed ruby installation (its bin/ command
  # scripts included — the spec 30 §2 spawn surface), plus /local/stub.rb
  # (the runtime's compiled-in entry point) and the L1 manifest. Spec 22
  # phase M2: the tebako-runtime gem is NO LONGER staged — its require maps
  # ship empty (spec 22 §7) and the Rust driver covers the VFS, so the
  # image carries no tebako-runtime gem at all, and the gem_prelude require
  # patch that loaded it at boot is retired (tamatebako/ruby#65). For the
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

    def initialize(platform, ruby_ver, stash_dir, data_src_dir, data_pre_dir, data_bin_file, deps_bin_dir, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength,Metrics/AbcSize
                   mount_point:, embed: true, mount_root_override: false, support_dlls: nil, scrub_roots: [])
      @platform = platform
      @ruby_ver = ruby_ver
      @stash_dir = stash_dir
      @data_src_dir = data_src_dir
      @data_pre_dir = data_pre_dir
      @data_bin_file = data_bin_file
      @deps_bin_dir = deps_bin_dir
      @mount_point = mount_point
      @embed = embed
      # The build-tree roots deploy_rbconfig scrubs out of the shipped
      # rbconfig's inert flag fields (the CMake project's DEPS dir, binary
      # dir, and source dir — flowed as deploy-pass argv; empty for a bare
      # invocation, which then rewrites the prefix lines only).
      @scrub_roots = scrub_roots
      # The msys support-DLL stager (spec 22 §2.1): injectable so the spec
      # stages from a fake prefix; production resolves the toolchain
      # prefixes (SupportDlls.toolchain_prefixes).
      @support_dlls = support_dlls || TebakoRuntimeBuilder::SupportDlls.new(host_id: @platform.host_id)
      # The source tarball's override capability (the loadpath patch):
      # the layout's grant is emitted only when the source declares it —
      # truthful by construction (spec 17 §1, layout schema_minor 1).
      @mount_root_override = mount_root_override

      @tbd = File.join(@data_src_dir, "bin")
      @tgd = File.join(@data_src_dir, "lib", "ruby", "gems", @ruby_ver.api_version)
      @tld = File.join(@data_src_dir, "local")
      # The preload shim's in-image path once deploy_preload has staged it
      # (nil when absent): deploy_layout declares exactly what was staged —
      # truthful by construction (spec 22 §3, layout schema_minor 2).
      @preload_shim_in_image = nil
    end

    def build(stub_dir)
      init
      backport_bundler_erofs_degradation
      deploy(stub_dir)
      mkdwarfs if @embed
    end

    # The env image's own contract declaration (spec 18 C3/S17), read by
    # the driver post-mount, before ruby init: a missing layout is an
    # era-1 refusal; a mount_root ≠ the exe's compiled-in expectation is
    # exit 78. mount_root FLOWS from the tarball's tebako-mount-root
    # manifest (via -DFS_MOUNT_POINT → the deploy pass) — never re-authored
    # here. Field set per docs/spec/schemas/layout.yaml (snake_case,
    # lists-not-maps): schema/version, era, image_layout, mount_root,
    # interpreter_api_version; the additive mount_root_override grant
    # (schema_minor 1) is emitted by deploy_layout only when the source
    # tarball declares the capability (the loadpath patch — the grant
    # must be true exactly when the interpreter follows TEBAKO_MOUNT_ROOT);
    # the additive preload_shim grant (schema_minor 2) is emitted only
    # when deploy_preload actually staged the shim — the driver refuses
    # (exit 78) a declaration whose file the image does not hold; the
    # additive runtime_dll basename (schema_minor 3) is emitted for MSYS
    # builds only — flowed from RubyVersion#msys_dll_name, the name's
    # single owner (invariant 10); POSIX builds omit the key.
    LAYOUT_DECLARATION = {
      "schema" => "layout",
      "schema_version" => 1,
      "era" => 2,
      "image_layout" => 1
    }.freeze
    LAYOUT_PATH = File.join("lib", "tebako", "layout.yaml").freeze

    def deploy_layout # rubocop:disable Metrics/MethodLength
      path = File.join(@data_src_dir, LAYOUT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      declaration = LAYOUT_DECLARATION.merge(
        "mount_root" => @mount_point,
        "interpreter_api_version" => @ruby_ver.api_version
      )
      declaration["mount_root_override"] = true if @mount_root_override
      declaration["preload_shim"] = @preload_shim_in_image if @preload_shim_in_image
      # The runtime's own PE module basename (MSYS builds only; layout
      # schema_minor 3): the driver exports it as TEBAKO_RUNTIME_DLL into
      # the handoff env, and the tfs PE closure walk excludes a bare
      # import name matching it (spec 22 §2.1 — the OS's basename-reuse
      # rule binds the already-loaded copy). Flowed from
      # RubyVersion#msys_dll_name — the name's single owner; never a
      # second formula. POSIX builds omit the key.
      declaration["runtime_dll"] = @ruby_ver.msys_dll_name(@platform.host_id) if @platform.msys?
      File.write(path, YAML.dump(declaration))
      puts "   ... env image layout declaration: #{path}"
    end

    # The v2 preload shim rides the env image at /lib/tebako/ (the ruby
    # spawn hook materializes it into spawned children — spec 07 §8; its
    # in-image path is declared to the driver via the layout's
    # preload_shim grant, which flows to the hook as TEBAKO_PRELOAD_SHIM —
    # spec 22 §3). It ships inside the link unit (tools/stage_link_unit);
    # its absence only means an older link unit — the exec path degrades
    # to VFS-less children with a note, never a hard failure, and the
    # layout then declares nothing.
    def deploy_preload # rubocop:disable Metrics/MethodLength
      libdir = ENV.fetch("TEBAKO_RUST_LIBDIR", nil)
      return if libdir.nil?

      name = @platform.macos? ? "libtfs_preload.dylib" : "libtfs_preload.so"
      src = File.join(libdir, name)
      unless File.file?(src)
        puts "   ... no #{name} in TEBAKO_RUST_LIBDIR (#{libdir}) — " \
             "spawned children of memfs binaries get no VFS (an older link unit)"
        return
      end
      dest = File.join(@data_src_dir, "lib", "tebako")
      FileUtils.mkdir_p(dest)
      FileUtils.cp(src, File.join(dest, name))
      @preload_shim_in_image = File.join("lib", "tebako", name)
      puts "   ... preload shim: #{File.join(dest, name)}"
    end

    # The msys2 toolchain support DLLs (spec 22 §2.1 — the windows class-L
    # alias channel): payload-resident C extensions compiled by a
    # mingw/ucrt toolchain import the toolchain's support DLLs (ox.so and
    # sqlite3_native.so import libwinpthread-1.dll — the packed-mn#251
    # windows dogfood's 126; the C++ extension class — sassc's libsass —
    # adds libgcc_s_seh-1.dll/libstdc++-6.dll), and the PE closure walk's
    # importer-dir-only rule never reaches them from a gem's dir. The
    # runtime ships the set in bin/ and the manifest declares it in
    # library_aliases: (ImageManifest), so the driver's boot pass
    # materializes the set and leads PATH with it — the OS's own standard
    # search order then binds the import for every payload extension,
    # per-gem-code-free. POSIX legs ship nothing (the alias channel is a
    # windows contract; ELF/Mach-O closures ride rpath/$ORIGIN).
    def deploy_support_dlls
      return unless @platform.msys?

      staged = @support_dlls.stage(@tbd)
      names = staged.map { |path| File.basename(path) }
      puts "   ... support DLLs staged into bin/: #{names.join(", ")} (declared as library_aliases in the manifest)"
    end

    # The env image's spawn surface (spec 30 §2): the interpreter install's
    # own bin/ command scripts STAY in the image (the stripper no longer
    # deletes them) and Entrypoints normalizes their mode and derives the
    # provides.entrypoints declarations from exactly what is there. The
    # manifest emitter (builder.rb) re-derives from this same tree before
    # packing, and the read-back gate re-reads the packed image — three
    # views of one inventory, never a hand-kept list. The msys support
    # DLLs (staged just above) and the interpreter itself are the only
    # names Entrypoints excludes. Public like its sibling deploy passes so
    # the specs drive it against a layout tree directly.
    def deploy_entrypoints
      staged = TebakoRuntimeBuilder::Entrypoints.new(platform: @platform).stage(@data_src_dir)
      puts "   ... spawn surface staged in bin/ (provides.entrypoints): " \
           "#{staged.map { |decl| decl["path"] }.join(", ")}"
      staged
    end

    # The shipped rbconfig.rb (lib/ruby/<api>/<arch>/rbconfig.rb) is written
    # by configure/make against the BUILD host's absolute paths: prefix /
    # RUBY_EXEC_PREFIX name the packaging prefix, and the inert compile-flag
    # fields (RBCONFIG_FLAG_KEYS) carry -I/-L references into the build tree
    # (.build/deps, the CMake binary dir, the repo's build/include). Both
    # leak the build host into the shipped bytes — the reproducible-build
    # diff (E1/E2) — and record paths that exist nowhere at runtime. The
    # scrub: the two prefix lines go to the mount root verbatim (the value
    # rbconfig's own TOPDIR self-anchors to at runtime — its
    # File.dirname(__FILE__).chomp! suffix — so the fallback branch agrees),
    # and the flag fields get every build root replaced by the mount root,
    # longest root first so --prefix=<DATA_SRC_DIR> lands exactly. The
    # result is deterministically inert: the interpreter's load paths are
    # compiled into loadpath.o from the build-TREE rbconfig (the finalize
    # pass), never read from this file, and mkmf ignores nonexistent -I/-L
    # directories (the windows devkit dogfood already proves the shape —
    # the paths it ships today dangle identically). Toolchain paths outside
    # the build tree (homebrew's /opt/homebrew/... — pool-stable per arch)
    # stay: they are provenance, not leakage.
    def deploy_rbconfig # rubocop:disable Metrics/AbcSize -- the scrub's steps, one call per line
      rbconfigs = Dir.glob(File.join(@data_src_dir, "lib", "ruby", "*", "*", "rbconfig.rb"))
      if rbconfigs.empty?
        raise TebakoRuntimeBuilder::Error.new(
          "no rbconfig.rb under #{@data_src_dir}/lib/ruby — the layout tree is incomplete", 131
        )
      end

      roots = ([@data_src_dir] + @scrub_roots).uniq.sort_by { |root| -root.length }
      rbconfigs.each { |path| scrub_rbconfig!(path, roots) }
      puts "   ... rbconfig scrubbed to the mount root #{@mount_point} (#{roots.length} build root(s)): " \
           "#{rbconfigs.map { |path| path.sub("#{@data_src_dir}/", "") }.join(", ")}"
    end

    # The shipped gemspecs' tool-identity leak (tebako-runtime-ruby#384's
    # E3 finding): s.rubygems_version records the rubygems that WROTE the
    # stub — the .gem's packaged-by version when the built ruby's
    # installer generated it (rss-0.3.2: 4.0.2), the host setup-ruby's
    # when the run's path let the host tooling regenerate it (3.4.20 on
    # the twin). The field is a writer fingerprint rubygems never reads
    # at runtime (compatibility consults required_rubygems_version), so
    # every shipped gemspec is normalized to the rubygems the image
    # SHIPS — the built interpreter's own, read from the tree's
    # rubygems.rb (the single owner, never a hardcode).
    # s.installed_by_version already records the shipped rubygems on both
    # paths and stays untouched. Fail-closed like the rbconfig scrub: a
    # tree with no gemspecs (or an unparseable shipped version) is an
    # incomplete layout, never a pass-through.
    def deploy_gemspecs
      version = shipped_rubygems_version
      gemspecs = Dir.glob(File.join(@data_src_dir, "lib", "ruby", "gems", "*", "specifications", "**", "*.gemspec"))
      if gemspecs.empty?
        raise TebakoRuntimeBuilder::Error.new(
          "no *.gemspec under #{@data_src_dir}/lib/ruby/gems — the layout tree is incomplete", 131
        )
      end

      gemspecs.each { |path| normalize_gemspec!(path, version) }
      puts "   ... #{gemspecs.length} gemspec(s) record the shipped rubygems #{version}"
    end

    # The inert compile-flag fields deploy_rbconfig canonicalizes. Read at
    # mkmf time only (gem native-extension builds); never consulted by the
    # interpreter's own load paths.
    RBCONFIG_FLAG_KEYS = %w[configure_args CFLAGS cflags CXXFLAGS cxxflags CPPFLAGS cppflags LDFLAGS DLDFLAGS
                            RUST_LIB].freeze

    private

    # The rubygems the image ships: the VERSION constant of the tree's own
    # lib/ruby/<api>/rubygems.rb — exactly one must exist (the deploy pass
    # runs against one interpreter's layout).
    def shipped_rubygems_version # rubocop:disable Metrics/MethodLength
      candidates = Dir.glob(File.join(@data_src_dir, "lib", "ruby", "*", "rubygems.rb"))
      unless candidates.length == 1
        raise TebakoRuntimeBuilder::Error.new(
          "expected exactly one rubygems.rb under #{@data_src_dir}/lib/ruby (found #{candidates.length}) — " \
          "the layout tree is incomplete", 131
        )
      end

      match = File.read(candidates.first).match(/^\s*VERSION = "([0-9][0-9A-Za-z.-]*)"/)
      unless match
        raise TebakoRuntimeBuilder::Error.new(
          "#{candidates.first} declares no Gem::VERSION — cannot name the shipped rubygems", 131
        )
      end
      match[1]
    end

    # Rewrite just the version literal of the writer-fingerprint line,
    # preserving the line's shape (the generated stubs' ".freeze suffix
    # and indentation); a spec already recording the shipped version is
    # left byte-identical.
    def normalize_gemspec!(path, version)
      contents = File.read(path)
      replaced = contents.gsub(/^(\s*\w+\.rubygems_version = )"[^"]*"/, "\\1\"#{version}\"")
      File.write(path, replaced) unless replaced == contents
    end

    def scrub_rbconfig!(path, roots) # rubocop:disable Metrics/MethodLength
      contents = File.read(path)
      {
        'CONFIG["prefix"]' => "  CONFIG[\"prefix\"] = (TOPDIR || DESTDIR + \"#{@mount_point}\")",
        'CONFIG["RUBY_EXEC_PREFIX"]' => "  CONFIG[\"RUBY_EXEC_PREFIX\"] = \"#{@mount_point}\""
      }.each do |key, line|
        next if contents.gsub!(/^ *#{Regexp.escape(key)} = .*$/, line)

        raise TebakoRuntimeBuilder::Error.new("#{path} carries no #{key} line to rewrite", 130)
      end
      contents.gsub!(/^ *CONFIG\["(?:#{RBCONFIG_FLAG_KEYS.join("|")})"\] = .*$/) do |line|
        roots.reduce(line) { |scrubbed, root| scrubbed.gsub(root, @mount_point) }
      end
      File.write(path, contents)
    end

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

    def deploy(stub_dir) # rubocop:disable Metrics/MethodLength -- the deploy's ordered stages, one call per line
      puts "-- Running deploy script"

      check_toolchain_ruby!
      deploy_stub(stub_dir)
      deploy_ca_bundle
      deploy_support_dlls
      deploy_entrypoints
      deploy_preload
      deploy_layout
      deploy_rbconfig
      deploy_gemspecs
      TebakoRuntimeBuilder::Stripper.strip(@platform, @data_src_dir)
    end

    # The windows runtime ships the pinned CA bundle (CaBundle) into the
    # image at ssl/cert.pem: vcpkg's static openssl was built with the CI
    # runner's openssldir, so without it the default verify paths find
    # nothing on a user machine and the first HTTPS fails. The image
    # manifest (ImageManifest) declares /ssl/cert.pem in its class-R
    # materialize list and the exe's boot shim (build/CMakeLists.txt's
    # TEBAKO_MAIN_SHIM) points SSL_CERT_FILE at the driver's materialized
    # host copy — libcrypto's native CRT IO never sees the VFS. POSIX
    # legs ship nothing — vcpkg's unix openssl builds with
    # --openssldir=/etc/ssl, which the host supplies.
    def deploy_ca_bundle
      return unless @platform.msys?

      dest = TebakoRuntimeBuilder::CaBundle.new(cache_dir: File.join(@data_pre_dir, "downloads"))
                                           .deploy(@data_src_dir)
      puts "   ... CA bundle deployed to #{dest.sub("#{@data_src_dir}/", "")} (class-R materialized per the manifest)"
    end

    # The image ships the recreated environment's toolchain ruby; this gate
    # probes it before anything ships. On msys/mingw, configure forces
    # LOAD_RELATIVE, so the toolchain ruby prepends its exe dir to the
    # compiled-in absolute prefix and every load-path entry comes out
    # doubled (o/sD:/a/.../o/s/lib/...). deploy_env therefore carries the
    # real lib dirs in RUBYLIB, which lands ahead of the compiled entries;
    # this gate probes with that same env. When stdlib still does not
    # resolve, the image's rubygems is broken with a misleading 'cannot
    # load such file -- rubygems/gem_runner' at RUN time -- fail loud with
    # the evidence instead.
    def check_toolchain_ruby! # rubocop:disable Metrics
      ruby = File.join(@tbd, "ruby#{@platform.exe_suffix}")
      begin
        strings, = Open3.capture2e("strings", ruby)
        puts "   ... compiled-in paths in #{ruby}:"
        puts strings.lines.grep(%r{__tfs__|o/sD:|tebako-runtime-ruby}).first(12)
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
        puts strings.lines.grep(%r{/__tfs__|o/sD:|/lib/ruby}).first(12)
      rescue StandardError
        nil
      end
      raise TebakoRuntimeBuilder::Error.new("toolchain ruby cannot load rubygems from #{@data_src_dir}", 130)
    end

    # The probe env for check_toolchain_ruby!: GEM_HOME/GEM_PATH aim the
    # rubygems require at the recreated environment's gem home (the tree
    # the image ships). Nothing gem-install-shaped runs in the deploy pass
    # anymore (spec 22 phase M2), so the install-only plumbing
    # (GEM_SPEC_CACHE, TEBAKO_PASS_THROUGH) is gone.
    def deploy_env
      env = {
        "GEM_HOME" => @tgd,
        "GEM_PATH" => @tgd
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
