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
  # The env image's spawn surface (spec 30 §2): the commands the runtime
  # boots as a separate process for a consumer payload's `runtime` edge
  # expose list — rendered as `provides.entrypoints` in the L1 manifest
  # and carried by the image's /bin.
  #
  # The inventory is DERIVED from the layout tree's bin/ — the interpreter
  # install's own command scripts — never a hand-kept list: `bundle`/
  # `bundler`/`racc`/`syntax_suggest`/`rdbg`/`rbs`/`typeprof` presence
  # differs by ruby line, and a declaration without its file is the
  # driver's named refusal ("the env image's declaration lies", exit 65)
  # at every consumer boot. Existence-driven staging keeps the manifest
  # truthful by construction.
  #
  # Two families of shape ride bin/, both byte-identical to what the
  # install produced:
  #   POSIX: bin/<name> — a ruby script. The driver composes
  #          `<interpreter> <args_default…> <in-image path> <user args…>`
  #          (spec 17 §7), so the script is RUN BY THE INTERPRETER and its
  #          shebang never executes: no rewrite is needed or wanted.
  #   MSYS:  two installer families, and the rbinstall wrapper shows up in
  #          BOTH spellings:
  #          * the batch polyglot (head `:""||{`) — as bin/<name>.cmd from
  #            rbinstall's `$cmdtype = 'cmd'` (its `gem`), and as the
  #            extensionless bin/<name> from rubygems' WindowsScript
  #            (its balanced form: the extra `}` after the `%q<…>` makes
  #            it valid ruby as-is). The unbalanced rbinstall form is NOT
  #            ruby until the prolog is skipped, so EVERY polyglot
  #            declaration carries `args_default: ["-x"]` — ruby's own
  #            `-x` skips to the `#!` line, exactly what the wrapper's
  #            `ruby -x` line does when the OS runs it (and it is inert
  #            on the balanced form);
  #          * rubygems' gem-executable install also writes bin/<name>.bat
  #            (the OS launcher). A .bat whose base name is declared is a
  #            launcher TWIN — excluded, because the driver never asks the
  #            OS to launch anything (the published v0.17.1 windows
  #            image's /bin holds minitest, minitest.bat, test-unit,
  #            test-unit.bat).
  #
  # The support-DLL alias channel (SupportDlls, spec 22 §2.1) also stages
  # into bin/ on msys, and the installed interpreter itself sits there
  # until the stripper removes it; both are EXPLICIT exclusions, never a
  # name-shaped guess. Everything else in bin/ must be declared or be a
  # declared entry's launcher twin — the read-back gate (verify!) refuses
  # a stray file by name.
  class Entrypoints # rubocop:disable Metrics/ClassLength -- the class doc is the contract's explanation; code stays one verb per gate
    # The in-image home (the layout tree's bin/ maps to the image's /bin).
    IN_IMAGE_DIR = "/bin"

    # msys command wrappers: Ruby's rbinstall cmdtype='cmd' shape.
    MSYS_SUFFIX = ".cmd"
    MSYS_PROLOG = ':""||{'
    # ruby's -x strips everything before the script's #! line — the .cmd
    # wrapper's own invocation, applied by the interpreter the driver runs.
    MSYS_ARGS_DEFAULT = ["-x"].freeze

    # Fail-closed exit code for the spawn-surface gates (148 is the boot
    # smoke's; the surface gets its own).
    REFUSAL = 150

    # The interpreter binaries the install also puts in bin/: the runtime
    # EXECUTABLE is the interpreter (spec 17 §7), so these are not a spawn
    # surface of their own.
    INTERPRETER_NAMES = %w[ruby rubyw].freeze

    def initialize(platform:, support_dlls: nil)
      @platform = platform
      # Injectable like ImageBuilder's stager: the specs stage from a fake
      # prefix; production resolves the toolchain prefixes.
      @support_dlls = support_dlls || TebakoRuntimeBuilder::SupportDlls.new(host_id: platform.host_id)
    end

    # The declaration's canonical form for comparisons. tfs mkimage
    # re-renders the embedded manifest from the tpkg model, which spells an
    # absent args_default as []; the read-back therefore compares
    # semantics, never bytes.
    def self.canonical(declarations)
      canonical = declarations.map do |decl|
        { "name" => decl["name"], "path" => decl["path"], "args_default" => Array(decl["args_default"]) }
      end
      canonical.sort_by { |decl| decl["name"].to_s }
    end

    # Stage the surface into the layout tree's bin/ (mode normalization
    # included) and answer the declarations. A tree whose bin/ holds no
    # command script is a named build error: the runtime would ship with
    # no spawn surface at all (the issue-291 class, silently).
    def stage(tree_root)
      declarations = declarations(tree_root)
      declarations.each do |decl|
        FileUtils.chmod(0o755, File.join(tree_root, "bin", File.basename(decl["path"])))
      end
      declarations
    end

    # The declarations the tree's ACTUAL bin inventory yields
    # (`[{name, path[, args_default]}]`, name-sorted). This is what the
    # manifest emitter renders; the read-back gate re-reads the packed
    # image against it.
    def declarations(tree_root) # rubocop:disable Metrics/MethodLength -- the two named refusals are the gate
      bin_dir = File.join(tree_root, "bin")
      unless Dir.exist?(bin_dir)
        raise TebakoRuntimeBuilder::Error.new(
          "the layout tree #{tree_root} carries no bin/ directory — the runtime's spawn surface " \
          "(provides.entrypoints) has no inventory to declare", REFUSAL
        )
      end

      staged = script_files(bin_dir)
      if staged.empty?
        raise TebakoRuntimeBuilder::Error.new(
          "the layout tree #{tree_root} holds no command script in bin/ — a ruby runtime that declares " \
          "no spawn surface cannot serve `tebako run ruby:<command>`", REFUSAL
        )
      end
      declarations = staged.map { |path| declaration_for(path) }.sort_by { |decl| decl["name"] }
      check_unique_names!(declarations)
      declarations
    end

    # The read-back gate (both directions), against the PACKED image:
    # every declared path is a file the image holds, and every entry in
    # the image's /bin is either declared or one of the explicit
    # exclusions (the interpreter, the msys support-DLL alias channel, a
    # declared entry's .bat/.cmd launcher twin).
    def verify!(declared:, image_entries:)
      check_unique_names!(declared)
      declared.each { |decl| verify_declared_file!(decl, image_entries) }
      verify_no_stray!(declared, image_entries)
      declared
    end

    private

    def check_unique_names!(declarations)
      repeated = declarations.map { |decl| decl["name"] }.tally.select { |_name, count| count > 1 }.keys
      return if repeated.empty?

      raise TebakoRuntimeBuilder::Error.new(
        "provides.entrypoints repeats the name(s) #{repeated.join(", ")} — a command name is one entry", REFUSAL
      )
    end

    def verify_declared_file!(decl, image_entries)
      path = decl["path"].to_s
      file = File.basename(path)
      return if path == "#{IN_IMAGE_DIR}/#{file}" && image_entries.include?(file)

      raise TebakoRuntimeBuilder::Error.new(
        "declared entrypoint '#{decl["name"]}' resolves to #{path.inspect}, which the packed image's " \
        "#{IN_IMAGE_DIR} does not hold (entries: #{image_entries.join(", ")}) — the env image's declaration lies",
        REFUSAL
      )
    end

    def verify_no_stray!(declared, image_entries) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength -- one rejection predicate, one named refusal
      declared_files = declared.map { |decl| File.basename(decl["path"]) }
      declared_names = declared.map { |decl| decl["name"] }
      stray = image_entries.reject do |entry|
        declared_files.include?(entry) || excluded?(entry) || launcher_twin?(entry, declared_names)
      end
      return if stray.empty?

      raise TebakoRuntimeBuilder::Error.new(
        "the packed image's #{IN_IMAGE_DIR} holds script(s) the manifest does not declare: #{stray.join(", ")} " \
        "(only the interpreter #{interpreter_names.join("/")}, the msys support-DLL alias channel, and a " \
        "declared entry's launcher twin may stay undeclared) — declared: #{declared_files.join(", ")}", REFUSAL
      )
    end

    # The rubygems gem-executable install writes the ruby script as
    # bin/<name> plus an OS launcher bin/<name>.bat (rbinstall's
    # cmdtype='cmd' shape is the .cmd analogue). The driver always runs
    # the interpreter on the declared script, so a launcher whose base
    # name is declared is a twin, not a second command.
    def launcher_twin?(entry, declared_names)
      return false unless @platform.msys?

      match = /\A(?<base>.+)\.(?:bat|cmd)\z/.match(entry)
      match ? declared_names.include?(match[:base]) : false
    end

    def script_files(bin_dir)
      Dir.children(bin_dir).sort.filter_map do |name|
        path = File.join(bin_dir, name)
        next unless File.file?(path)
        next if excluded?(name)

        path if script?(path)
      end
    end

    # A shebang script (every POSIX install script and the platform's plain
    # wrappers) or, on msys, the batch polyglot prolog in either spelling
    # (bin/<name>.cmd from rbinstall, extensionless bin/<name> from
    # rubygems' WindowsScript). A file that is neither is NOT declared;
    # the read-back gate then names it as a stray so a new install shape
    # can never ship silently.
    def script?(path)
      head = File.open(path, "rb") { |file| file.read(64) }.to_s
      return true if head.start_with?("#!")

      @platform.msys? && head.start_with?(MSYS_PROLOG)
    end

    def declaration_for(path)
      file = File.basename(path)
      declaration = { "name" => command_name(file), "path" => "#{IN_IMAGE_DIR}/#{file}" }
      declaration["args_default"] = MSYS_ARGS_DEFAULT.dup if msys_polyglot?(path)
      declaration
    end

    def msys_polyglot?(path)
      return false unless @platform.msys?

      File.open(path, "rb") { |file| file.read(64) }.to_s.start_with?(MSYS_PROLOG)
    end

    def command_name(file)
      @platform.msys? ? file.delete_suffix(MSYS_SUFFIX) : file
    end

    def excluded?(name)
      interpreter_names.include?(name) || alias_names.include?(name)
    end

    def interpreter_names
      @interpreter_names ||= INTERPRETER_NAMES.flat_map do |name|
        [name, "#{name}#{@platform.exe_suffix}"]
      end.uniq
    end

    # The spec 22 §2.1 alias channel's names — an msys contract only;
    # SupportDlls.names_for is fail-closed on unmapped hosts, so the
    # lookup stays inside the guard.
    def alias_names
      @alias_names ||= @platform.msys? ? TebakoRuntimeBuilder::SupportDlls.names_for(@platform.host_id) : []
    end
  end
end
