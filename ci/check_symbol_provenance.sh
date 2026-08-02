#!/usr/bin/env bash
# ci/check_symbol_provenance.sh — the S51 nm provenance assert (spec 18
# C4): the built runtime exe's tebako_main must resolve from the fs TU
# (the CMake-built libtebako-fs.a), never from the toolchain stub
# (build/resources/toolchain_stub.c, archived as deps/lib/libtebako-fs.a
# so the toolchain ruby links, then removed by the finalize pass). The
# stub's tebako_main returns 0 without mounting anything — a shadowed
# link yields a "runtime" that boots as a plain interpreter and fails
# nothing until the first memfs access (the stub-shadow class).
#
# Evidence hierarchy (every check prints its nm/objdump output):
#   1. exe-side, authoritative: nm shows tebako_main defined AND the fs
#      TU's companion data symbol tebako::fs_mount_point defined. The
#      stub is C and carries no C++ namespace symbols; in a shadowed
#      link nothing else pulls the fs TU, so the symbol's absence is
#      the shadow's fingerprint. (v1 link: tebako-main.cpp.o references
#      it; v2 link: the shim lives in the fs TU itself.)
#   2. exe-side, v2 (Rust) link: the disassembly of tebako_main must
#      reference tebako_driver_boot — the fs TU shim forwards the exe's
#      own compiled-in root to the Rust driver; the stub references
#      nothing.
#   3. archive-side (when the build prefix is host-visible): the stub
#      archive must be GONE (its survival is the shadow precondition)
#      and the real archive's nm -A shows tebako_main defined in the
#      expected member (rust: tebako-fs.cpp.o; v1: tebako-main.cpp.o) —
#      the archive-member provenance.
#
# The driver flavor is read off the exe (tebako_driver_boot defined ⇔
# the v2 Rust link), never trusted from the caller.
#
# Windows legs assert on the BUILD-TREE exe (.build/deps/src/_ruby_*/
# ruby.exe): strip -S on PE removes the COFF symbol table, so the
# shipped .exe carries no nm-readable symbols; the build-tree exe is
# the same link before stripping. POSIX legs assert on the shipped exe
# (strip -S keeps the symbol table on ELF and Mach-O).
#
# Usage:
#   check_symbol_provenance.sh --exe PATH [--driver auto|rust|cpp]
#                              [--stub-archive PATH] [--real-archive PATH]
set -euo pipefail

EXE=""
DRIVER="auto"
STUB_ARCHIVE=""
REAL_ARCHIVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exe)          EXE="$2"; shift 2 ;;
    --driver)       DRIVER="$2"; shift 2 ;;
    --stub-archive) STUB_ARCHIVE="$2"; shift 2 ;;
    --real-archive) REAL_ARCHIVE="$2"; shift 2 ;;
    *) echo "check_symbol_provenance: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$EXE" ] || { echo "check_symbol_provenance: --exe PATH is required" >&2; exit 2; }
[ -s "$EXE" ] || { echo "::error::provenance: exe $EXE is missing or empty"; exit 1; }

failures=0
fail() { echo "::error::provenance: $*"; failures=$((failures + 1)); }
note() { echo "provenance: $*"; }

# --- 1. tebako_main is a defined text symbol in the exe ---------------
main_lines="$(nm "$EXE" 2>/dev/null | grep -E '[TtWw] _?tebako_main$' || true)"
if [ -z "$main_lines" ]; then
  fail "tebako_main is not a defined text symbol in $EXE — the runtime entry hook is missing"
  echo "nm evidence (all tebako-ish symbols):"; nm "$EXE" 2>&1 | grep -i tebako || echo "(none — stripped beyond -S?)"
else
  note "tebako_main defined in the exe: $main_lines"
fi

# --- 2. the fs TU fingerprint is in the exe ----------------------------
fingerprint="$(nm "$EXE" 2>/dev/null | grep '_ZN6tebako14fs_mount_pointE' | grep -v ' U ' || true)"
if [ -z "$fingerprint" ]; then
  fail "tebako::fs_mount_point absent from $EXE — the fs TU was never linked; tebako_main came from the toolchain stub (stub-shadow)"
  echo "nm evidence:"; nm "$EXE" 2>&1 | grep -E '_?tebako_main$|_?tebako_mount_point$|fs_mount_point' || true
else
  note "fs TU fingerprint present in the exe: $fingerprint"
