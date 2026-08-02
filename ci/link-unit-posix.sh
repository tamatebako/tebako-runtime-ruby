#!/bin/sh
# ci/link-unit-posix.sh — stage the v2 Rust link unit for the POSIX legs
# (linux-gnu, linux-musl, macos). The windows-gnu leg has its own
# ci/link-unit.sh (the ucrt64 toolchain rules do not transfer).
#
# Ownership boundary (spec 14, SSOT): the link unit itself is OWNED by the
# tebako product repo — tools/stage_link_unit builds tebako-driver + tfs
# (scoped by tebako-arscope) and harvests the native closure. This script
# owns only the factory-leg glue: toolchain provisioning, vcpkg bootstrap,
# the serialized sqfs pre-install, and the container wraps. Never copy
# staging logic out of tebako-rs.
#
# Usage (from build-runtime-packages.yml):
#   sh ci/link-unit-posix.sh <os> <arch>        host entry
#   sh ci/link-unit-posix.sh --inner <flavor> <arch>   container re-exec
#
# The libc invariants are kept BY CONSTRUCTION, never by luck:
#   linux-gnu  — staged INSIDE ubuntu:20.04 (glibc 2.31, the shipping floor;
#                a host-staged unit would import >2.31 symbol versions the
#                20.04 build container's link then refuses — spec 19 §3 and
#                tebako-rs ci/gnu-floor-build.sh). No vcpkg baseline restore:
#                the published baselines are 24.04-built and would re-import
#                2.39 objects through the back door; the ports build in-leg
#                (the vcpkg archive cache keeps reruns fast).
#   linux-musl — staged INSIDE alpine:3.17, the SAME musl generation as the
#                tebako-alpine-3.17 build container. Staging on a newer
#                alpine risks configure-time detected libc additions (the
#                strlcpy class, musl >= 1.2.4) that the 3.17 link cannot
#                resolve; the host cannot build musl objects at all.
#   macos      — native runner; the vcpkg baseline restore is safe there
#                (dwarfs-t is the single writer, built on the same runners).
#
# SQFS_SYS_VCPKG_INSTALLED_DIR is deliberately NOT exported for the cargo
# build: stage_link_unit harvests libsquashfs.a from the self-installed
# tree under the sqfs-sys cargo out dir — the pre-install below is an
# archive-cache warmer and lock-race avoidance only (sqfs-sys's build.rs
# would otherwise wait on the vcpkg-root lock dwarfs-t-sys holds for ~45
# min on a cold cache). Exporting the var (release.yml's binary legs do)
# leaves no tree under the out dir and the harvest dies.
set -eu

# Pins (owner: tebako-rs .github/workflows/release.yml + ci.yml; the factory
# windows leg mirrors the same vcpkg commit — keep all copies in step).
RUST_VERSION="1.94.1"
VCPKG_COMMIT="f14401ca0f2754347c3864da7488a9b955b4e47a"
# Kitware cmake for the gnu floor container: ubuntu 20.04's apt cmake is
# 3.16, dwarfs-t needs >= 3.24 (TEBAKO_BUILD) — provision, never guess.
CMAKE_VERSION="3.31.8"

die() { echo "link-unit-posix: $*" >&2; exit 64; }

# shellcheck disable=SC1007
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
FACTORY_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
WS=${GITHUB_WORKSPACE:-$FACTORY_ROOT}
OUT="$WS/.build/link-unit"
ACTIVE_VCPKG_ROOT=""

usage() {
  die "usage: sh ci/link-unit-posix.sh <macos|linux-gnu|linux-musl> <x86_64|arm64> | --inner <gnu|musl> <arch>"
}

triplet_for() { # $1=flavor $2=arch
  case "$1/$2" in
    gnu/x86_64)   echo x64-linux-static ;;
    gnu/arm64)    echo arm64-linux-static ;;
    musl/x86_64)  echo x64-linux-musl ;;
    musl/arm64)   echo arm64-linux-musl ;;
    macos/x86_64) echo x64-osx-static ;;
    macos/arm64)  echo arm64-osx-static ;;
    *) die "no vcpkg triplet for $1/$2" ;;
  esac
}

