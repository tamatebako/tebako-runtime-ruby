# Reproducible builds — the claim, the scope, and the per-release proof

`docs/build-chain.md` ("The artifact reproducibility pins") owns the
**contract**: the pins that make two runs of the same tree produce the
same exe and `.tfs`. This file owns the **claim per leg** and the
**verification surface** — `.github/workflows/reproduce.yml`, which any
reader can dispatch against any published release, and which runs weekly
as the drift watch.

## The claim (and its scope)

For a release tag whose tree carries the reproducible-build arc:

> Same tag tree + same chain (tamatebako/ruby roll, tebako product pin,
> digest-pinned toolchain containers, pinned compilers) ⇒ byte-identical
> runtime exe (**pre-signing**) and byte-identical env image.

The scoped exclusions, all named in the leg's provenance (the release
shard's `built_from`), never silent:

- **Signing rewrites the exe after the claim's digest.** macOS codesign
  today, Windows Authenticode once spec 34 arms. The exe claim is scoped
  to `built_from.exe_sha256_presign`; the published (signed) exe verifies
  against its own `.sha256` sidecar, never against a rebuild.
- **brew floats within a runner image** (recorded, not pinned — the
  Brewfile pins formula names; the resolved versions land in
  `built_from.toolchain`).
- **MSYS2 rides the rolling repo** (recorded, not pinned — no snapshot
  mirror exists to pin against; the `pacman -Q` manifest's digest lands
  in `built_from.toolchain`). Windows byte-identity is therefore claimed
  only while the pacman resolution stands; a moved resolution is expected
  drift, and the toolchain record names it.
- The **runner image** is recorded in `built_from.toolchain` and floats
  on GitHub's schedule — a suspect, not a pin.

## The era law (why old tags verify differently)

The arc landed after v0.17.15. A tag whose tree predates it carries no
`ci/record-toolchain.sh` (the current workflow's build steps invoke it),
stamps its image manifest's `identity.created` with wall-clock time (no
`SOURCE_DATE_EPOCH` honor — its images can never byte-reproduce), and its
shards carry no `exe_sha256_presign` / `toolchain`. For those tags
reproduce.yml verifies the **published-integrity floor** — the leg's exe
and image download and sha256-verify against their published `.sha256`
sidecars, and the shard is proven in sync with those anchors — and says
so in the verdict. The identity rows light up automatically on the first
post-arc release; no workflow edit is needed.

| tag | era | what reproduce.yml verifies |
|---|---|---|
| ≤ v0.17.15 | pre-arc | published-integrity floor (exe/image ↔ sidecars ↔ shard) |
| first post-arc release and later | post-arc | the floor **plus** rebuilt-vs-published exe (presign-scoped) and image identity |

## reproduce.yml

```
gh workflow run reproduce.yml \
  -f tag=<vX.Y.Z> -f ruby_version=<e.g. 4.0.9> \
  -f platform=<linux-gnu|linux-musl|macos|windows> -f arch=<x86_64|arm64>
```

One dispatch verifies ONE published leg:

1. **era** — checks out the tag's tree (no build spend), decides the era
   (`ci/record-toolchain.sh` present?), and flows the leg's `host_id`
   from the tag's own `Platform.host_id_for` (the grammar's single
   owner).
2. **rebuild** (era=post only) — calls `_build-platform.yml` with
   `source_ref=<tag>` (every repo-self checkout rides it: the tag's exact
   build scripts, pins, and matrix vocabulary), `skip_codesign=true`
   (both signing gates force-disarm — the exe claim is pre-signing), and
   `publish=false`. **The run never touches the release** — no upload, no
   signature, no registry write; the leg's own gates (boot smoke,
   spawn-edge acceptance) run in full, and the rebuilt bytes ship only as
   a run artifact. The chain-gate checkouts (tamatebako/ruby,
   tamatebako/tebako) ride `main` by design: the verification tracks the
   CURRENT chain, and drift there is exactly what the watch exists to
   name.
3. **verdict** — `ci/reproduce-verdict.sh` renders the verdict table
   (step summary) and a JSON verdict artifact (30-day retention).

The verdict rows:

| row | severity | meaning |
|---|---|---|
| published exe/image ↔ `.sha256` sidecar | hard | the trust anchors verify the served bytes (every era) |
| shard sha256 fields ↔ sidecars | hard | the shard (a mirror) has not drifted from the anchors |
| rebuilt exe identity | hard | era=post: rebuilt exe vs `exe_sha256_presign` when the published exe is signed (presign ≠ published digest ⇒ signed leg), else vs the published exe digest directly; both diffs always report, the out-of-scope one informational |
| rebuilt image identity | hard | era=post: rebuilt `.tfs` vs the published image digest |
| source roll sha256, toolchain, abi | informational | the rebuilt contract card vs the shard — a red identity row's cause-of-death evidence (a moved roll = the chain drifted; a moved toolchain = the suspect list) |

A hard failure names the artifact, both hashes, and quotes the shard's
`built_from.toolchain` verbatim, then exits red. `gh run download` of the
run's `reproduce-verdict-*` artifact gives the machine-readable form.

## The weekly drift watch

`schedule: 17 3 * * 1` (Monday 03:17 UTC, default branch only — the
watch activates with the merge that lands this file). The schedule
self-dispatches a `workflow_dispatch` run for the latest non-shard
release's witness leg — **ruby 4.0.9 × linux-gnu × x86_64**, the leg the
arc's E2 twin-run proved byte-identical across two independent runners
(runs [44983654950](https://github.com/tamatebako/tebako-runtime-ruby/actions/runs/44983654950)
and [45000701327](https://github.com/tamatebako/tebako-runtime-ruby/actions/runs/45000701327),
both on `3e25a6a`: exe `4d858ae0…` == the published v0.17.15 exe, image
`206081a8…` identical across the pair). The dispatch indirection exists
because `compute_matrix.rb` ignores the ruby/arch filters under a
`schedule` event; every verification run stays filter-honored. Repin the
witness leg when `matrix.json`'s tidy vocabulary moves.

A red weekly run means the CURRENT chain drifted from what the release
was built against — read the verdict's informational rows first (roll
sha, toolchain diff), then the failing job.

## Per-leg status

The claim per leg of the current release line, with the run that proves
it. "Pending" legs carry the arc's full pins and are expected green; the
table links the proving dispatch once one exists (the weekly watch keeps
the witness leg's row current).

| leg | exe scope | status | proving dispatch |
|---|---|---|---|
| linux-gnu × x86_64 | published bytes (unsigned) | **proven** — E2 twin-run, byte-identical exe + image across runners | runs [44983654950](https://github.com/tamatebako/tebako-runtime-ruby/actions/runs/44983654950) + [45000701327](https://github.com/tamatebako/tebako-runtime-ruby/actions/runs/45000701327); weekly watch |
| linux-gnu × arm64 | published bytes (unsigned) | pending (same containerized recipe as the proven leg) | — |
| linux-musl × x86_64 | published bytes (unsigned) | pending | — |
| linux-musl × arm64 | published bytes (unsigned) | pending | — |
| macos × x86_64 | pre-signing digest (codesign rewrites the published exe) | pending — the E3 twin-run; brew floats recorded-not-pinned | — |
| macos × arm64 | pre-signing digest (codesign rewrites the published exe) | pending — the E3 twin-run; brew floats recorded-not-pinned | — |
| windows × ucrt64 | published bytes (unsigned today; re-scopes to presign automatically once Authenticode arms) | **partial by construction** — MSYS2 recorded-not-pinned: identity claimed only while the pacman resolution stands (the PE timestamp is `SOURCE_DATE_EPOCH`-fixed) | — |
| windows × ucrt-arm64 | published bytes (unsigned today; same re-scope) | partial by construction — as ucrt64 | — |

Pre-arc tags (≤ v0.17.15) verify the published-integrity floor on every
leg; their images stamped wall-clock time, so no identity claim exists
for them and none is made.

## Debugging a red verdict

1. The `::error::` names the artifact, the expected (published/presign)
   hash, and the rebuilt hash, and quotes the shard's
   `built_from.toolchain`.
2. Read the informational rows: a moved **source roll sha256** means the
   tamatebako/ruby roll drifted since the release (the chain gate rides
   `main`); a moved **toolchain** names the floating piece (runner image,
   brew, MSYS2).
3. Re-dispatch on ONE ref (the scope law — `actions/cache` never shares
   across refs; a same-key restore from the default branch is a warm arm,
   a cold scope pays the full build; both are valid evidence, and the
   verdict is identical either way).
4. The rebuild is byte-honest by construction: `publish=false` means no
   asset of the release can be created, replaced, or deleted by a
   verification run.