fi

# --- driver flavor, read off the exe -----------------------------------
if [ "$DRIVER" = "auto" ]; then
  # capture-then-test (never nm | grep -q: pipefail turns grep's early
  # exit into a SIGPIPEd nm and a false negative)
  boot_lines="$(nm "$EXE" 2>/dev/null | grep -E '[TtWw] _?tebako_driver_boot$' || true)"
  if [ -n "$boot_lines" ]; then
    DRIVER=rust
  else
    DRIVER=cpp
  fi
fi
note "driver flavor (read off the exe): $DRIVER"

# --- 3. v2 link: tebako_main forwards to tebako_driver_boot ------------
if [ "$DRIVER" = "rust" ]; then
  # Output-driven tool selection: an objdump that cannot honor
  # --disassemble=<sym> (e.g. the macOS shim prints the header only)
  # yields no function body and the llvm-objdump spelling is tried next.
  # Neither producing the body is a failure — never a silently skipped
  # provenance check.
  dis=""
  if command -v objdump >/dev/null 2>&1; then
    dis="$(objdump -d --disassemble=tebako_main "$EXE" 2>/dev/null || true)"
  fi
  if ! printf '%s\n' "$dis" | grep -q 'tebako_main>:' && command -v llvm-objdump >/dev/null 2>&1; then
    dis="$(llvm-objdump -d --disassemble-symbols=tebako_main "$EXE" 2>/dev/null || true)"
  fi
  if ! printf '%s\n' "$dis" | grep -q 'tebako_main>:' && command -v otool >/dev/null 2>&1; then
    # darwin last resort: /usr/bin/objdump is a deprecation shim and
    # llvm-objdump sits behind xcrun (off PATH) — otool (cctools) is
    # always there. Mach-O labels are bare `_symbol:` lines; take the
    # body up to the next label (a tail call has no ret).
    dis="$(otool -tV "$EXE" 2>/dev/null | awk '/^_tebako_main:/{f=1; next} f && /^[_a-zA-Z].*:$/{exit} f{print}' || true)"
  fi
  if [ -z "$dis" ]; then
    fail "no objdump could disassemble tebako_main in $EXE — the v2 provenance check cannot run"
  elif printf '%s\n' "$dis" | grep -q tebako_driver_boot; then
    note "tebako_main forwards to tebako_driver_boot (the fs TU shim)"
  else
    fail "tebako_main in $EXE does not reference tebako_driver_boot — the toolchain stub's pass-through, not the fs TU shim"
    echo "disassembly evidence:"; printf '%s\n' "$dis"
  fi
fi

# --- 4. the toolchain stub archive must not survive the build ----------
if [ -n "$STUB_ARCHIVE" ]; then
  if [ -e "$STUB_ARCHIVE" ]; then
    fail "toolchain stub archive survived the build: $STUB_ARCHIVE — it shadows -ltebako-fs ahead of the real archive"
    echo "nm evidence (the stub archive's tebako_main):"; nm -A --defined-only "$STUB_ARCHIVE" 2>&1 | grep tebako_main || true
  else
    note "toolchain stub archive absent: $STUB_ARCHIVE"
  fi
fi

# --- 5. the real archive's member provenance ---------------------------
if [ -n "$REAL_ARCHIVE" ]; then
  member_name='tebako-main.cpp.o'
  [ "$DRIVER" = "rust" ] && member_name='tebako-fs.cpp.o'
  if [ ! -f "$REAL_ARCHIVE" ]; then
    fail "the real fs archive is missing: $REAL_ARCHIVE"
  else
    prov="$(nm -A --defined-only "$REAL_ARCHIVE" 2>/dev/null | grep -E '[TtWw] _?tebako_main$' || true)"
    if printf '%s\n' "$prov" | grep -qF "$member_name"; then
      note "archive member provenance: $prov"
    else
      fail "tebako_main in $REAL_ARCHIVE does not resolve from member $member_name"
      echo "nm -A evidence:"; printf '%s\n' "$prov"
      nm -A --defined-only "$REAL_ARCHIVE" 2>&1 | grep tebako || true
    fi
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "::error::provenance: $failures check(s) failed — the stub-shadow class (spec 18 S51)"
  exit 1
fi
note "tebako_main resolves from the fs TU — provenance OK ($EXE, driver $DRIVER)"
