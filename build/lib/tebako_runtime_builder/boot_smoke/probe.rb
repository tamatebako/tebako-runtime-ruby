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
  MOUNT_POINT = ENV.fetch("TEBAKO_BOOT_MOUNT_POINT", "/__tebako_memfs__").freeze
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
    report("load_path_default_gem") do
      require "fileutils"
      defined?(FileUtils::VERSION) ? FileUtils::VERSION : "loaded"
    end
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

  def self.run
    case ENV.fetch("TEBAKO_BOOT_PROBE", "")
    when "boot" then boot
    when "stat" then stat
    when "io" then io
    when "bundler" then bundler
    when "locks" then locks
    else exit 2
    end
    exit 0
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
    results.map { |name, (size, read)| "#{name}:size=#{size},read=#{read}" }.join(" ")
  end

  def self.stdlib_file_read_size(api, name)
    path = File.join(MOUNT_POINT, "lib", "ruby", api, name)
    [File.size(path), File.binread(path).bytesize]
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
end

$stdout.sync = true
BootSmokeProbe.run
