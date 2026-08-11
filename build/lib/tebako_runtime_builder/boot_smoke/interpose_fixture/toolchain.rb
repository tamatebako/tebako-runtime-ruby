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
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
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
    class InterposeFixture
      # The spec-22 fixture's build-time toolchain resolution: the leg's
      # stashed ruby headers and an image pack tool. Both resolve from an
      # explicit env override first, then the container-leg copy-out
      # (.build/smoke-{headers,tools}), then the host-leg build prefix —
      # a miss is a named error listing the paths tried.
      class Toolchain
        def initialize(headers_dir: nil, image_tool: nil)
          @headers_dir = headers_dir
          @image_tool = image_tool
        end

        # A directory holding ruby.h plus one arch dir
        # (<hdr>/<arch>/ruby/config.h).
        def headers_dir
          @headers_dir ||= resolve_headers
        end

        def arch_dir
          @arch_dir ||= arch_dir_in(headers_dir) || missing_arch_dir!
        end

        def missing_arch_dir!
          raise TebakoRuntimeBuilder::Error.new(
            "no <arch>/ruby/config.h under the stashed ruby headers #{headers_dir}", 145
          )
        end

        def image_tool
          @image_tool ||= resolve_image_tool
        end

        private

        def resolve_headers
          candidates = header_candidates
          found = candidates.find { |dir| File.file?(File.join(dir, "ruby.h")) && arch_dir_in(dir) }
          found || raise(TebakoRuntimeBuilder::Error.new(
                           "no stashed ruby headers for the spec-22 boot-smoke fixture (tried: " \
                           "#{candidates.join(", ")}; set TEBAKO_SMOKE_RUBY_HEADERS to a directory holding ruby.h)", 145
                         ))
        end

        def header_candidates
          explicit = @headers_dir || ENV.fetch("TEBAKO_SMOKE_RUBY_HEADERS", nil)
          return [explicit] if explicit

          [File.join(".build", "smoke-headers", "ruby-*"),
           File.join(".build", "deps", "stash_*", "include", "ruby-*"),
           File.join(".build", "deps", "src", "ruby-*", "include")]
            .flat_map { |pattern| Dir.glob(pattern) }.select { |dir| File.directory?(dir) }
        end

        def arch_dir_in(dir)
          Dir.children(dir).map { |child| File.join(dir, child) }
             .find { |path| File.file?(File.join(path, "ruby", "config.h")) }
        end

        def resolve_image_tool
          requested = ENV.fetch("TEBAKO_SMOKE_TFS", nil) || ENV.fetch("TEBAKO_TFS", nil)
          return which!(requested) if requested

          [".build/smoke-tools/mkdwarfs", ".build/deps/bin/mkdwarfs"].each do |tool|
            return File.expand_path(tool) if File.executable?(tool)
          end
          which!("tfs")
        end

        def which!(tool)
          return tool if File.executable?(tool) && !File.directory?(tool)

          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
            path = File.join(dir, tool)
            return path if File.executable?(path) && !File.directory?(path)
          end
          raise TebakoRuntimeBuilder::Error.new(
            "no image tool for the spec-22 boot-smoke fixture (#{tool} does not resolve; " \
            "set TEBAKO_SMOKE_TFS or TEBAKO_TFS)", 145
          )
        end
      end
    end
  end
end
