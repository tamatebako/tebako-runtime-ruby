#!/usr/bin/env bash
# ci/link-unit.sh — build + stage the windows-gnu link unit (the factory
# leg). Everything lives here, not inline in the workflow YAML —
# run-blocks get string-edited and break silently; a script is reviewed
# and shellcheck-able.
set -euo pipefail

# Toolchain rules (hard-won, TODO.v2-1/01):
# - the C++ compiler MUST be the msys ucrt64 one: the ruby link uses it,
#   and the C++ TLS internals differ from the choco mingw's (gcc 14's
#   __emutls_v._ZSt11__once_call is undefined at the gcc 16 ruby link).
# - the msys /usr/bin (setup-msys2's runtime) stays OFF PATH: vcpkg
#   downloads its OWN msys2 for the autotools ports and the two runtimes
#   ABI-clash (openssl's perl eval crash). Git's own /usr/bin carries the
#   coreutils and is PROVEN safe (the Git-bash legs build openssl fine).
export PATH="/d/a/_temp/msys64/ucrt64/bin:/c/Program Files/Git/usr/bin:/c/Users/runneradmin/.cargo/bin:/c/Windows/System32"
mkdir -p .build/link-unit
/d/a/_temp/msys64/ucrt64/bin/ruby.exe tebako-rs/tools/stage_link_unit \
  .build/link-unit --target x86_64-pc-windows-gnu
