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
  workflows themselves, the matrix vocabulary).
- `platforms:<p>:` inputs reach only that platform.
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

Three independent caches, each keyed on what it actually contains:

| Cache | Key | Contents |
|-------|-----|----------|
| roll cache | `spec22-src-roll-v1-<platform>-<ruby-branch-sha>` | the rolled source tarballs + SHA256SUMS |
| build prefix | `tebako-runtime-<os>-<arch>-<version>-<tebako-ver>-<src_sha256>-v<CACHE_VER>` | the whole `.build` prefix |
| link unit | artifact staged per run, pin-hit download | the native closure per triplet |

The load-bearing one is `src_sha256`: the sha256 of the source tarball
THIS platform consumes for that ruby version. It is read from the
pinned release's SHA256SUMS (normal path) or from the roll's own
SHA256SUMS (chain gate, via `TEBAKO_SRC_MIRROR`). The build prefix cache
is `save-always: true` — a red leg must never poison the next one.

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
- `audit: true` — publish-shaped verification with no build spend.
- `CACHE_VER` — see the contract above; bump ONLY for recipe shape
  changes, and say why in the comment (the history is recorded there).

## Where each value lives (SSOT)

- Legs/routing: `.github/build-graph.yaml` + `scripts/compute_matrix.rb`.
- Version/env vocabulary: `.github/matrix.json`.
- Source pin + asset naming: `build/lib/tebako_runtime_builder/source_fetcher.rb`.
- Toolchain container version: `contract.yml`.
- This architecture: `docs/build-chain.md`. The release process:
  `docs/release-runbook.md`.
