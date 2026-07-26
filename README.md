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
`--src-release`/`--src-mirror` overrides, `--jobs`).

## Runtime filesystem image (item 30)

Every build also packs the assembled runtime layout tree — the exact tree
the runtime executable embeds as its memfs image — as a standalone DwarFS
image next to the executable:

```
runtime-packages/tebako-runtime-$(cat VERSION)-3.3.7-<platform>.tfs
```

The image-era lean flow mounts this file directly instead of extracting a
runtime layout (the runtime executable stays published and consumable as
before — backward compat). The image is written with the writer defaults
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
the shipped packages. `--no-image` skips the step. Both artifacts are
uploaded to the release; `manifest.json` folds the image into the package's
entry as an additive `image` key (`filename`/`sha256`/`size_bytes`), and
`SHA256SUMS.txt` carries both lines.

Image layout (same as the embedded memfs tree): `/lib/ruby/<api>` (stdlib),
`/lib/ruby/gems/<api>` (gem home, incl. the tebako-runtime gem),
`/local/stub.rb` (the runtime's compiled-in entry point), `/bin` (empty —
the ruby executable and the bin shims are stripped from the layout; the
interpreter is the outer driver executable that mounts the image, exactly
like the packaged-app path).

## Layout

- `VERSION` — the runtime contract version: package names and the release
  tag follow it (`v$(cat VERSION)`), and the gem's RuntimeManager resolves
  packages by exactly this version. Bump it in lockstep with the tebako gem
  version the produced runtimes serve.
- `build/` — the self-contained CMake build project (vendored from the
  tebako gem's runtime press driver, adapted to the pre-patched source):
  `CMakeLists.txt`, `cmake/`, `cmake-scripts/`, `src/tebako-main.cpp`,
  `include/tebako/`, codegen templates in `resources/`, and the Ruby build
  tooling in `lib/` + `tools/build_pass.rb`.
- `tools/build_runtime` — the build entry point (fetch → verify → build →
  package).
- `.github/workflows/build-runtime-packages.yml` — the version × platform
  matrix CI; `scripts/` holds the matrix generator and the hardened release
  assembly (`upload_release.rb`).
- `Brewfile` — macOS host build dependencies (CI).

## Specs

```sh
bundle install
bundle exec rspec
```
