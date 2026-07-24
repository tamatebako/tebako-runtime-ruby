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
