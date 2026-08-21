#!/usr/bin/env bash
# ci/prepare-gnu-runtime-container.sh — run INSIDE the gnu CI container
# (tebako-ubuntu-20.04) before tools/build_runtime: install gcc-11/g++-11
# from the toolchain-r ppa (tebako-runtime-ruby#117).
#
# Why: the published gnu link unit (contract.yml link_unit_release) is
# built on tebako's focal floor with ppa gcc-11 — Botan 3 hard-requires
# gcc >= 11 — so its C++ objects reference libstdc++ symbols up to
# GLIBCXX_3.4.29 (std::__throw_bad_array_new_length, the ref-qualified
# stringstream::str()). The runtime exe link drives clang-18 and absorbs
# libstdc++ STATICALLY (-l:libstdc++.a in the link line), and clang
# resolves that archive from the NEWEST gcc under /usr/lib/gcc/<triplet>/
# — gcc-10 (3.4.28) before this script, so the v0.2.0 unit's miniruby
# link died with 302 undefined references. The pre-pin source build never
# hit this: its objects were compiled in-leg with clang-19 against
# libstdc++-10 headers, so nothing referenced past 3.4.28.
#
# Static absorption means the newer archive adds NO runtime floor — the
# shipped exe keeps no NEEDED libstdc++.so. The compiler is deliberately
# NOT switched (no update-alternatives): ruby still builds with clang-18;
# only the absorbed archive's provenance moves. Mirrors the ppa pattern
# in tebako's ci/gnu-floor-build.sh (key + deb line, no API call — the
# add-apt-repository launchpad lookup has hung on arm64 runners).
set -euo pipefail

# Idempotent: a re-run in the same container finds the toolchain present.
if compgen -G "/usr/lib/gcc/*-linux-gnu/11" > /dev/null; then
  echo "prepare-gnu-runtime-container: gcc-11 already present — skipping"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Key 1E9377A2BA9EF27F ("Launchpad Toolchain builds") is the ppa's
# published signer; the ppa ships gcc-11/g++-11 for focal amd64 AND arm64.
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x1E9377A2BA9EF27F" \
  | gpg --dearmor -o /usr/share/keyrings/toolchainr.gpg
echo "deb [signed-by=/usr/share/keyrings/toolchainr.gpg] http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu focal main" \
  > /etc/apt/sources.list.d/toolchainr.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc-11 g++-11
g++-11 --version | head -1

# Evidence for the leg log: the link driver must now resolve the
# statically absorbed archive to gcc-11's (3.4.29) copy.
if command -v clang-18 > /dev/null; then
  echo "prepare-gnu-runtime-container: clang-18 resolves libstdc++.a -> $(clang-18 -print-file-name=libstdc++.a)"
fi
