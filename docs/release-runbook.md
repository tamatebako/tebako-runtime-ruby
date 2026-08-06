# Release runbook — tebako-runtime-ruby

How a runtime release ships under the multi-staged hierarchy. Written after the
2026-08-03 incident night; every rule here has a production scar behind it.

## The moving parts

- `.github/build-graph.yaml` — the dependency tree. Every matrix decision is
  computed from it by `scripts/compute_matrix.rb`; never duplicate path logic
  into workflow `paths:` filters.
- `build-<platform>.yml` × 4 — the thin triggers (push/PR/dispatch).
- `_build-platform.yml` — the one per-platform unit: compute → build → publish.
- `publish.yml` — the coordinator (era baselines, audits, slice dispatches).
- `scripts/upload_release.rb` — the publish: manifest merge, content skip,
  convergence loop, completeness gate. Spec-locked in
  `spec/release_manager_spec.rb`.
- tebako-ci-containers — the toolchain images, tagged per factory VERSION.

## Normal operations

### Cut a new runtime release (VERSION bump)

1. **Tag the containers FIRST.** The container legs pull
   `ghcr.io/tamatebako/tebako-<image>:<VERSION>-<arch>`; a VERSION bump without
   the images fails every container leg with `manifest unknown`:

   ```sh
   gh api -X POST repos/tamatebako/tebako-ci-containers/dispatches \
     -f event_type='tebako release' -F 'client_payload[tag]=vX.Y.Z'
   ```

   Wait for `build-containers` to go green (both images × both arches).
2. PR the VERSION bump; merge when the tree-computed legs are green.
3. The merge push fires the four triggers with publish=true. Their publishes
   land the tidy set and merge the manifest.
4. Fire the era baseline when you want the full catalog:

   ```sh
   gh workflow run publish.yml -f ruby_filter=catalog -f platform=all -f publish=true
   ```

5. Audit (read-only, no builds):

   ```sh
   gh workflow run publish.yml -f ruby_filter=catalog -f platform=all -f audit=true -f publish=false
   ```

### Dispatch shapes (coordinator inputs)

- one ruby everywhere: `ruby_filter=4.0.6, platform=all`
- one platform, all rubies: `ruby_filter=full, platform=windows`
- one ruby on one platform: `ruby_filter=4.0.6, platform=windows`
- era baseline (every published version): `ruby_filter=catalog`
- dry run: `publish=false`; audit only: `audit=true` + `publish=false`

### A new ruby source release (pin bump)

tamatebako/ruby publishes `tfs-ruby-*-src` → `bump-source-pin.yml` opens the pin
PR → a human merges → the push that moves `DEFAULT_RELEASE` rebuilds **exactly
the versions whose tarballs moved** (the two pins' SHA256SUMS decide), on every
platform. No manual dispatch is needed; the `repository_dispatch 'tebako
release'` route exists for back-compat only.

## The invariants (learned 2026-08-03)

1. **Write a release's assets once.** Fresh-name CREATEs are reliable even
   during backend incidents; a delete+rewrite of an asset name can 422 for
   *hours* while replicas flap. The per-platform publishes tolerate this via
   the convergence loop (46-min budget) and content-skip, but during a
   declared-bad window prefer: builds-only dispatches (`publish=false`) → one
   single-pass publish when the backend recovers.
2. **Never hand-edit the manifest.** The per-platform publishes merge it; the
   era baseline regenerates every entry from fresh builds. If the manifest is
   corrupt but assets are intact, the repair is a republish, not an edit.
3. **The release is the store.** Assets persist; the manifest mirrors them.
   Consumers read the manifest; the `.sha256` sidecars are the trust anchor.
4. **Publishes serialize globally** (`publish-runtime-packages`, never
   cancel). The merge is read-modify-write; the serialization is what makes
   per-platform independence safe.
5. **A failed publish is always re-runnable** — content-skips make reruns
   cumulative-safe. Prefer rerunning over improvising.
6. **Check for stray dispatches before assuming a queue stall.** A lost
   `repository_dispatch 'tebako release'` against the factory fans out a
   full-catalog publish. `gh run list --workflow publish.yml` shows them.

## Incident field notes (2026-08-03)

- Symptom: uploads time out but land; retries 422 `already_exists`;
  listings and the download edge disagree for minutes; a deleted name 422s
  re-uploads for hours. Diagnosis path: by-id delete → 204/404 on the
  primary while another replica still lists it. There is no in-band fix —
  budgeted convergence + single-pass republish is the playbook.
- The status page said "All Systems Operational" through the whole thing.
  Trust probes (by-id GET after DELETE, a served-content sha compare), not
  the page.
- API clients: `gh pr`/`gh run` (GraphQL) EOF'd while `gh api` (REST)
  answered; git pushes needed the https+token form with retries while ssh:22
  was refused. A token can also be edge-blocked per-IP (connections die
  after the Authorization header; unauthenticated 200s, garbage-token 401s) —
  an IP change cleared it.
