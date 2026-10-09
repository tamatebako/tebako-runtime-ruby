# tebako-runtime-ruby

The tebako Ruby runtime factory. This repository builds the prebuilt Ruby
runtime packages that tebako packages run on, and publishes them as
releases.

## Objective

tebako packages a Ruby application into a single executable by stitching
the app onto a prebuilt runtime. Someone has to build that runtime once,
per Ruby version and per platform, so that packagers and end users never
compile anything. That someone is this repository.

## What this repository consumes

- **Pre-patched Ruby source releases** from
  [tamatebako/ruby](https://github.com/tamatebako/ruby): one
  `tfs-ruby-<version>-src.tar.gz` asset per supported Ruby version (plus
  per-platform scenario variants), verified against the release's
  `SHA256SUMS`. The pin lives in
  `build/lib/tebako_runtime_builder/source_fetcher.rb`
  (`DEFAULT_RELEASE`); a dispatch from the source factory bumps it by
  pull request, and the same pull request extends the build vocabulary
  (`tools/sync_matrix_vocabulary.rb`), so onboarding a Ruby version is a
  source-factory release with no manual edits here.
- **The tebako driver stack** (link unit) and the **`tfs` image CLI** from
  [tamatebako/tebako](https://github.com/tamatebako/tebako) releases,
  pinned by `contract.yml`'s `link_unit_release` and verified against the
  release's checksum sidecars.
- **CI containers** from tebako-ci-containers for the Linux legs.

Releases are the interface everywhere: this repository never consumes
another project's source tree.

## What this repository produces

Each release tag `v$(cat VERSION)` carries, per Ruby version × platform:

- **the runtime executable**
  (`tebako-runtime-<tebako-version>-ruby-<ruby-version>-<platform>`) — the
  interpreter with the tebako driver linked in;
- **the runtime filesystem image** (`<runtime>.tfs`) — the Ruby standard
  library and gems as a single mountable image, shipped next to the
  executable (the executable mounts it at boot; nothing is extracted);
- **the Windows Ruby DLL** (`<runtime>.dll`) on Windows only, where the
  runtime is a shared build so native extensions can bind against it;
- **a `.sha256` sidecar next to every served asset** — the trust anchor
  resolvers verify downloads against;
- **a `.manifest.json` shard per package** — the package's manifest entry
  (versions, checksums, sizes, mount root, image layout, build
  provenance, contract version, and the image/DLL companions);
- **detached OpenPGP signatures** (`.asc`) for every served name on
  signing-enabled lines.

The machine-readable resolution index is this repository's
**`tpkg-registry.yaml`** on the main branch, rendered from the release's
shards by the publish pipeline (`tools/registry_update.rb`) and landed by
bot pull request — never hand-edited, except `status: withdrawn` marks.

Older release lines are immutable: packages published under the
`<= 0.16.32` lines keep their original
`tebako-runtime-<tebako-version>-<ruby-version>-<platform>` spelling (no
`ruby` language segment) and stay installable forever; release lines
`>= 0.17.0` compose the name with the language segment. Tooling accepts
both spellings.

## The release contract

- **Byte-immutable payloads.** A published payload asset never changes
  under its name. Metadata (checksums, shards) is derivable and may be
  regenerated, but always describes the bytes actually served.
- **Contract version.** The loader ↔ runtime protocol (environment
  variables, argument layout, image handoff) is versioned as an integer
  in `contract.yml` (schema in `schema/`), locked in CI against the
  constant compiled into the runtime itself. A semantic change to that
  protocol bumps the integer by exactly one in both places in the same
  commit.
- **Verification at fetch, never per run.** Downloads are verified
  against the `.sha256` sidecars when they are installed into the local
  store; running a package performs no verification and no installation.
- **Every leg is gated before upload.** A freshly built runtime is
  boot-smoked in its own CI leg (see below); a failed smoke blocks the
  upload, and the publish pipeline fails loudly on any missing artifact.

## The build matrix

The platform and Ruby vocabulary lives in `.github/matrix.json`;
`scripts/compute_matrix.rb` derives each run's legs from
`.github/build-graph.yaml` (a leg runs only when something it reads
changed). The Ruby version sets are extended automatically on each
source-factory release (see "What this repository consumes").

Platforms today: linux-gnu and linux-musl, macOS, and Windows (ucrt64),
each on x86_64 and arm64 where the upstream and driver support holds.
The windows/arm64 leg is wired but stays disabled until the product
publishes the arm64 Windows link unit; publish runs additionally require
the `TEBAKO_SERVE_WINDOWS_ARM64` repository variable.

## Building a runtime locally

```sh
tools/build_runtime --ruby 3.3.7
```

produces `runtime-packages/tebako-runtime-$(cat VERSION)-3.3.7-<platform>`
plus its `.tfs` image (see `tools/build_runtime --help` for output path,
build prefix, source mirror/release overrides, and parallelism).

Running the executable standalone needs the image handoff:

```sh
TEBAKO_RUNTIME_IMAGE=$PWD/runtime-packages/<runtime>.tfs \
  runtime-packages/<runtime> --tebako-extract layout
```

## CI layout

`.github/workflows/` holds a multi-staged hierarchy:
`_build-platform.yml` (the per-platform build/publish unit), four thin
platform triggers (`build-<platform>.yml`), `bump-source-pin.yml` (the
source-release pin bump), and `publish.yml` (the release coordinator).
The architecture, cache layout, and determinism invariants are documented
in `docs/build-chain.md` — read it before touching any workflow, the roll
tooling, or a cache key.

## Layout

- `VERSION` — the package version: package names and the release tag
  follow it (`v$(cat VERSION)`).
- `contract.yml` + `schema/` — the loader ↔ runtime contract version and
  its JSON schema; `scripts/check_contract_version.rb` locks it against
  the compiled-in constant.
- `build/` — the self-contained CMake build project (adapted to the
  pre-patched source): `CMakeLists.txt`, `cmake/`, `cmake-scripts/`,
  `src/`, `include/`, codegen templates in `resources/`, and the Ruby
  build tooling in `lib/`.
- `tools/build_runtime` — the build entry point (fetch → verify → build →
  package); `tools/registry_update.rb` renders the registry mirror from a
  release's shards; `tools/sync_matrix_vocabulary.rb` keeps the dispatch
  vocabulary in step with the source factory's releases.
- `Brewfile` — macOS host build dependencies (CI).

## Specs

```sh
bundle install
bundle exec rspec
```

### Runtime boot smoke

`spec/boot_smoke_spec.rb` (tag `:boot_smoke`) boots a built runtime
executable and exercises the packaged context from inside: the virtual
filesystem syscall surface, image IO and `$LOAD_PATH` resolution, gem
home and bundler, file locking, the openssl canary, dynamic extension
loading, the JIT support matrix, and a compiled magnus (Ruby/Rust)
extension fixture that proves the executable's export surface serves the
ruby-rust gem ecosystem.

Point `TEBAKO_RUNTIME_ROOT` at a runtime root — a directory holding
exactly one `tebako-runtime-*` executable (a build leg's
`runtime-packages/`, a tebako-home runtime cache dir) or the executable
path itself — and run:

```sh
TEBAKO_RUNTIME_ROOT=runtime-packages bundle exec rspec --tag boot_smoke
```

Without the variable the class skips in a plain run and fails loudly when
targeted explicitly. CI runs the tag against each freshly built runtime
before the artifact upload.
