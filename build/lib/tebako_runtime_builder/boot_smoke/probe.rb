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
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

# In-runtime boot-smoke probe (roadmap item 19). This file is NOT part of
# the build library's constant graph: TebakoRuntimeBuilder::BootSmoke
# preloads it into the runtime under test via RUBYOPT (-r), so every check
# runs inside the packaged memfs context before the compiled-in entry stub
# dispatches. It is deliberately a top-level module, standalone (image
# stdlib/default gems only), and exits the interpreter when done.
#
# The probe only SENSES: each check prints exactly one
#   BOOT-SMOKE <check> <ok|fail|unsupported> <detail>
# line on stdout; the host-side BootSmoke::Run model and the spec class
# judge. A check raises on a violated invariant rather than reporting a
# false-looking ok, so "fail" always names the drifted syscall.
module BootSmokeProbe
  MOUNT_POINT = ENV.fetch("TEBAKO_BOOT_MOUNT_POINT", "/__tfs__").freeze
  STUB = File.join(MOUNT_POINT, "local", "stub.rb").freeze

  def self.report(name)
    detail = yield
    puts "BOOT-SMOKE #{name} ok #{detail}"
  rescue NotImplementedError => e
    # Platform does not expose the facility at all (e.g. btime on the
    # linux statx path -- the memfs carries no birthtime by design)
    puts "BOOT-SMOKE #{name} unsupported #{e.message}"
  rescue Exception => e # rubocop:disable Lint/RescueException
    # Deliberate: a check must never kill the probe before it reports
    puts "BOOT-SMOKE #{name} fail #{e.class}: #{e.message} || #{context_line}"
  end

  # One-line in-runtime diagnostic context appended to a failed check's
  # detail (the host side surfaces it via Run#detail): which rubygems
  # actually loaded, what is already activated/loaded, and where
  # requires look.
  def self.context_line
    gems = defined?(Gem) && Gem.respond_to?(:version) ? Gem.version : "undef"
    specs = defined?(Gem) && Gem.respond_to?(:loaded_specs) ? Gem.loaded_specs.keys.sort.join(",") : "n/a"
    feats = $LOADED_FEATURES.grep(/rubygems|bundler|tmpdir|csv|tebako/).join(",")
    "ctx{gem_version=#{gems} loaded_specs=#{specs} feats=#{feats} load_path=#{$LOAD_PATH.join(";")}}"
  end

  def self.boot
    report("ruby_version") { RUBY_VERSION }
    report("contract_version") { contract_version_check }
  end

  def self.stat
    report("stat") { stat_check }
    report("lstat") { lstat_check }
    report("fstat") { fstat_check }
    report("birthtime") { birthtime_check }
    report("exist") { exist_check }
    report("readable") { readable_check }
    report("dir_iteration") { dir_iteration_check }
  end

  def self.io
    report("read_image_file") { File.open(STUB) { |io| io.readline.strip } }
    report("read_stdlib_files") { read_stdlib_check }
    report("load_path_default_gem") { load_path_default_gem_check }
    report("copy_stream") { copy_stream_check }
    report("layout_yaml") { layout_yaml_check }
  end

  def self.bundler
    report("gem_home") { gem_home_check }
    report("require_bundler") do
      require "bundler"
      Bundler::VERSION
    end
    report("process_lock") { process_lock_check }
    report("default_gems_load") do
      require "csv"
      defined?(CSV::VERSION) ? CSV::VERSION : "loaded"
    end
  end

  def self.locks
    report("flock_writable") { flock_check }
  end

  def self.native_ext
    report("require_openssl") { openssl_check }
    report("load_native_extension") { native_extension_check }
  end

  def self.run
    case ENV.fetch("TEBAKO_BOOT_PROBE", "")
    when "boot" then boot
    when "stat" then stat
    when "io" then io
    when "bundler" then bundler
    when "locks" then locks
    when "native_ext" then native_ext
    else exit 2
    end
    exit 0
  end

  # The runtime is authoritative for the bootstrap<->runtime contract it
  # speaks (roadmap 45): the fs-TU's tebako_main shim exports the linked
  # driver's compiled-in tebako_driver_contract_version() into the
  # environment at boot. The release pipeline emits contract.yml's value
  # into the manifest entry -- the spec pins the two to agreement, so a
  # stale link unit carrying an older driver can never ship under a
  # mis-declared contract_version (the corrupt-manifest incident class).
  # An unset variable also exposes a shadowed tebako_main link (the S51
  # provenance class): the toolchain stub exports nothing.
  def self.contract_version_check
    ENV.fetch("TEBAKO_CONTRACT_VERSION") do
      raise "TEBAKO_CONTRACT_VERSION is unset inside the runtime -- the fs-TU tebako_main shim did not " \
            "export it (a pre-roadmap-45 factory build, or a shadowed tebako_main link)"
    end
  end

  # A native extension must load on EVERY leg (owner directive): openssl
  # rides the runtime's static extension set on POSIX, so the require
  # binds there today; on windows the same require is the issue-#40
  # canary -- it binds against the shipped ruby DLL once the shared
  # build lands. The probe only senses (ok/fail); the spec compares the
  # state against the leg's recorded expectation
  # (TEBAKO_SMOKE_EXPECT_OPENSSL) and fails on any drift, either way.
  def self.openssl_check
    require "openssl"
    OpenSSL::OPENSSL_VERSION
  end

  def self.stat_check
    stat = File.stat(STUB)
    unless stat.file? && stat.size.positive?
      raise "#{STUB} is not a file (file?=#{stat.file?} size=#{stat.size} mode=#{stat.mode.to_s(8)})"
    end

    "size=#{stat.size}"
  end

  # Byte-level read of representative stdlib files in the image: File.size
  # (the stat surface) must equal the bytes a read actually returns. The
  # 4.0.x msys runtime loaded lib/ruby/4.0.0/{rubygems,bundler,tmpdir}.rb
  # as EMPTY files (the requires returned, nothing was defined) while
  # other files read fine -- the require path alone cannot tell the two
  # apart, so the check reads the files outright.
  STDLIB_READ_FILES = %w[rubygems.rb bundler.rb tmpdir.rb fileutils.rb].freeze

  def self.read_stdlib_check
    api = "#{RUBY_VERSION.split(".")[0, 2].join(".")}.0"
    results = STDLIB_READ_FILES.to_h { |name| [name, stdlib_file_read_size(api, name)] }
    bad = results.reject { |_name, (size, read)| size.positive? && size == read }
    raise "image stdlib reads return wrong content: #{stdlib_read_detail(results)}" unless bad.empty?

    stdlib_read_detail(results)
  end

  def self.stdlib_read_detail(results)
    results.map { |name, (size, read, head)| "#{name}:size=#{size},read=#{read},head=#{head}" }.join(" ")
  end

  def self.stdlib_file_read_size(api, name)
    path = File.join(MOUNT_POINT, "lib", "ruby", api, name)
    [File.size(path), File.binread(path).bytesize, File.binread(path, 16).unpack1("H*")]
  end

  # The spec-17 smoke form's core assertion: the interpreter EXECUTES
  # code from the mount. The require resolves through $LOAD_PATH entries
  # inside the memfs and runs the file it finds there -- the detail is
  # the resolved feature path, which the spec asserts lives under the
  # mount point (a host-resolved stdlib would prove nothing about the
  # image).
  def self.load_path_default_gem_check
    require "fileutils"
    feature = $LOADED_FEATURES.find { |loaded| loaded.end_with?("/fileutils.rb") }
    raise "fileutils required but no fileutils.rb in $LOADED_FEATURES" unless feature

    feature
  end

  # The deploy direction (image -> host): ruby's io.c zero-copy path
  # (copy_file_range on linux, fcopyfile on macOS) must degrade to plain
  # read/write on a memfs fd. The unguarded EBADF escapes only in a real
  # run -- the 0.16.2 deploy-time incident; the zero-copy guard landed in
  # tamatebako/ruby v0.2.15. A byte-exact copy is the only acceptable
  # outcome.
  def self.copy_stream_check # rubocop:disable Metrics/MethodLength
    require "tmpdir"
    Dir.mktmpdir do |dir|
      dst = File.join(dir, "copy-stream.out")
      IO.copy_stream(STUB, dst)
      expected = File.binread(STUB)
      copied = File.binread(dst)
      unless copied.bytesize == expected.bytesize
        raise "copy_stream copied #{copied.bytesize} of #{expected.bytesize} bytes"
      end
      raise "copy_stream content mismatch (deploy would ship corrupt files)" unless copied == expected

      "bytes=#{copied.bytesize}"
    end
  end

  # The env image's own contract declaration (spec 18 C3/S17): the image
  # must carry /lib/tebako/layout.yaml naming the mount root the exe
  # compiled in (TEBAKO_BOOT_MOUNT_POINT flows the same expectation
  # host-side), the era-2 contract set, and the interpreter api line. A
  # pre-era image (no layout) or a mismatched pair fails the check by
  # name — the factory-side surface of the driver's exit-78 verdict.
  def self.layout_yaml_check # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    require "yaml"
    path = File.join(MOUNT_POINT, "lib", "tebako", "layout.yaml")
    raise "missing #{path} in the env image (pre-era image — rebuild with the current factory)" unless File.file?(path)

    layout = YAML.safe_load_file(path)
    api = "#{RUBY_VERSION.split(".")[0, 2].join(".")}.0"
    expected = {
      "schema" => "layout",
      "schema_version" => 1,
      "era" => 2,
      "image_layout" => 1,
      "mount_root" => MOUNT_POINT,
      "interpreter_api_version" => api
    }
    mismatched = expected.reject { |key, value| layout.is_a?(Hash) && layout[key] == value }
    unless mismatched.empty?
      raise "#{path} declares #{layout.inspect} — expected #{mismatched.inspect} (mismatched exe↔image pair)"
    end

    "era=2 mount_root=#{layout["mount_root"]} api=#{api}"
  end

  def self.lstat_check
    "size=#{File.lstat(STUB).size}"
  end

  def self.fstat_check
    File.open(STUB) { |io| "size=#{io.stat.size}" }
  end

  def self.birthtime_check
    File.stat(STUB).birthtime.to_s
  end

  def self.exist_check
    raise "File.exist? false for #{STUB}" unless File.exist?(STUB)

    missing = File.join(MOUNT_POINT, "local", "no-such-file.rb")
    raise "File.exist? true for missing #{missing}" if File.exist?(missing)

    "true"
  end

  def self.readable_check
    raise "File.readable? false for #{STUB}" unless File.readable?(STUB)

    "true"
  end

  def self.dir_iteration_check
    children = Dir.children(MOUNT_POINT)
    unless children.include?("lib") && children.include?("local")
      raise "mount root misses lib/local: #{children.sort.join(",")}"
    end

    children.sort.join(",")
  end

  # Gem.home was removed in rubygems 3.5; Gem.dir is the successor. Both
  # must resolve to the image gem home (the image-era Gem.home gap had it
  # unset/host-pointed and broke bundler inside packaged apps).
  def self.gem_home_check
    require "rubygems"
    home = defined?(Gem.home) ? Gem.home : Gem.dir
    raise "gem home is not defined" if home.nil? || home.empty?
    raise "gem home #{home} is not a directory" unless File.directory?(home)

    home
  end

  # Bundler's ProcessLock targets the bundle path -- Gem.dir, inside the
  # read-only memfs. Every supported bundler degrades to "no lock" there
  # (<= 2.5 rescues EROFS & co. directly, 4.x wraps the failure as
  # PermissionError; 2.6.0-2.6.5 lost the EROFS degradation upstream, so
  # the factory backports it into 3.4-line images -- see
  # ImageBuilder#backport_bundler_erofs_degradation); what must never
  # escape is the drift-class errno (the unshimmed statx/fcopyfile EBADF
  # the image-era boot gap died with -- it matched none of the rescues and
  # aborted the boot).
  def self.process_lock_check
    require "bundler"
    unless defined?(Bundler::ProcessLock)
      raise NotImplementedError, "bundler #{Bundler::VERSION} carries no ProcessLock"
    end

    Bundler::ProcessLock.lock(Gem.dir) { "no-lock-on-memfs" }
  end

  # The memfs is read-only; the writable path is a host temporary file, so
  # POSIX fcntl semantics pass through to the host fd (the memfs no-op shim
  # of item 18 covers memfs fds, never this host one).
  def self.flock_check
    require "tmpdir"
    Dir.mktmpdir do |dir|
      File.open(File.join(dir, "boot-smoke.lock"), "w") do |io|
        raise "flock(LOCK_EX) failed" unless io.flock(File::LOCK_EX)
        raise "flock(LOCK_UN) failed" unless io.flock(File::LOCK_UN)
      end
    end
    "ex/un"
  end

  # The image's own dynamic native extension (issue #40, msys): racc's
  # cparse.so rides the env image as a PE module importing the ruby DLL.
  # The require extracts the .so to a host path (tebako_fs_dlmap2file) and
  # LoadLibrary binds its imports against x64-ucrt-ruby<ABI>.dll found
  # next to the running exe -- the same binding path precompiled gems
  # take. A pure-ruby fallback would mask an unbindable .so, so the check
  # asserts the .so itself landed in $LOADED_FEATURES. Off-msys the
  # runtime's own exts are static and there is nothing to bind.
  def self.native_extension_check # rubocop:disable Metrics/MethodLength
    host_os = RbConfig::CONFIG["host_os"]
    unless host_os =~ /mswin|mingw/
      raise NotImplementedError, "dynamic extension binding is a windows-runtime check (host_os=#{host_os})"
    end

    require "racc/cparse"
    feature = $LOADED_FEATURES.find { |loaded| loaded.end_with?("cparse.so") }
    unless feature
      raise "racc/cparse required but no cparse.so in $LOADED_FEATURES " \
            "(the pure-ruby fallback masked an unbindable extension)"
    end

    feature
  end
end

$stdout.sync = true
BootSmokeProbe.run
