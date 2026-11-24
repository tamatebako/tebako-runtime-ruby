# The build chain — architecture and invariants

This document is the normative description of how this repository's CI
turns a patched ruby source into published runtime packages, and of the
caching contracts that keep the matrix fast. **If you change any workflow,
the roll tooling, the matrix computation, or a cache key, update this file
in the same PR.** A future agent that skips this file and "just fixes" a
red run is the classic failure mode — read it first.

## The staged hierarchy

`_build-platform.yml` is the ONE per-platform build workflow. The four
thin triggers (`build-<platform>.yml`) and the `publish.yml` coordinator
call it; it is never dispatched directly. Stages:

1. **compute** — `scripts/compute_matrix.rb --platform <p>` walks
   `.github/build-graph.yaml` against the event's change set and emits
   THIS platform's legs. A leg runs because something it reads changed —
   never because "the workflow fired". An unaffected platform computes
   `run=false` and every later stage skips in seconds.
2. **link-unit** — the v2 link unit (tebako-driver + scoped tfs + the
   native closure), staged once per platform-arch. The closure depends on
   the triplet only, never on the ruby version.
3. **build** — the matrix legs (env × ruby), consuming the staged unit
   via `TEBAKO_RUST_LIBDIR`.
4. **publish + sign** — IN-LEG (spec 13 §2a's de-rendezvous, roadmap 85):
   the leg that built a package publishes its write-once names (payload +
   `.sha256` sidecars + `.manifest.json` shard) and signs every served
   name (`spec 09 §5`'s no-fold rule) in the same invocation. No shared
   file exists, so N legs publish concurrently with zero rendezvous — the
   serialized publish group is gone. The `publish.yml` coordinator keeps
   ONE release job for the two duties that need the whole matrix: the
   read-only AUDIT of every platform's expected names against the
   release, and the registry render (`tools/registry_update.rb`) landed
   on main by bot PR.

## The diff-routing law (build-graph.yaml)

- `shared:` inputs reach every platform's legs (the builder model, the
  build workflow, the matrix planner, the matrix vocabulary).
- `platforms:<p>:` inputs reach only that platform.
- `publish_only:` paths (release tooling consumed at release time —
  `scripts/release_adapter.rb`, `tools/registry_update.rb`,
  `tpkg-registry.yaml`, the `publish.yml` coordinator, the pin-bump bot,
  the bare-launch probe) produce no legs: a change there cannot affect
  build outputs.
- `ignore:` paths (docs, etc.) produce no legs.
- `validation_only:` paths validate on the tidy set, never build-shaped.
- A source-pin move (`DEFAULT_RELEASE` in
  `build/lib/tebako_runtime_builder/source_fetcher.rb`) rebuilds exactly
  the versions whose tarballs moved **in the scenarios this platform
  consumes** (per-scenario SHA256SUMS diff; macos consumes the linux-gnu
  scenario). An msys-only source change runs windows legs only.
- A version `defer`red for a platform in `matrix.json` is never
  scheduled, never expected, never promised there — dropped at the
  universal chokepoint (`available`), so every trigger path agrees.

## The cache architecture (and why it works)

Four independent caches, each keyed on what it actually contains:

| Cache | Key | Contents |
|-------|-----|----------|
| roll cache | `spec22-src-roll-v2-<platform>-<hash(rolled inputs)>` | the rolled source tarballs + SHA256SUMS |
| build prefix | `tebako-runtime-<os>-<arch>-<version>-<tebako-ver>-<src_sha256>-v<CACHE_VER>` | the whole `.build` prefix |
| staged link unit | `link-unit-staged-v1-<os>-<arch>-<tebako-sha>-<dwarfs-sha>-<hash(ci/link-unit*.sh)>` | the fully staged link unit (compile skipped on hit) |
| published link unit | release-pin download (no cache scope) | the native closure per triplet — the terminal state |

The roll cache key is the hash of the ROLLED INPUTS
(`ruby-src/versions.yml`, `ruby-src/patches/**`, `ruby-src/schema/**`,
`ruby-src/tools/**`) — content, not the ruby-branch SHA. A probe commit
that touches only CI/harness files reuses the previous round's roll.
The retired v1 key (branch SHA) minted a fresh ~2.5 GB entry per probe
commit and evicted the build prefixes the matrix runs to warm.

The staged link unit is keyed on the two input SHAs it compiles
(tebako-rs + dwarfs-t) plus the link-unit scripts. A hit skips the
whole compile stage (the build legs consume the restored stage); a miss
rebuilds and saves. The published pin, when set, beats both — it is
the scope-free terminal state (see the scope law below).

The load-bearing build-prefix component is `src_sha256`: the sha256 of
the source tarball THIS platform consumes for that ruby version. It is
read from the pinned release's SHA256SUMS (normal path) or from the
roll's own SHA256SUMS (chain gate, via `TEBAKO_SRC_MIRROR`). The build
prefix cache is `save-always: true` — a red leg must never poison the
next one.

**For this to save anything, `src_sha256` must be content-addressed:**
identical patched source ⇒ identical tarball bytes ⇒ identical sha256 ⇒
cache hit. Which brings us to the contract.

## THE DETERMINISM CONTRACT (do not violate)

The source roll's tarballs are produced with metadata fully clamped:

```
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -czf ...
```

- Member order is sorted (readdir order is not stable across checkouts).
- All mtimes are epoch (a fresh checkout/patch run stamps now()).
- Ownership is numeric zero (runner uids must not leak into bytes).
- The gzip header is already MTIME=0: tar pipes through gzip, which has
  no name/timestamp to record.

Verified 2026-08-17: two independent `tools/apply` rolls of the same
version produce byte-identical trees (`diff -r` clean), and a
metadata-clamped tar of both produces identical sha256.

Verified again 2026-08-19 (runs 32204381083, 32211646613): three probe
rounds on three different ruby-branch SHAs computed the IDENTICAL build
prefix key (`…e06b8398…-v4`) — the roll bytes did not move.

**If the tar line regresses to plain `tar -czf`:** every ruby-branch
move changes every tarball's sha256 on every platform, every build
prefix cache goes cold, and the whole matrix rebuilds (~60 min × every
leg) for changes that touched one platform's bytes — the runner-queue
starvation this design exists to prevent.

**Forbidden moves:**

- Never reintroduce a plain `tar -czf` in the roll step.
- Never bump `CACHE_VER` to "fix" a cache miss whose real cause is
  non-deterministic roll bytes — `CACHE_VER` is the manual escape hatch
  for a build-recipe shape change under an UNCHANGED source tarball,
  nothing else.
- Never hand-edit a SHA256SUMS file. It is generated, always.
- Never add timestamps, absolute paths, or host identifiers to anything
  `tools/apply` writes into the rolled tree — the tree is content, and
  content is the cache key.

## The artifact reproducibility pins (the E1/E2 contract)

The roll contract above makes the SOURCE bytes deterministic; this
section is the ARTIFACT side — what makes two runs of the same commit
produce the same exe and `.tfs`, and how the claim is proven.

The pins (each named in the leg's provenance, never implicit):

- **`SOURCE_DATE_EPOCH`** — the compute job derives ONE epoch from the
  HEAD commit (`git log -1 --format=%ct`) and every leg stamps it: the
  image manifest's `identity.created` and the packed image's metadata
  (tfs-cli's mkimage honors it; unset falls to epoch 0). A same-commit
  re-run reproduces the stamp; the wall clock never enters an artifact.
- **Container digests** — `contract.yml container_digests` records the
  ghcr manifest digest per (container × arch); the preflight job proves
  recorded == live before any leg spends compute, and the container legs
  pull `name:tag@digest`. A retagged toolchain container fails the
  preflight by name instead of moving the compiler under the matrix.
- **Pinned compilers** — the linux-gnu leg installs
  `gcc-11=${GCC11_PIN}`/`g++-11=${GCC11_PIN}` (the PPA's exact version
  tokens) for the exe link; the rust toolchain is the FLOWED ecosystem
  pin on EVERY leg that compiles Rust — the container legs and (since
  the runner image's rustc floats with the image) the macos legs, via
  `ci/prepare-rust-toolchain.sh`, and the link-unit source build via
  dtolnay's `toolchain:` input.
- **darwin codegen + link pins** (`Platform::CONFIGURE_CPU_PINS` /
  `CONFIGURE_DLD_PINS`, flowed by the builder as `-DRUBY_CPU_PIN` /
  `-DRUBY_DLD_PIN` and spliced into the ruby configure by
  `build/CMakeLists.txt`; the E5 twin-run, #390) — two darwin-specific
  drift classes closed at the flag level. `-mcpu=apple-m1` on
  macos-arm64: Apple clang's aarch64 default `-target-cpu` is the build
  host's own chip, so codegen drifts with whatever silicon the hosted
  fleet hands the leg, and can emit instructions the contract floor
  (macOS 14 ⇒ M1) lacks; apple-m1 is the floor and runs on every later
  chip (macos-x86_64 pins nothing — its default target-cpu is a fixed
  conservative model, never the host chip). `-Wl,-S` on the darwin
  bundle links: the new ld derives an MH_BUNDLE's `LC_UUID` from a hash
  of the link content, which includes the N_OSO debug stabs recording
  each object file's mtime — two cold builds of the same tree therefore
  produce extension bundles differing in `LC_UUID` and in the ad-hoc
  CDHash that covers it (the E5 drift, 6 of 7 drifted bundles).
  Stripping the stabs AT LINK makes the hashed content exactly the
  shipped bytes — the same determinism the exe already gets from its
  `ld_classic` link (`MAINLIBS` carries `-Wl,-ld_classic`, whose UUID
  hash ignores stab mtimes). The bundles lose nothing: DWARF never
  ships in them (the deploy strip removes it anyway).
- **Host-path scrubs** — the deploy pass rewrites the shipped
  `rbconfig.rb`'s build-host prefixes and flag values to the mount point
  (never `CONFIG["build"]`/TOPDIR), normalizes every shipped gemspec's
  `s.rubygems_version` to the rubygems the image ships (read from the
  tree's own `rubygems.rb` — the E3 twin-run's writer-fingerprint leak,
  #384), and the deploy strip removes the `.dSYM` trees and the
  extension-compile build logs (`mkmf.log`/`extconf.log`/`config.log` —
  mkmf's ccXXXXXX.o temp names are random per run, #384's E4 finding).
  Ruby's configure runs with
  the canonical `--build`/`--host` triplet (Platform::CONFIGURE_TRIPLETS
  owns the map; the darwin kernel major flows from
  `macos_deployment_target`), so the recorded archdir never names the
  build host's guess.
- **The recorded provenance** — every contract sidecar's `built_from`
  carries `exe_sha256_presign` (the pre-signing exe digest) and
  `toolchain` (the leg's identity, composed by `ci/record-toolchain.sh`
  beside the toolchain it names). The release shards fold both.

The named gaps (recorded-not-pinned, by construction):

- **brew** floats within a run's runner image (the Brewfile pins formula
  NAMES, not versions; `--no-upgrade` stops mid-matrix drift). The
  resolved versions are recorded in the toolchain identity.
- **MSYS2** rides the rolling repo: the action SHA pins the
  checksum-verified base installer, but the package resolution floats.
  The action's `update: true` stays on every msys leg — it owns the
  runtime self-update termination dance (an in-leg `pacman -Syu` that
  pulls msys2-runtime kills the shell mid-step, run 44916477809) — and
  MSYS2 serves no snapshot mirror a `pacman -U` could pin against (a
  snapshot URL 404s as the mirrors GC; a `--ignore` holdback of the
  runtime is an unsupported partial upgrade). The resolved package set
  is recorded (`pacman -Q` per leg, and its sha256 in the toolchain
  identity). One member has left the class permanently
  (tebako-runtime-ruby#392): **libyaml** — the rolling repo dropped
  `libyaml.a` in `mingw-w64-*-libyaml-0.2.6-1` (2026-11-23, every
  windows link died `cannot find -l:libyaml.a`), so the deps stage
  builds it from the upstream 0.2.5 tarball into `deps/lib` (the
  autotools configure — upstream's dist excludes the CMake support
  files, so the CMake path fails at configure_file), and the legs no
  longer install `libyaml:p`. The windows gate asserts no `libyaml`
  DLL name in either shipped PE's import table.
- **Signing** rewrites the exe after `exe_sha256_presign` is recorded
  (macOS codesign, windows Authenticode) — timestamped by design. The
  reproducibility claim is scoped to the pre-signing bytes.
- **bigdecimal's `.text` on darwin** (recorded-not-pinned, #390): Apple
  clang 16's loop vectorizer rolls equal-cost SIMD lane/register choices
  per compiler invocation on bigdecimal.c — 49 distinct objects of 50
  in-job recompiles on ONE runner (the E5 probe twin, runs 45359686216 +
  45359692782; `-fno-vectorize` stabilizes, `-fno-slp-vectorize`/`-O2`/
  `-frandom-seed` do not; clang 15 is byte-stable 20/20 on the same
  flags). The variants are semantically equivalent and the runtime is
  unaffected, but the macos-arm64 bundle bytes carry the roll until the
  upstream fix lands or a per-TU `-fno-vectorize` patch is taken (the
  perf tradeoff is the owner's call — the flag sweeps are recorded in
  #390). Every other object in the tree is byte-stable across runners.

The proof protocol (run post-merge by the release driver, never a CI
gate): **E1** re-dispatches the same commit on ONE ref — the warm-cache
arm, expected trivially identical. **E2** dispatches the same commit on
a SECOND ref (THE SCOPE LAW below: a same-key cache never crosses refs,
so the second ref pays the cold build) — the cold arm. The diff reads
the shards: `built_from.exe_sha256_presign` per leg, plus the `.tfs`
sidecar shas. A mismatch names its leg; the toolchain identity is the
first suspect list.

The per-release verification surface is `.github/workflows/reproduce.yml`
(docs/reproducible.md owns the claim per leg and the era table): for ONE
published leg it dispatches the platform's thin trigger ON THE RELEASE
TAG's ref (the tag's own pipeline definition runs — checkouts are the
event ref, never an input, so no cache-writing job ever builds an
input-selected ref; the run's cache writes land in the tag's own scope
by THE SCOPE LAW below, never the default branch's), watches the build,
and fails on any byte-identity mismatch. It runs weekly as the drift
watch and on dispatch for any tag.

## THE SCOPE LAW (why a green key still misses)

`actions/cache` scopes entries to the ref that wrote them:
`refs/pull/N/merge` runs and branch dispatches NEVER share entries,
even when the key string is identical. Evidenced 2026-08-19: runs
32204381083 (`pull_request`) and 32211646613 (`workflow_dispatch` on
the branch) computed the same prefix key and both missed — each scope
was cold. Consequences:

- **Iterate on ONE ref.** Pick `workflow_dispatch` on the feature
  branch and stay on it; every scope's first run pays a cold build,
  and bouncing between a PR run and a dispatch pays it twice.
- **A scope miss is NOT corruption and NOT non-determinism** — never
  bump `CACHE_VER` for it, never "fix" the roll. Check the run's ref
  before touching any key.
- **The published-pin path is the scope-free terminal state** — release
  downloads carry no cache scope. Landing the chain (ruby source
  release → tebako release → pins set) is what makes the caches
  advisory instead of load-bearing.

Eviction math: the repository cache cap is 10 GB. One link-unit-stage
entry is ~2.3–2.6 GB; the retired per-commit roll key minted a fresh
~2.5 GB entry per probe commit, so three probe rounds were enough to
evict the build prefixes the matrix runs to warm. The content-keyed
roll (v2) and the staged link-unit cache exist to keep minted bytes per
probe round near zero.

## The patch-ownership law (the factory never edits ruby C source)

This repo is a **pure builder**: it fetches the pinned, sha256-verified,
PRE-PATCHED source release from tamatebako/ruby and compiles it. Every
patch to ruby's own sources — every `*.c`/`*.h` semantic change the
runtime needs — is owned by tamatebako/ruby and reaches a build ONLY
through a source release (the SSOT law; the release pin is
`source_fetcher.rb`'s `DEFAULT_RELEASE`).

Under incident pressure the correct loop is: fix on a tamatebako/ruby
branch → iterate UNMERGED via `harness_ref` (below) → merge to ruby main
→ cut a source release → bump the pin here. **Never** land a NEW
factory-side hot-patch of ruby C source — not "temporarily", not with a
removal note. (The 2026-08 incident era did exactly that — the
glob_opendir guard, the fd_is_text dispatch, the dlmap extraction
workaround — each with a "drop with the pin bump" contract. At the
v0.2.26 pin bump the three were audited for absorption line-by-line: the
dlmap extraction WAS absorbed (dln_c_dlmap_msys + the tebako@main link
unit, tebako#414) and is retired; the glob_opendir guard and the
fd_is_text dispatch were NOT — the released patches never mention
`glob_opendir`/`nfiles`/`rb_w32_fd_is_text`, and the #114 windows boot
smoke segfaulted at `<internal:dir>:220` on every ruby leg without them.
Those two survive in `build_passes.rb` as named, spec-pinned hot-patches
until the source-side absorption lands in tamatebako/ruby's
dir_c_memfs_msys / io_c_shims_msys patches and ships in a source
release. Do not resurrect the pattern for anything new.)

What legitimately remains in `build_passes.rb` is build-LINK glue: the
issue-40 set (the DLL export fragment, the exe link order, the mkexports
baseruby rewrite, miniruby's static libs) edits ruby's build SYSTEM
(Makefile.in/GNUmakefile.in/mkexports.rb/config.status) to control how
OUR link unit joins the ruby DLL/exe — factory business, never ruby
semantics.

## The spec-22 chain gate (temporary)

While the v2 chain is in flight, the roll-source job rolls from the
draft ruby branch (not the published release), the matrix's `src_sha256`
comes from that roll via `TEBAKO_SRC_MIRROR`, and build legs download
the roll artifact (`--src-mirror`). The gate fails a non-windows roll
whose `dln.c` lacks the loader-interpose block; msys is exempt BY DESIGN
(`dln_c_dlmap_msys` owns dln.c there, and the block is dead code without
`USE_DLN_DLOPEN`). When the chain lands (ruby release, then tebako
release), the chain jobs and the mirror plumbing come out and the
published-pin path remains.

## Operator escape hatches

- `workflow_dispatch` grammar: `full | tidy | catalog | a,comma,slice`
  on one platform, optionally with `arch_filter` — the fast path for
  iteration loops that genuinely need rebuilt artifacts.
- `ruby_filter` (e.g. `4.0.6`) narrows the matrix to one ruby version —
  the probe-round spend control. Pair it with a dispatch on ONE ref
  (the scope law above).
- `harness_ref` points the dogfood acceptance-harness checkout at a
  tamatebako/ruby branch, so the harness iterates UNMERGED next to its
  probe PR — never merge a harness PR just to run it.
- `audit: true` — publish-shaped verification with no build spend.
- `CACHE_VER` — see the contract above; bump ONLY for recipe shape
  changes, and say why in the comment (the history is recorded there).

## The env image's support-DLL set (msys only)

Windows legs stage the msys2 toolchain runtime DLLs
(libwinpthread-1.dll, libgcc_s_seh-1.dll, libstdc++-6.dll) into the
image's `bin/` and the L1 manifest declares them as `library_aliases:`
(spec 22 §2.1 — the alias channel; spec 03 §2.5 owns the grammar). The
driver's boot pass materializes declared aliases and leads the process
PATH with their directories, so a payload-resident C extension's bare
import (ox.so/sqlite3 → libwinpthread-1.dll — the packed-mn#251 windows
126; sassc's libsass → the C++ pair) binds through the OS's own standard
search order, per-gem-code-free. `SupportDlls::NAMES` is the single
owner: the deploy pass stages exactly that set (fail-closed when the
toolchain prefix lacks a member), `ImageManifest` declares exactly that
set, and the boot smoke judges the chain (declaration, in-image
presence, PATH lead) against it via `TEBAKO_SMOKE_EXPECT_SUPPORT_DLLS`.

## The macOS signing profile (the entitlement grants)

`ci/runtime.entitlements` pins the fixed hardened-runtime profile every
macOS exe is signed with (spec 31 §3/§5 — the pinned set until §2's
manifest derivation lands). Four grants, each load-bearing:

- **allow-dyld-environment-variables** (tebako#1125's class; the
  tebako-runtime-r#5 precedent) — dyld honors the driver's
  `DYLD_INSERT_LIBRARIES` at the boot-head self re-exec. Without it the
  insertion is stripped SILENTLY and every unpatched native extension
  (a third-party C extension doing plain libc open of an in-image path
  — leptris' libxml2 shape) dies ENOENT on the host filesystem, while
  ruby's own patched IO stays green: the published 0.17.15 pair shipped
  exactly that defect, GREEN on every leg, because macOS 15's dyld
  tolerates the omission and no CI runner runs a stripping macOS. So
  the profile is asserted STATICALLY in-leg by
  `ci/macos-sign-notarize-runtime.sh` — count the `<true/>` values AND
  grep each key by name (a count alone passes a wrong-keyed profile) —
  and publish.yml's macos-14 acceptance leg is the stripping-platform
  exec canary, with the boot smoke's `boot_head_insertion` sense (the
  micro interpose dylib in dyld's own loaded-image list) carrying the
  named verdict.
- **disable-library-validation** — the driver materializes in-image
  native extensions to the host for dlopen; they carry no Developer ID
  signature of their own.
- **allow-jit** — the MAP_JIT grant; ruby's JITs never use MAP_JIT, but
  a grant is a permission, never a requirement.
- **allow-unsigned-executable-memory** (ruby#386) — YJIT/ZJIT do W^X by
  mprotect over a plain PROT_NONE reservation (no MAP_JIT anywhere in
  yjit/, zjit/, or jit.c); without the grant the kernel SIGKILLs the
  first instruction fetch from the JIT arena — the 0.17.15 darwin-23
  incident.

The dyld grant is the entitlement PLANE of tebako#1125's fix, and its
sufficiency boundary is recorded, not implied: the insertion it
restores arms CHILD processes with the file-IO preload shim, while the
macOS INTERPRETER process itself carries no file-IO interpose family
today (the boot-head micro dylib covers dlopen/dlerror only; the shim's
in-process dlopen is interpose-inert; ruby's fs TU has no preload-shim
re-exec — R's tebako_r_main.c shape). The boot smoke's `native_open`
scenario pins that platform truth fail-closed: the raw-open checks
answer "ok" on linux (the exe-shape `libtfs_preload.a` preempts
in-process) and "unsupported" on macOS until the product delivers the
family into the interpreter process (the rebind module gaining the
file-IO tuples, or the fs TU gaining R's re-exec) — the delivery flips
the recorded expectation deliberately, in its own PR.

## Where each value lives (SSOT)

- macOS entitlement profile: `ci/runtime.entitlements` (asserted in-leg
  by `ci/macos-sign-notarize-runtime.sh`).
- Legs/routing: `.github/build-graph.yaml` + `scripts/compute_matrix.rb`.
- Version/env vocabulary: `.github/matrix.json`.
- Source pin + asset naming: `build/lib/tebako_runtime_builder/source_fetcher.rb`.
- Configure pins (triplet, `-mcpu`, dldflags): `build/lib/tebako_runtime_builder/platform.rb`
  (`CONFIGURE_TRIPLETS` / `CONFIGURE_CPU_PINS` / `CONFIGURE_DLD_PINS`).
- Toolchain container version: `contract.yml`.
- msys support-DLL set: `build/lib/tebako_runtime_builder/support_dlls.rb`.
- This architecture: `docs/build-chain.md`. The release process:
  `docs/release-runbook.md`.
