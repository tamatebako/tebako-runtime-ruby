#!/usr/bin/env bash
# ci/prepare-rust-toolchain.sh — run INSIDE the gnu/musl CI containers
# (tebako-ubuntu-20.04 / tebako-alpine-3.17) before tools/build_runtime,
# and on the macOS build legs (HOME-local homes — the macOS runners'
# /opt is root-owned): install the ecosystem-pinned Rust toolchain so the
# ruby configure sees rustc on PATH and auto-enables YJIT (ruby >= 3.2,
# x86_64/aarch64 linux/darwin targets — upstream configure.ac's
# YJIT_TARGET_OK arms; configure probes plain `rustc` on PATH,
# AC_CHECK_PROG, and silently configures YJIT out when it misses — the
# 0.16.19 linux legs). The macOS legs pinned the runner image's floating
# rustup default before this (the runner generation decided the bytes);
# they now pin the same ecosystem version the containers do.
#
# Why in-leg: the retired v1 build images carry NO rust toolchain at all.
# The pinned toolchain otherwise ships with the tpkg-builder images
# (tebako-ci-containers tpkg-builder/tools/install-rust.sh); the runtime
# factory's legs move onto those with TODO.v2-1/13 — this script is the
# bridge until then, and a no-op beyond it (a baked-in pin takes the skip
# path below). Default layout mirrors install-rust.sh (/opt/rustup +
# /opt/cargo, minimal profile) so the two container generations agree
# byte-for-byte on where the toolchain lives; a caller pre-setting
# RUSTUP_HOME/CARGO_HOME (the macOS legs) redirects the install there.
#
# The version is NOT a literal here (SSOT): the workflow flows the
# ecosystem pin — tamatebako/tebako .github/workflows/release.yml's
# env RUST_VERSION, the owner tebako-ci-containers' pins.env names — into
# the leg as RUST_VERSION. Unset/empty is a named refusal, never a
# float to rustup's default.
set -euo pipefail

pin="${RUST_VERSION:?prepare-rust-toolchain: RUST_VERSION is unset — the compute job flows it from the tebako product release.yml pin}"

# Callers with no root (the macOS runners' /opt) seat the homes; the
# container default mirrors install-rust.sh byte-for-byte.
export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}" CARGO_HOME="${CARGO_HOME:-/opt/cargo}"

version_of() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  "$bin" --version 2>/dev/null | cut -d' ' -f2
}

# Idempotent: a re-run in the same container, a container generation
# with the pin baked in (tpkg-builder leads PATH with /opt/cargo/bin),
# or a macOS runner whose rustup default already IS the pin finds the
# toolchain present.
if [ "$(version_of rustc || true)" = "$pin" ] || [ "$(version_of "$CARGO_HOME/bin/rustc" || true)" = "$pin" ]; then
  echo "prepare-rust-toolchain: rustc $pin already present — skipping"
  exit 0
fi

curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "$pin"
rm -f /tmp/rustup-init.sh

# The version must BE the pin — drift fails closed, the same gate
# install-rust.sh applies to the baked toolchain (exit 65).
[ "$(version_of "$CARGO_HOME/bin/rustc" || true)" = "$pin" ] || {
  echo "prepare-rust-toolchain: rustc version drifted from the pin ($pin)" >&2
  exit 65
}
echo "prepare-rust-toolchain: $("$CARGO_HOME/bin/rustc" --version) ready at $CARGO_HOME/bin — the ruby build leads PATH with it"
