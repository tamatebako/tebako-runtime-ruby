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

module TebakoRuntimeBuilder
  class BootSmoke
    # Parsed result of one boot-smoke boot: the probe's
    #   BOOT-SMOKE <check> <ok|fail|unsupported> <detail>
    # lines keyed by check name, plus the process outcome. The probe only
    # senses; this model and the spec class judge. A boot that never
    # reported (mount failure, crash, timeout) is !booted? and fails every
    # example of its scenario with the stderr/context intact.
    class Run
      LINE_RE = /\ABOOT-SMOKE (?<name>\S+) (?<state>ok|fail|unsupported)(?:\s+(?<detail>.*))?\z/

      def initialize(scenario:, stdout:, stderr:, status:)
        @scenario = scenario
        @stdout = stdout
        @stderr = stderr
        @status = status
        @checks = parse(stdout)
      end

      attr_reader :scenario, :stdout, :stderr

      def booted?
        !@status.nil? && @status.exitstatus.to_i.zero? && !@checks.empty?
      end

      def exitstatus
        @status&.exitstatus
      end

      def state(name)
        check = @checks[name]
        check ? check[0] : nil
      end

      def detail(name)
        check = @checks[name]
        check ? check[1] : nil
      end

      def failure_summary
        lines = ["scenario '#{@scenario}' did not boot (exit #{exitstatus || "timeout"})"]
        # Both streams ALWAYS report (a silent exit needs its absence said
        # out loud — the v2.8.28-unit boot failure showed nothing on
        # either), then the driver journal's tail (the boot's own record
        # of how far it got) when one exists.
        lines << "stderr: #{@stderr.to_s.strip.empty? ? "(empty)" : @stderr.strip[0, 500]}"
        lines << "stdout: #{@stdout.to_s.strip.empty? ? "(empty)" : @stdout.strip[0, 500]}"
        journal = journal_tail
        lines << "driver journal (tail): #{journal}" if journal
        lines.join("\n")
      end

      private

      # The driver's store journal (journal.log) tails the boot — the
      # named step the boot died inside is its last lines. The smoke's
      # scrubbed env keeps the default home, so the journal sits at the
      # machine store's standard path.
      def journal_tail
        log = File.join(Dir.home, ".tebako", "journal.log")
        return nil unless File.file?(log)

        tail = File.readlines(log).last(25).join.strip
        tail.empty? ? nil : tail
      rescue StandardError
        nil
      end

      def parse(stdout)
        checks = {}
        stdout.to_s.each_line do |line|
          match = LINE_RE.match(line.strip)
          checks[match[:name]] = [match[:state], match[:detail].to_s] if match
        end
        checks
      end
    end
  end
end
