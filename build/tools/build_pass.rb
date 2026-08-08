#!/usr/bin/env ruby
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

# Build pass runner: the single-step interface invoked by the CMake project
# (build/CMakeLists.txt) during the ExternalProject/packaged_filesystem
# build. See TebakoRuntimeBuilder::BuildPasses for what each pass does.

require_relative "../lib/tebako_runtime_builder"

begin
  unless ARGV.length.positive?
    raise TebakoRuntimeBuilder::Error, "build_pass needs at least 1 argument (command), none has been provided."
  end

  case ARGV[0]
  when "prepare"
    #       ARGV[1] -- OSTYPE
    #       ARGV[2] -- RUBY_SOURCE_DIR
    #       ARGV[3] -- DEPS_LIB_DIR
    #       ARGV[4] -- RUBY_VER
    #       ARGV[5] -- FS_MOUNT_POINT
    #       ARGV[6] -- C compiler
    unless ARGV.length == 7
      raise TebakoRuntimeBuilder::Error,
            "build_pass prepare command expects 7 arguments, #{ARGV.length} has been provided."
    end
    TebakoRuntimeBuilder::BuildPasses.prepare(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6])
  when "postconfigure"
    #       ARGV[1] -- OSTYPE
    #       ARGV[2] -- RUBY_SOURCE_DIR
    #       ARGV[3] -- DEPS_LIB_DIR
    #       ARGV[4] -- RUBY_VER
    unless ARGV.length == 5
      raise TebakoRuntimeBuilder::Error,
            "build_pass postconfigure command expects 5 arguments, #{ARGV.length} has been provided."
    end
    TebakoRuntimeBuilder::BuildPasses.postconfigure(ARGV[1], ARGV[2], ARGV[3], ARGV[4])
  when "toolchain"
    #       ARGV[1] -- RUBY_SOURCE_DIR
    #       ARGV[2] -- DATA_SRC_DIR
    #       ARGV[3] -- RUBY_STASH_DIR
    #       ARGV[4] -- DEPS_LIB_DIR
    unless ARGV.length == 5
      raise TebakoRuntimeBuilder::Error,
            "build_pass toolchain command expects 5 arguments, #{ARGV.length} has been provided."
    end
    TebakoRuntimeBuilder::BuildPasses.toolchain(ARGV[1], ARGV[2], ARGV[3], ARGV[4])
  when "deploy"
    #       ARGV[1] -- RUBY_VER
    #       ARGV[2] -- RUBY_STASH_DIR
    #       ARGV[3] -- DATA_SRC_DIR
    #       ARGV[4] -- DATA_PRE_DIR
    #       ARGV[5] -- DATA_BIN_FILE
    #       ARGV[6] -- STUB_DIR
    #       ARGV[7] -- DEPS_BIN_DIR
    #       ARGV[8] -- EMBED ("1": also write the incbin fs.bin image;
    #                  "0": image era, the standalone .tfs is the only image)
    #       ARGV[9] -- FS_MOUNT_POINT (the exe's compiled-in root, flowed
    #                  from the tarball manifest; written into the image's
    #                  /lib/tebako/layout.yaml — spec 18 C3)
    #       ARGV[10] -- MOUNT_ROOT_OVERRIDE ("1": the tarball carries the
    #                  loadpath patch — the layout gains the
    #                  mount_root_override grant, spec 17 §1)
    unless ARGV.length == 11
      raise TebakoRuntimeBuilder::Error,
            "build_pass deploy command expects 11 arguments, #{ARGV.length} has been provided."
    end
    TebakoRuntimeBuilder::BuildPasses.deploy(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7],
                                             mount_point: ARGV[9], embed: ARGV[8] == "1",
                                             mount_root_override: ARGV[10] == "1")
  when "overlay"
    #       ARGV[1] -- PASS2_TARBALL
    #       ARGV[2] -- PASS2_SHA256
    #       ARGV[3] -- RUBY_SOURCE_DIR
    #       ARGV[4] -- WORK_DIR
    unless ARGV.length == 5
      raise TebakoRuntimeBuilder::Error,
            "build_pass overlay command expects 5 arguments, #{ARGV.length} has been provided."
    end
    TebakoRuntimeBuilder::BuildPasses.overlay(ARGV[1], ARGV[2], ARGV[3], ARGV[4])
  when "finalize"
    #       ARGV[1] -- OSTYPE
    #       ARGV[2] -- RUBY_SOURCE_DIR
    #       ARGV[3] -- OUTPUT
    #       ARGV[4] -- RUBY_VER
    #       ARGV[5] -- DEPS_LIB_DIR
    #       ARGV[6] -- patchelf path (optional, "none" to skip)
    unless [6, 7].include?(ARGV.length)
      raise TebakoRuntimeBuilder::Error,
            "build_pass finalize command expects 6 or 7 arguments, #{ARGV.length} has been provided."
    end
    patchelf = ARGV[6].nil? || ARGV[6] == "none" ? nil : ARGV[6]
    TebakoRuntimeBuilder::BuildPasses.finalize(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], patchelf)
  else
    raise TebakoRuntimeBuilder::Error, "build_pass cannot process #{ARGV[0]} command"
  end
rescue TebakoRuntimeBuilder::Error => e
  puts "build_pass failed: #{e.message} [#{e.error_code}]"
  exit(e.error_code)
end
exit(0)
