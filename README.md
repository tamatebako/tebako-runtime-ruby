# tebako-runtime-ruby

Builds and publishes the prebuilt tebako Ruby runtime packages
(`tebako-runtime-<tebako-version>-<ruby-version>-<platform>`) that the
tebako gem resolves at press/run time.

## How a runtime is built

The build input is the **pre-patched ruby source** published by
[tamatebako/ruby](https://github.com/tamatebako/ruby) as the
`tfs-ruby-<version>-src.tar.gz` release assets (verified against the
release `SHA256SUMS`). The runtime links the prebuilt
[libtfs](https://github.com/tamatebako/libtfs) package and embeds the
modern `tebako_fs_*` entry driver (vendored in `build/src`).

```sh
tools/build_runtime --ruby 3.3.7
```

produces `runtime-packages/tebako-runtime-$(cat VERSION)-3.3.7-<platform>`
(see `tools/build_runtime --help` for options: output path, build prefix,
`--src-release`/`--src-mirror` overrides, `--patchelf`, `--jobs`).

## Runtime filesystem image (item 30)

Every build also packs the assembled runtime layout tree — the exact tree
the v1 runtime executable embedded as its memfs image — as a standalone
DwarFS image next to the executable:

```
runtime-packages/tebako-runtime-$(cat VERSION)-3.3.7-<platform>.tfs
```

**Image era (item 30b, the default):** the executable ships WITHOUT the
embedded incbin image — the standalone `.tfs` is the runtime's only
filesystem image, and the entry driver mounts the file
`TEBAKO_RUNTIME_IMAGE` names (an image-era tebako bootstrap sets it after
resolving the sha256-verified `.tfs` into the shared cache; the v1 handoff
is unchanged). Standalone use — including `--tebako-extract` — therefore
takes the variable explicitly:

```sh
TEBAKO_RUNTIME_IMAGE=$PWD/runtime-packages/tebako-runtime-$(cat VERSION)-3.3.7-<platform>.tfs \
  runtime-packages/tebako-runtime-$(cat VERSION)-3.3.7-<platform> --tebako-extract layout
```

Without the variable (and no embedded image) the driver fails startup with
a message naming the expected handoff; v1 runtimes — the published 0.15.9
executables, or anything built `--embed-image` — ignore the variable and
mount the embedded image exactly as before (graceful degradation, no
republish needed). The variable wins wherever it is set, so an embedded
build also mounts the named image.

The image is written with the writer defaults
(mkdwarfs compression level 7) by our own factory toolchain:

1. `tfs mkimage --format dwarfs` (the tebako-rs tfs-cli binary) when one
   resolves — `--tfs PATH`, then `TEBAKO_TFS`, then `tfs` on `PATH`. It is
   pointed at the build's own SHA256-verified `mkdwarfs` via `--mkdwarfs`
   so the embedded image and the standalone image share one writer.
2. Otherwise the build's own `deps/bin/mkdwarfs` directly — the same
   prebuilt binary the deploy pass already uses for the embedded image
   (tfs-cli's `mkimage` is a wrapper over exactly this invocation until it
   binds the writer API in-process).

Both are build-time factory tools; neither becomes a runtime dependency of
the shipped packages. `--no-image` skips the step (only meaningful with
`--embed-image`, the v1 shape — an image-era executable without the `.tfs`
cannot boot); `--embed-image` embeds the image into the executable instead
(v1 backward-compat shape: the variable is honored when set, the embedded
image otherwise). Both artifacts are
uploaded to the release; `manifest.json` folds the image into the package's
entry as an additive `image` key (`filename`/`sha256`/`size_bytes`), and
`SHA256SUMS.txt` carries both lines.

Image layout (same as the embedded memfs tree): `/lib/ruby/<api>` (stdlib),
`/lib/ruby/gems/<api>` (gem home — spec 22 phase M2: the env image ships
NO tebako-runtime gem; the Rust driver covers the VFS),
`/local/stub.rb` (the runtime's compiled-in entry point), `/bin` (empty —
the ruby executable and the bin shims are stripped from the layout; the
interpreter is the outer driver executable that mounts the image, exactly
like the packaged-app path).

## The windows ruby DLL (issue 40)

The windows-ucrt64 runtime is `--enable-shared` (the standard ruby-mingw
shape; every other platform stays `--disable-shared`): the ruby core and
the tebako closure link into `x64-ucrt-ruby<ABI>.dll`, and the runtime
executable imports it — a `--disable-shared` exe exports zero symbols and
ships no DLL, so no dynamically linked native extension could ever bind.
The memfs mount table exists exactly once per process, in the DLL; the
exe's driver reaches it through the DLL's `tebako_fs_*` exports.

The DLL is the third artifact of a windows package:

- it is built as `x64-ucrt-ruby<ABI>.dll` in the ruby tree and staged as
  `<runtime>.dll` (the package name — two same-ABI legs share the PE name
  and would collide in the merged release workspace);
- the store entry holds it next to the exe **under the PE name**
  (`x64-ucrt-ruby<ABI>.dll`): the PE loader resolves the exe's imports
  against the exe's own directory first, so interpreter and extensions
  bind without PATH games. The manifest's additive `dll` key flows the
  mapping (`filename` = the asset, `install_as` = the PE name, plus
  `sha256`/`size_bytes`; consumers ignoring the key keep working, same
  rule as `image`), and `SHA256SUMS.txt` carries the line;
- the env image does NOT carry the DLL (`bin/` is stripped from the
  layout — a DLL inside the read-only memfs would be dead weight: PE
  imports never resolve against it).

The leg proves the wiring before the artifacts leave CI: the windows
boot smoke materializes the PE-named copy next to the exe (the store
entry's shape) and loads racc's `cparse.so` from the image — a real
`LoadLibrary` bind of an in-image PE extension against the DLL
(`spec/boot_smoke_spec.rb`, the `native_ext` scenario).

## Bootstrap ↔ runtime contract version (roadmap 45)

The bootstrap (released from tamatebako/tebako) and the runtime images
published here version independently, so the protocol between them — the
env vars passed down, the argv layout, the filesystem-image handoff — is
versioned as an integer **contract**. Contract 1 pins today's semantics
exactly; current behavior IS the contract.

Two representations, locked in agreement by CI
(`scripts/check_contract_version.rb`, run in the prepare job before the
matrix builds, and by `spec/contract_spec.rb`):

- `contract.yml` (schema: `schema/contract.schema.yml`) — the release
  pipeline's single source of truth. `scripts/upload_release.rb` emits it
  as an additive `contract_version` key in every `manifest.json` package
  entry (consumers ignoring the key keep working, same rule as `image`).
- `TEBAKO_CONTRACT_VERSION` in `build/src/tebako-main.cpp` — the constant
  compiled into the runtime itself. The driver exports it as the
  `TEBAKO_CONTRACT_VERSION` environment variable before the entry dispatch,
  so the packaged context (and any driver-stage tooling) can read the
  contract the runtime speaks.

**Bump rules:** any change to env/argv/handoff semantics bumps the integer
by exactly +1 in BOTH places, same commit — the agreement check fails the
build otherwise. The bootstrap side (negotiation, `min_contract..max_contract`
range, `ContractMismatch` named error) lives in the tebako-rs workspace; the
version → semantics changelog table is spec 06's.

## Layout

- `VERSION` — the package version: package names and the release tag follow
  it (`v$(cat VERSION)`), and the gem's RuntimeManager resolves packages by
  exactly this version. Bump it in lockstep with the tebako gem version the
  produced runtimes serve. (Not the roadmap-45 contract version — that one
  lives in `contract.yml`.)
- `contract.yml` + `schema/` — the bootstrap ↔ runtime contract version
  (roadmap 45) and its JSON schema; `scripts/check_contract_version.rb`
  locks it against the compiled-in constant (see the contract section above).
- `build/` — the self-contained CMake build project (vendored from the
  tebako gem's runtime press driver, adapted to the pre-patched source):
  `CMakeLists.txt`, `cmake/`, `cmake-scripts/`, `src/tebako-main.cpp`,
  `include/tebako/`, codegen templates in `resources/`, and the Ruby build
  tooling in `lib/` + `tools/build_pass.rb`.
- `tools/build_runtime` — the build entry point (fetch → verify → build →
  package).
- `.github/workflows/` — the multi-staged hierarchy: `_build-platform.yml`
  (the one per-platform build/publish unit), the four thin platform
  triggers (`build-<platform>.yml`), and `publish.yml` (the release
  coordinator — one version everywhere / one platform all versions / one
  version on one platform, via workflow dispatch). `scripts/` holds the
  dependency-tree matrix computer (`compute_matrix.rb`, walking
  `.github/build-graph.yaml`) and the hardened per-platform release
  assembly (`upload_release.rb` — manifest merge, idempotent skip, audit).
  **The architecture and the cache/determinism invariants are documented
  in `docs/build-chain.md` — read it before touching any workflow, the
  roll tooling, or a cache key.**
- `Brewfile` — macOS host build dependencies (CI).

## Specs

```sh
bundle install
bundle exec rspec
```

### Runtime boot smoke (roadmap item 19)

`spec/boot_smoke_spec.rb` (tag `:boot_smoke`) boots a built runtime
executable and exercises the memfs syscall surface from inside the
packaged context — stat/lstat/fstat + btime (the ruby-4.0-linux statx
case), image IO and `$LOAD_PATH` resolution, gem home + bundler (incl.
bundler's process lock degrading to no-lock on the read-only gem home),
and `File#flock` — the statx/fcntl/flock drift class, caught at build
time.

Point `TEBAKO_RUNTIME_ROOT` at a runtime root — a directory holding
exactly one `tebako-runtime-*` executable (a build leg's
`runtime-packages/`, a tebako-home runtime cache dir) or the executable
path itself (a bare layout tree or a mounted filesystem image carries no
interpreter, so it is never a valid root) — and run:

```sh
TEBAKO_RUNTIME_ROOT=runtime-packages bundle exec rspec --tag boot_smoke
```

Without the variable the class skips in a plain run and fails loudly when
targeted explicitly. CI runs the tag against each freshly built runtime
before the artifact upload (`.github/workflows/_build-platform.yml`).