ensure_checkouts() {
  [ -f "$WS/tebako-rs/tools/stage_link_unit" ] ||
    die "tebako product checkout missing at $WS/tebako-rs (the workflow checks tamatebako/tebako out there)"
  [ -f "$WS/dwarfs-rs/dwarfs-t/CMakeLists.txt" ] ||
    die "dwarfs-rs checkout (submodules: recursive) missing at $WS/dwarfs-rs"
}

# vcpkg build logs die with the container otherwise — surface the tails.
dump_vcpkg_logs() {
  [ -n "$ACTIVE_VCPKG_ROOT" ] || return 0
  for f in "$ACTIVE_VCPKG_ROOT"/buildtrees/*/*-out.log "$ACTIVE_VCPKG_ROOT"/buildtrees/*/*-err.log; do
    [ -s "$f" ] || continue
    echo "=== $f ==="
    tail -30 "$f"
  done
}
on_exit() {
  rc=$?
  [ $rc -eq 0 ] || dump_vcpkg_logs
  exit $rc
}
trap on_exit EXIT

bootstrap_vcpkg() { # $1=root
  root=$1
  if [ ! -d "$root/.git" ]; then
    git clone --quiet https://github.com/microsoft/vcpkg "$root"
  fi
  if [ "$(git -C "$root" rev-parse HEAD)" != "$VCPKG_COMMIT" ]; then
    git -C "$root" checkout --quiet "$VCPKG_COMMIT"
  fi
  if [ ! -x "$root/vcpkg" ]; then
    "$root/bootstrap-vcpkg.sh" -disableMetrics
  fi
  ACTIVE_VCPKG_ROOT="$root"
}

rustup_install() {
  curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh
  sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "$RUST_VERSION"
  rm -f /tmp/rustup-init.sh
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  rustc --version
}

# Serialized squashfs-tools-ng install — an archive-cache warmer only (see
# the header): the cargo build's sqfs-sys build.rs self-installs from the
# warm archive cache into its own out dir, where stage_link_unit harvests
# libsquashfs.a. $1=vcpkg root, $2=triplet, $3=install root.
sqfs_preinstall() {
  echo "== pre-install squashfs-tools-ng ($2) =="
  "$1/vcpkg" install \
    --vcpkg-root "$1" \
    --x-wait-for-lock \
    --x-manifest-root "$WS/tebako-rs/crates/sqfs-sys" \
    --x-install-root "$3" \
    --triplet "$2" \
    --overlay-triplets "$WS/tebako-rs/crates/sqfs-sys/vcpkg_triplets" \
    --overlay-ports "$WS/tebako-rs/crates/sqfs-sys/vcpkg_ports"
}

run_stage() {
  cd "$WS/tebako-rs"
  echo "== stage_link_unit -> $OUT =="
  ruby tools/stage_link_unit "$OUT"
}

