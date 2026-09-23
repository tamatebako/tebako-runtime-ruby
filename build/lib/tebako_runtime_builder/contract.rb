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

require "yaml"

module TebakoRuntimeBuilder
  # contract.yml — the factory's pin SSOT (schema/contract.schema.yml).
  # The build entry points read their defaults from here; the release
  # pipeline and the matrix planner have their own readers, this class is
  # the builder's one. Mirrored from the python factory's Contract.
  class Contract
    PATH = File.expand_path("../../../contract.yml", __dir__).freeze

    def initialize(path = PATH)
      @path = path
      @data = YAML.load_file(path)
      return if @data.is_a?(Hash)

      raise TebakoRuntimeBuilder::Error.new("#{path} is not a YAML mapping (schema: schema/contract.schema.yml)", 64)
    end

    # The tamatebako/tebako release pin whose published tfs CLI the image
    # step consumes (TfsTool). May be EMPTY: the legs then build the driver
    # from source and no published CLI exists to pin — the builder refuses
    # the default fetch by name and asks for --tfs instead (an empty pin is
    # a config state, never a silent skip).
    def link_unit_release
      @data.fetch("link_unit_release", "").to_s
    end
  end
end
