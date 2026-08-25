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
4. **publish** — uploads this platform's packages; the manifest merge
   keeps every other platform's entries, and a serialized concurrency
   group makes simultaneous publishes impossible.

## The diff-routing law (build-graph.yaml)

- `shared:` inputs reach every platform's legs (the builder model, the
  build workflow, the matrix planner, the matrix vocabulary).
- `platforms:<p>:` inputs reach only that platform.
- `publish_only:` paths (release tooling consumed at release time —
  `scripts/upload_release.rb`, the `publish.yml` coordinator, the
  pin-bump bot, the bare-launch probe) produce no legs: a change there
  cannot affect build outputs.
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

## Where each value lives (SSOT)

- Legs/routing: `.github/build-graph.yaml` + `scripts/compute_matrix.rb`.
- Version/env vocabulary: `.github/matrix.json`.
- Source pin + asset naming: `build/lib/tebako_runtime_builder/source_fetcher.rb`.
- Toolchain container version: `contract.yml`.
- msys support-DLL set: `build/lib/tebako_runtime_builder/support_dlls.rb`.
- This architecture: `docs/build-chain.md`. The release process:
  `docs/release-runbook.md`.
