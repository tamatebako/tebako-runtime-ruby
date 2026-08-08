#!/usr/bin/env bash
# ci/link-unit-download.sh — consume the PUBLISHED link unit (a
# tamatebako/tebako release asset) instead of rebuilding the native
# closure from source. The closure depends on the triplet and the
# product release only — never on the ruby version — so a pin hit turns
# every leg's staging into a ~30 s download.
#
# The pin is contract.yml's link_unit_release (empty = build from
# source): it names the product release whose driver the factory needs.
# A platform with no published unit (gnu, until the product ships a
# floor build) misses — a miss selects the source build and is never an
# error. A checksum MISMATCH is a hard error, never a silent fallback:
# bytes that disagree with the release API's digest are a supply-chain
# event, not a cache miss.
#
# Usage: ci/link-unit-download.sh <os> <arch> <release>
#   GITHUB_OUTPUT gets hit=true|false; on a hit the verified unit sits
#   at .build/link-unit in the exact shape the build legs assert on.

set -euo pipefail

os=${1:?usage: link-unit-download.sh <os> <arch> <release>}
arch=${2:?}
release=${3:-}

hit() { echo "hit=$1" >> "$GITHUB_OUTPUT"; }

# The product release's platform ids (release.yml's matrix.platform).
case "$os/$arch" in
  linux-gnu/x86_64)  pid=linux-gnu-x86_64 ;;
  linux-gnu/arm64)   pid=linux-gnu-arm64 ;;
  linux-musl/x86_64) pid=linux-musl-x86_64 ;;
  linux-musl/arm64)  pid=linux-musl-arm64 ;;
  macos/x86_64)      pid=macos-x86_64 ;;
  macos/arm64)       pid=macos-arm64 ;;
  windows/x86_64)    pid=x86_64-windows-gnu ;;
  *) echo "::error::no link-unit platform id for $os/$arch"; exit 64 ;;
esac

if [ -z "$release" ]; then
  echo "link-unit pin empty — building from source"
  hit false
  exit 0
fi

ver=${release#v}
asset="link-unit-${ver}-${pid}.tar.gz"
digest=$(gh api "repos/tamatebako/tebako/releases/tags/$release" \
  --jq ".assets[] | select(.name == \"$asset\") | .digest")
if [ -z "$digest" ]; then
  echo "no published $asset on $release — building from source"
  hit false
  exit 0
fi

mkdir -p .build/dl
gh release download "$release" --repo tamatebako/tebako --pattern "$asset" --dir .build/dl --clobber
expected=${digest#sha256:}
actual=$(openssl dgst -sha256 -r ".build/dl/$asset" | cut -d' ' -f1)
if [ "$actual" != "$expected" ]; then
  echo "::error::$asset sha256 mismatch: release API declares $expected, the download is $actual — refusing the unit (never a silent source fallback on a supply-chain mismatch)"
  exit 65
fi

mkdir -p .build/link-unit
tar -xzf ".build/dl/$asset" -C .build/link-unit --strip-components=1
rm -rf .build/dl

# The completeness contract — the same files the build legs assert on.
for f in libtebako_driver.a libtfs.a include/tebako/fs/c_api.h; do
  test -s ".build/link-unit/$f" || { echo "::error::downloaded unit lacks $f"; exit 65; }
done
compgen -G ".build/link-unit/closure/*.a" > /dev/null || { echo "::error::downloaded unit carries no closure/*.a"; exit 65; }
echo "published link unit $asset verified (sha256 $expected)"
hit true
