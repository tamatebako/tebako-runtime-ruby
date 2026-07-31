#!/usr/bin/env bash
# ci/link-unit.sh — build + stage the windows-gnu link unit (the factory
# leg). Everything lives here, not inline in the workflow YAML —
# run-blocks get string-edited and break silently; a script is reviewed
# and shellcheck-able.
set -euo pipefail

export PATH="/c/Users/runneradmin/.cargo/bin:$PATH"
mkdir -p .build/link-unit
/d/a/_temp/msys64/ucrt64/bin/ruby.exe tebako-rs/tools/stage_link_unit \
  .build/link-unit --target x86_64-pc-windows-gnu
