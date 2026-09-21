#!/usr/bin/env bash
# ci/tfs-download.sh — fetch the native tfs CLI (a tamatebako/tebako
# release asset) for legs that must pack the env image in-process.
#
# windows/arm64 is the forcing case: its link unit is limnifs-only (the
# product's arm64 unit ships no dwarfs closure — upstream dwarfs-t's
# milestone), so the env image must be written by `tfs mkimage --format
# limnifs` with a NATIVE arm64 binary. The deps mkdwarfs is x64 dwarfs-t:
# wrong arch under Prism (SIGSEGV, run 35608648436) and a format the
# arm64 driver cannot mount. ImagePackager refuses that fallback by
# name; this script is how the leg satisfies the requirement.
#
# Same discipline as ci/link-unit-download.sh: digest-verified against
# the release API; a mismatch or a missing asset is a hard error, never
# a silent fallback.
#
# Usage: ci/tfs-download.sh <os> <arch> <release>
#   On success the verified binary sits at .build/tfs/tfs[.exe] and the
#   last stdout line is its path (drive-letter form on windows).

set -euo pipefail

os=${1:?usage: tfs-download.sh <os> <arch> <release>}
arch=${2:?}
release=${3:?usage: tfs-download.sh <os> <arch> <release> — pass the contract.yml link_unit_release pin}

# The product release binary platform ids (NOT the link-unit pids —
# the CLI assets spell windows with the ucrt segment).
case "$os/$arch" in
  windows/x86_64)  pid=windows-ucrt64;    exe=.exe ;;
  windows/arm64)   pid=windows-ucrt-arm64; exe=.exe ;;
  macos/x86_64)    pid=macos-x86_64;      exe= ;;
  macos/arm64)     pid=macos-arm64;       exe= ;;
  linux-gnu/x86_64)  pid=linux-gnu-x86_64;  exe= ;;
  linux-gnu/arm64)   pid=linux-gnu-arm64;   exe= ;;
  linux-musl/x86_64) pid=linux-musl-x86_64; exe= ;;
  linux-musl/arm64)  pid=linux-musl-arm64;  exe= ;;
  *) echo "::error::no tfs asset id for $os/$arch"; exit 64 ;;
esac

ver=${release#v}
asset="tfs-${ver}-${pid}${exe}"

command -v gh >/dev/null || { echo "::error::gh CLI not on PATH — cannot fetch $asset"; exit 64; }

digest=$(gh api "repos/tamatebako/tebako/releases/tags/$release" \
  --jq ".assets[] | select(.name == \"$asset\") | .digest")
if [ -z "$digest" ]; then
  echo "::error::no published $asset on $release — the in-process image packer needs it"
  exit 65
fi

mkdir -p .build/tfs
gh release download "$release" --repo tamatebako/tebako --pattern "$asset" --dir .build/tfs --clobber

expected=${digest#sha256:}
actual=$(openssl dgst -sha256 -r ".build/tfs/$asset" | cut -d' ' -f1)
if [ "$actual" != "$expected" ]; then
  echo "::error::$asset sha256 mismatch: release API declares $expected, the download is $actual — refusing the tool (never a silent fallback on a supply-chain mismatch)"
  exit 65
fi

mv ".build/tfs/$asset" ".build/tfs/tfs${exe}"
chmod +x ".build/tfs/tfs${exe}" 2>/dev/null || true

# Smoke the binary BEFORE the build leg trusts it: a binary that cannot
# run here (wrong arch, emulation gap) must fail this step, not an hour
# into the ruby build.
".build/tfs/tfs${exe}" --version >/dev/null

# Drive-letter form on windows (the invoking ruby is an msys build — its
# File.file? reads C:/... but /c/... works too; the spawned exe path is
# safest in the form CreateProcess understands).
if [ -n "${MSYSTEM:-}" ]; then
  cd .build/tfs && pwd -W | tr '\\' '/' | sed "s|\$|/tfs${exe}|"
else
  echo "$(pwd)/.build/tfs/tfs${exe}"
fi