# --- macos (native runner) ---------------------------------------------------
stage_macos() {
  triplet=$(triplet_for macos "$ARCH")
  ensure_checkouts

  echo "== native build tools (brew) =="
  for formula in ninja autoconf automake autoconf-archive libtool; do
    brew list --formula "$formula" >/dev/null 2>&1 || brew install "$formula"
  done

  bootstrap_vcpkg "$WS/.vcpkg-root"

  # The vcpkg baseline (dwarfs-t is the single writer): never fails the leg
  # — a miss means the ports build normally. The restore script owns the
  # canonical root and reports it via GITHUB_ENV; adopt the value here (a
  # scratch file stands in when running outside GitHub Actions).
  envfile=${GITHUB_ENV:-}
  scratch=""
  if [ -z "$envfile" ]; then
    scratch=$(mktemp)
    envfile=$scratch
  fi
  if [ -n "${GH_TOKEN:-}" ] &&
     GITHUB_ENV="$envfile" bash "$WS/dwarfs-rs/dwarfs-t/ci/vcpkg-baseline-restore.sh" \
       "$WS/dwarfs-rs/dwarfs-t" "$triplet"; then
    kv=$(grep '^DWARFS_RS_VCPKG_INSTALLED_DIR=' "$envfile" | tail -1)
    if [ -n "$kv" ]; then
      kv_name=${kv%%=*}
      kv_value=${kv#*=}
      export "$kv_name=$kv_value"
      echo "vcpkg baseline: $kv"
    fi
  else
    echo "baseline miss — ports build normally"
  fi
  [ -z "$scratch" ] || rm -f "$scratch"

  sqfs_preinstall "$WS/.vcpkg-root" "$triplet" "$WS/.sqfs-installed"

  export DWARFS_RS_VCPKG_ROOT="$WS/.vcpkg-root"
  export VCPKG_ROOT="$WS/.vcpkg-root"
  export SQFS_SYS_VCPKG_ROOT="$WS/.vcpkg-root"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  run_stage
}

# --- linux container legs (host side): re-exec inside the libc container -----
host_container() { # $1=gnu|musl
  flavor=$1
  ensure_checkouts
  case "$flavor" in
    gnu)  image="ubuntu:20.04" ;;
    musl) image="alpine:3.17" ;;
    *)    die "no container image for flavor '$flavor'" ;;
  esac
  # Host dirs the caches warm (actions/cache + Swatinem/rust-cache): the
  # vcpkg archive cache and the cargo registry/git databases ride into the
  # container; the target dir lives in the mounted workspace. musl also
  # gets the source-built cmake's cache dir (3.17's stock cmake is too
  # old for the boost 1.90 ports).
  mkdir -p "$HOME/.cache/vcpkg" "$HOME/.cargo/registry" "$HOME/.cargo/git"
  extra_mounts=""
  if [ "$flavor" = musl ]; then
    mkdir -p "$HOME/.cache/tebako-cmake-musl-$ARCH"
    extra_mounts="-v $HOME/.cache/tebako-cmake-musl-$ARCH:/opt/cmake-musl"
  fi
  echo "== staging the link unit inside $image (flavor $flavor, arch $ARCH) =="
  # shellcheck disable=SC2086
  docker run --rm \
    -v "$WS:$WS" -w "$WS" \
    -v "$HOME/.cache/vcpkg:/root/.cache/vcpkg" \
    -v "$HOME/.cargo/registry:/root/.cargo/registry" \
    -v "$HOME/.cargo/git:/root/.cargo/git" \
    $extra_mounts \
    -e GITHUB_WORKSPACE="$WS" \
    "$image" sh "$WS/ci/link-unit-posix.sh" --inner "$flavor" "$ARCH"
}

