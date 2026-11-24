#!/bin/sh
# ci/record-toolchain.sh — emit the build leg's toolchain identity as one
# compact JSON object on stdout. The leg feeds it to tools/build_runtime as
# TEBAKO_BUILD_TOOLCHAIN_JSON, which folds it verbatim into the
# .contract.yaml sidecar's built_from.toolchain (the tebako-release uploader
# then carries it into the release shard) — the provenance the
# reproducible-build contract audits against: two runs of the same tree must
# have resolved the SAME toolchain, and a diff names what moved.
#
# Every value resolves HERE, beside the toolchain it names — the container
# legs run this INSIDE the image (never a host-side guess at what the
# container holds), the macOS/windows legs on the leg's own runner. A field
# that cannot resolve is omitted, never guessed.
#
# Fields:
#   os                  — uname -srm (the build kernel; provenance only —
#                         nothing from it enters the artifact anymore)
#   cc / cxx / ld       — first --version lines of the default toolchain
#   rustc               — the pinned rustc's --version line (the YJIT legs)
#   cpu / hw_model      — the build host's silicon (darwin legs: sysctl
#                         machdep.cpu.brand_string / hw.model). Codegen
#                         provenance, not decoration: Apple clang's
#                         aarch64-darwin default -target-cpu is the HOST
#                         chip, and the hosted macOS fleet's silicon is
#                         the one toolchain input no other field records
#                         (tebako-runtime-ruby#390's E5 audit gap — the
#                         twin runs' job APIs named only the "macos-15"
#                         label).
#   container           — the pinned name:tag@sha256 ref (container legs;
#                         TEBAKO_TC_CONTAINER flows it from the host — the
#                         digest the preflight asserted against contract.yml)
#   runner              — the GitHub runner image ($ImageOS-$ImageVersion)
#   brew                — the Brewfile formulas' resolved versions (macOS)
#   msys2_pacman_sha256 — the digest of the full `pacman -Q` manifest
#                         (windows legs; the manifest itself prints to the
#                         leg log. MSYS2 serves no snapshot mirror, so the
#                         rolling resolution is RECORDED, never pinned —
#                         the named windows deviation)
set -eu

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

json="{"
sep=""
add() { # add <key> <value> — omitted when the value is empty
  [ -n "$2" ] || return 0
  json="$json$sep\"$1\":\"$(esc "$2")\""
  sep=","
}

first_line() { # first_line <cmd> [args...] — empty when the command misses
  command -v "$1" >/dev/null 2>&1 || return 0
  "$@" 2>/dev/null | head -1 || true
}

add os "$(uname -srm)"
add cc "$(first_line "${CC:-cc}" --version)"
add cxx "$(first_line "${CXX:-c++}" --version)"
add ld "$(first_line ld --version)"
add rustc "$(first_line rustc --version)"
if [ "$(uname -s)" = "Darwin" ]; then
  add cpu "$(first_line sysctl -n machdep.cpu.brand_string)"
  add hw_model "$(first_line sysctl -n hw.model)"
fi
add container "${TEBAKO_TC_CONTAINER:-}"
[ -n "${ImageOS:-}" ] && add runner "${ImageOS}-${ImageVersion:-unknown}"
if command -v brew >/dev/null 2>&1 && [ -f Brewfile ]; then
  formulas="$(brew bundle list --formula --file=Brewfile 2>/dev/null || true)"
  if [ -n "$formulas" ]; then
    # shellcheck disable=SC2086 # the formula list word-splits by design
    add brew "$(brew list --versions $formulas 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  fi
fi
if command -v pacman >/dev/null 2>&1; then
  add msys2_pacman_sha256 "$(pacman -Q | sha256sum | cut -d' ' -f1)"
fi
printf '%s}\n' "$json"
