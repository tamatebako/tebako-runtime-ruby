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

# Tebako runtime builder (tebako-runtime-ruby)
#
# Build tooling that produces tebako runtime packages from the PRE-PATCHED
# ruby source published by tamatebako/ruby (tfs-ruby-<version>-src.tar.gz
# release assets, verified against the release SHA256SUMS). It replaces the
# gem's 'tebako press -m runtime' build path: the gem's patch layer is not
# carried here -- the source tree arrives patched -- while the consumer-side
# steps the patched tree expects (the @TEBAKO_MLIBS@ / config.status MAINLIBS
# substitutions, the toolchain/final builds, the filesystem image deploy)
# are implemented by this library.
module TebakoRuntimeBuilder
  # Autoloads use absolute paths so the library loads regardless of the
  # caller's $LOAD_PATH (build_pass.rb is invoked bare from CMake)
  autoload :BuildHelpers,   File.expand_path("tebako_runtime_builder/build_helpers", __dir__)
  autoload :BuildPasses,    File.expand_path("tebako_runtime_builder/build_passes", __dir__)
  autoload :Builder,        File.expand_path("tebako_runtime_builder/builder", __dir__)
  autoload :Error,          File.expand_path("tebako_runtime_builder/error", __dir__)
  autoload :ImageBuilder,   File.expand_path("tebako_runtime_builder/image_builder", __dir__)
  autoload :Mlibs,          File.expand_path("tebako_runtime_builder/mlibs", __dir__)
  autoload :Platform,       File.expand_path("tebako_runtime_builder/platform", __dir__)
  autoload :RubyVersion,    File.expand_path("tebako_runtime_builder/ruby_version", __dir__)
  autoload :SourceFetcher,  File.expand_path("tebako_runtime_builder/source_fetcher", __dir__)
  autoload :Stripper,       File.expand_path("tebako_runtime_builder/stripper", __dir__)

  # Bundler/rubygems versions pinned by the gem's scenario manager. For the
  # supported ruby matrix (>= 3.1.6) the gem's deploy gates make the rubygems
  # update and the bundler install no-ops; the constant is kept for the
  # day an older ruby line is reintroduced.
  BUNDLER_VERSION = "2.4.22"
  RUBYGEMS_VERSION = "3.4.22"
end