# --- inner gnu (ubuntu:20.04 — the glibc 2.31 floor) --------------------------
inner_gnu() {
  triplet=$(triplet_for gnu "$ARCH")

  echo "== apt toolchain (focal) =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    build-essential ninja-build pkg-config \
    autoconf automake autoconf-archive libtool \
    curl zip unzip tar ca-certificates git gnupg \
    python3 libbz2-dev ruby libstdc++-10-dev

  # The workspace (and its checkouts) is runner-owned; the container is
  # root. Without this, every git command dies on 'dubious ownership' —
  # silent under version.cmake's ERROR_QUIET until its fail-closed guard
  # ('missing version files', slice 30733548162). The runners set the
  # same word for their own user in the checkout action's post-job.
  git config --global --add safe.directory '*'

  echo "== cmake $CMAKE_VERSION (Kitware binary; focal's apt cmake is 3.16) =="
  case "$ARCH" in
    x86_64) carch="x86_64" ;;
    arm64)  carch="aarch64" ;;
    *)      die "no kitware cmake arch for '$ARCH'" ;;
  esac
  curl -fsSL -o /tmp/cmake.tgz \
    "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-$carch.tar.gz"
  mkdir -p /opt/cmake
  tar -xzf /tmp/cmake.tgz -C /opt/cmake --strip-components=1
  rm -f /tmp/cmake.tgz
  PATH="/opt/cmake/bin:$PATH"
  export PATH
  cmake --version | head -1

  # rnp-rs's build.rs runs bindgen, which dlopens libclang. Focal's stock
  # libclang (v10) is too old for the current bindgen; llvm.org publishes
  # clang-19 for focal (tebako-rs ci/gnu-floor-build.sh's proven shape).
  echo "== clang-19 (llvm.org apt) =="
  curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg
  echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/focal/ llvm-toolchain-focal-19 main" \
    > /etc/apt/sources.list.d/llvm19.list
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends clang-19 libclang-19-dev
  echo "/usr/lib/llvm-19/lib" > /etc/ld.so.conf.d/llvm19.conf
  ldconfig
  export LIBCLANG_PATH=/usr/lib/llvm-19/lib

  # ONE compiler for the whole staged unit: clang-19. Focal's gcc-9.4 is
  # doubly unfit — Botan 3.12's configure.py refuses gcc < 11 (slice
  # 30733013847) and dwarfs-t's C++20 has never been exercised on gcc-9
  # (every proven build is clang or gcc >= 13). clang picks the newest
  # installed libstdc++ — libstdc++-10-dev above, exactly the build
  # container's set (clang-18 + libstdc++-10 is the image's proven C++20
  # combo): gcc-9's headers lack <span> (slice 30733224603). Object-level
  # GLIBCXX refs therefore stay at gcc-10's ceiling, and glibc refs stay
  # <= 2.31 by construction (focal headers).
  export CC=clang-19
  export CXX=clang++-19
  "$CC" --version | head -1

  # rnp-src 0.2.0's build_librnp hardcodes ("gcc", "g++") off macOS and
  # never reads CC/CXX — on focal that is gcc-9.4, and botan-3's headers
  # reject its C++14 default ('Botan 3.x requires at least C++20',
  # slice 30733548162). The crate cannot be steered from here, so the
  # gcc name resolves to clang-19 instead (the one-compiler rule above
  # makes the substitution coherent, not a hack).
  mkdir -p /opt/cc-shim
  ln -sf /usr/bin/clang-19 /opt/cc-shim/gcc
  ln -sf /usr/bin/clang++-19 /opt/cc-shim/g++
  PATH="/opt/cc-shim:$PATH"
  export PATH
  gcc --version | head -1

  # glibc 2.34 folded libpthread into libc, so the 24.04 runners never
  # miss it — focal's 2.31 keeps the DSO separate and botan's
  # os_utils/thread_pool objects (pulled into librnp's static link)
  # fail with 'undefined reference to pthread_create/pthread_setname_np'
  # (slice 30734476722). cmake appends LDFLAGS at configure time; vcpkg
  # sanitizes it out of the port builds, so only the direct cmake
  # projects (dwarfs-t, librnp) see it.
  export LDFLAGS="-lpthread"

  echo "== rustup ($RUST_VERSION) =="
  rustup_install

  echo "== vcpkg bootstrap ($VCPKG_COMMIT) =="
  bootstrap_vcpkg "$WS/.vcpkg-floor"

  # The sqfs overlay triplet for this arch (checked in for the common four;
  # generate from dwarfs-t's x64-linux-static otherwise — gnu-floor shape).
  SQFS_TRIPLETS="$WS/tebako-rs/crates/sqfs-sys/vcpkg_triplets"
  DWARFS_TRIPLETS="$WS/dwarfs-rs/dwarfs-t/vcpkg_triplets"
  if [ ! -f "$SQFS_TRIPLETS/$triplet.cmake" ]; then
    case "$ARCH" in arm64) va=arm64 ;; *) va=x64 ;; esac
    sed -e "s/VCPKG_TARGET_ARCHITECTURE x64/VCPKG_TARGET_ARCHITECTURE $va/" \
        "$DWARFS_TRIPLETS/x64-linux-static.cmake" > "$SQFS_TRIPLETS/$triplet.cmake"
  fi

  sqfs_preinstall "$WS/.vcpkg-floor" "$triplet" "$WS/.sqfs-floor"

  export DWARFS_RS_VCPKG_ROOT="$WS/.vcpkg-floor"
  export VCPKG_ROOT="$WS/.vcpkg-floor"
  export SQFS_SYS_VCPKG_ROOT="$WS/.vcpkg-floor"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  run_stage
}

