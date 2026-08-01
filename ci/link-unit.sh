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
export PATH="/d/a/_temp/msys64/ucrt64/bin:/c/Program Files/Git/usr/bin:/c/Program Files/Git/cmd:/c/Users/runneradmin/.cargo/bin:/c/Windows/System32"

# CRT probe (the __imp___msvcrt_assert link failure, 2026-07-31): rustc's
# -nodefaultlibs late-lib recipe adds -lmsvcrt but no -lucrt/-lucrtbase;
# which import lib actually carries _assert vs __msvcrt_assert decides the
# fix. Print the facts BEFORE the hour-long build, every run (free).
echo "=== CRT import-lib probe (ucrt64 gcc 16.1) ==="
for a in libmsvcrt.a libucrt.a libucrtbase.a libmsvcrt-os.a libmingwex.a; do
  p="$(x86_64-w64-mingw32-gcc -print-file-name="$a")"
  [ -f "$p" ] || { echo "$a: NOT FOUND"; continue; }
  echo "--- $a ($p)"
  nm -g --defined-only "$p" 2>/dev/null \
    | grep -E "__imp_+(_)?(msvcrt_)?assert$" | sort -u || echo "  (no assert imports)"
done

mkdir -p .build/link-unit
/d/a/_temp/msys64/ucrt64/bin/ruby.exe tebako-rs/tools/stage_link_unit \
  .build/link-unit --target x86_64-pc-windows-gnu