# --- inner musl (alpine:3.17 — the build container's musl generation) --------
inner_musl() {
  triplet=$(triplet_for musl "$ARCH")

  echo "== apk toolchain (alpine 3.17) =="
  # clang15-libclang: rnp-rs's build.rs runs bindgen (the rnp-src
  # source-built model) — bindgen dlopens libclang.so at runtime, and
  # only the versioned libclang package ships on alpine (3.17 has no
  # unversioned `libclang`; tebako-rs's 3.21 legs use clang19-libclang).
  # The shim below gives bindgen the unversioned name. No apk cmake:
  # 3.17's 3.24.4 is too old for the boost 1.90 ports (they declare 3.25
  # — FetchContent SYSTEM is real, slice 30734477576) — a new enough
  # cmake is provisioned from source below.
  apk --no-cache add \
    build-base ninja git bash \
    autoconf automake libtool make pkgconfig perl python3 \
    curl zip unzip tar ca-certificates linux-headers \
    openssl-dev ruby clang15-libclang

  # Same root-vs-runner ownership story as the gnu leg: git must answer
  # version.cmake's rev-parse/log or dwarfs-t's configure fails closed
  # ('missing version files').
  git config --global --add safe.directory '*'

  # cmake $CMAKE_VERSION from source (bootstrap needs only g++ + make),
  # installed into the host-mounted cache dir — the build pays once, every
  # later leg restores it. 3.17's musl is the whole point of this
  # container, so a newer alpine (or a glibc-linked prebuilt cmake) is
  # never the answer.
  if [ ! -x /opt/cmake-musl/bin/cmake ]; then
    echo "== building cmake $CMAKE_VERSION from source (first musl leg pays this once) =="
    curl -fsSL -o /tmp/cmake-src.tgz \
      "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION.tar.gz"
    mkdir -p /tmp/cmake-src
    tar -xzf /tmp/cmake-src.tgz -C /tmp/cmake-src --strip-components=1
    rm -f /tmp/cmake-src.tgz
    (cd /tmp/cmake-src && ./bootstrap --prefix=/opt/cmake-musl --parallel="$(nproc)" \
       && make -j"$(nproc)" && make install)
    rm -rf /tmp/cmake-src
  fi
  PATH="/opt/cmake-musl/bin:$PATH"
  export PATH
  cmake --version | head -1

  so=$(find /usr/lib -name 'libclang.so*' 2>/dev/null | sort -V | tail -1)
  [ -n "$so" ] || die "no libclang.so* under /usr/lib after apk add clang15-libclang"
  so_dir=$(dirname "$so")
  [ -e "$so_dir/libclang.so" ] || ln -s "$so" "$so_dir/libclang.so"
  export LIBCLANG_PATH="$so_dir"
  echo "LIBCLANG_PATH=$so_dir ($so)"

  # vcpkg's bootstrap downloads glibc-linked cmake/ninja by default — they
  # cannot run on musl (exit 127). Use the apk-provided tools everywhere.
  export VCPKG_FORCE_SYSTEM_BINARIES=1

  echo "== rustup ($RUST_VERSION) =="
  rustup_install

  echo "== vcpkg bootstrap ($VCPKG_COMMIT) =="
  bootstrap_vcpkg "$WS/.vcpkg-musl"

  # The musl overlay triplets: x64-linux-musl is checked into dwarfs-t;
  # generate the arm64 flavor and the sqfs copies on the fly
  # (tebako-rs ci/musl-build.sh's shape; upstreaming is a follow-up there).
  SQFS_TRIPLETS="$WS/tebako-rs/crates/sqfs-sys/vcpkg_triplets"
  DWARFS_TRIPLETS="$WS/dwarfs-rs/dwarfs-t/vcpkg_triplets"
  if [ ! -f "$DWARFS_TRIPLETS/$triplet.cmake" ]; then
    case "$triplet" in
      arm64-linux-musl)
        sed -e "s/VCPKG_TARGET_ARCHITECTURE x64/VCPKG_TARGET_ARCHITECTURE arm64/" \
            "$DWARFS_TRIPLETS/x64-linux-musl.cmake" > "$DWARFS_TRIPLETS/$triplet.cmake" ;;
      *) die "no dwarfs-t overlay triplet for '$triplet'" ;;
    esac
  fi
  if [ ! -f "$SQFS_TRIPLETS/$triplet.cmake" ]; then
    case "$ARCH" in arm64) va=arm64 ;; *) va=x64 ;; esac
    sed -e "s/VCPKG_TARGET_ARCHITECTURE x64/VCPKG_TARGET_ARCHITECTURE $va/" \
        "$DWARFS_TRIPLETS/x64-linux-musl.cmake" > "$SQFS_TRIPLETS/$triplet.cmake"
  fi

  sqfs_preinstall "$WS/.vcpkg-musl" "$triplet" "$WS/.sqfs-musl"

  # dwarfs-t's frozen_bit_writer.h uses size_t without <cstddef> — fine
  # where a newer libstdc++ pulls it in transitively (gcc-13 runners),
  # fatal on 3.17's gcc-12 include graph (slice 30742088790: 'error:
  # size_t has not been declared'). The durable fix is a one-line
  # include in dwarfs-t (owner follow-up); until it lands, force the
  # header in — cmake reads CXXFLAGS at configure time, so the
  # cached-target-dir bust in the workflow (the link-unit2- key) is
  # what lets this reach an already-configured build tree.
  export CXXFLAGS="-include cstddef"

  # musl targets default to +crt-static, and a statically linked build
  # script cannot dlopen — but rnp-rs's build.rs runs bindgen, which
  # dlopens libclang. -crt-static OFF: the artifacts are dynamic-musl, the
  # same shape as the runtimes this factory ships (ci/musl-build.sh).
  export RUSTFLAGS="-C target-feature=-crt-static"
  export DWARFS_RS_VCPKG_ROOT="$WS/.vcpkg-musl"
  export DWARFS_RS_VCPKG_TRIPLET="$triplet"
  export SQFS_SYS_VCPKG_TRIPLET="$triplet"
  export VCPKG_ROOT="$WS/.vcpkg-musl"
  export SQFS_SYS_VCPKG_ROOT="$WS/.vcpkg-musl"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
  run_stage
}

MODE=${1:-}
case "$MODE" in
  macos|linux-gnu|linux-musl)
    ARCH=${2:-}
    [ -n "$ARCH" ] || usage
    case "$MODE" in
      macos)      stage_macos ;;
      linux-gnu)  host_container gnu ;;
      linux-musl) host_container musl ;;
    esac
    ;;
  --inner)
    FLAVOR=${2:-}
    ARCH=${3:-}
    [ -n "$FLAVOR" ] && [ -n "$ARCH" ] || usage
    case "$FLAVOR" in
      gnu)  inner_gnu ;;
      musl) inner_musl ;;
      *)    usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac

echo "link-unit-posix: staged the v2 link unit at $OUT"
