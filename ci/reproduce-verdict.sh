#!/usr/bin/env bash
# ci/reproduce-verdict.sh — the verdict half of .github/workflows/reproduce.yml.
# Verifies ONE published release leg against (a) its own trust anchors and
# (b) this run's rebuild of the same leg from the tag's exact tree, then
# renders the verdict table (the step summary) and verdict.json (the
# workflow uploads it as an artifact).
#
# What is checked, in order:
#   1. PUBLISHED INTEGRITY (every era): the leg's exe / image download from
#      the release and sha256-verify against their published .sha256
#      sidecars (the trust anchors), and the manifest shard's own sha256
#      fields are proven IN SYNC with those sidecars (the shard is a
#      mirror, never the anchor).
#   2. REBUILT IDENTITY (era=post only — the tag's tree carries the
#      reproducible-build arc): the exe + image rebuilt in THIS run are
#      hashed from the leg's runtime-packages artifact and diffed:
#        - exe: when the shard's built_from.exe_sha256_presign differs from
#          the published exe digest, the published exe is a SIGNED
#          post-image (macOS codesign today; windows Authenticode once
#          spec 34 arms) and the hard compare scopes to the presign
#          digest — signing rewrites the exe after that digest by design.
#          Otherwise the leg shipped unsigned and the hard compare is
#          against the published bytes directly. Both diffs are always
#          reported (the out-of-scope one informational).
#        - image: rebuilt .tfs vs the published image digest, always hard.
#      A hard mismatch fails the run naming the artifact + both hashes and
#      quoting the shard's built_from.toolchain block verbatim (the first
#      suspect list).
#   3. PROVENANCE (informational, never fatal): the rebuilt contract card's
#      built_from.sources vs the shard's (a mismatch means the chain-gate
#      source roll moved since the release — the cause a red identity row
#      names), the rebuilt .abi vs the shard's abi, and the rebuilt
#      toolchain block vs the shard's.
#
# Era law: a tag whose tree predates the reproducible-build arc carries no
# ci/record-toolchain.sh — the current workflow cannot rebuild it, and its
# image stamped wall-clock time (no SOURCE_DATE_EPOCH honor) could never
# byte-reproduce anyway. era=pre therefore skips the identity rows loudly
# and the run stands on the published-integrity floor.
#
# Required env: GH_TOKEN, TAG, RUBY_VERSION, PLATFORM, ARCH, HOST_ID
# (flowed from the tag's own Platform.host_id_for by the era job — never
# re-derived here), ERA (pre|post), REBUILD_RESULT (the rebuild job's
# result), REBUILD_RUN (the rebuild's compute run output), GITHUB_RUN_ID,
# GITHUB_STEP_SUMMARY. Writes verdict.json in the cwd. Exit 0 = no hard
# row failed; 1 = a hard row failed or the inputs/release are incoherent
# (every failure is a named ::error:: first).
set -euo pipefail

REPO="tamatebako/tebako-runtime-ruby"

for v in GH_TOKEN TAG RUBY_VERSION PLATFORM ARCH HOST_ID ERA REBUILD_RESULT GITHUB_RUN_ID GITHUB_STEP_SUMMARY; do
  [ -n "${!v:-}" ] || { echo "::error::ci/reproduce-verdict.sh: $v is unset"; exit 1; }
done
for tool in gh jq sha256sum ruby; do
  command -v "$tool" >/dev/null 2>&1 || { echo "::error::ci/reproduce-verdict.sh: $tool not on PATH"; exit 1; }
done
case "$ERA" in
  pre|post) : ;;
  *) echo "::error::ci/reproduce-verdict.sh: ERA must be pre|post, got '$ERA' (the era job failed?)"; exit 1 ;;
esac

rows_jsonl="$(pwd)/rows.jsonl"
: > "$rows_jsonl"
failures=0

row() { # row <check> <expected> <actual> <pass|fail|skip|info> [note]
  jq -nc --arg name "$1" --arg expected "$2" --arg actual "$3" --arg result "$4" --arg note "${5:-}" \
    '{check: $name, expected: $expected, actual: $actual, result: $result, note: $note}' >> "$rows_jsonl"
  [ "$4" = "fail" ] && failures=$((failures + 1)) || true
}

quote_toolchain() { # the shard's toolchain block, verbatim, for a red row
  if [ -n "${toolchain:-}" ]; then
    echo "$toolchain" | jq .
  else
    echo "(absent in this era's shard — the toolchain record landed with the reproducible-build arc)"
  fi
}

hard_mismatch() { # hard_mismatch <artifact> <expected> <actual>
  echo "::error::reproducibility mismatch on $1: expected $2, rebuilt $3 — the shard's built_from.toolchain (the first suspect list):"
  quote_toolchain
  echo "::error::end of toolchain block for $1"
}

finish() { # finish <exit-code> <green|red>
  local code="$1" word="$2"
  jq -n --arg tag "$TAG" --arg ruby "$RUBY_VERSION" --arg platform "$PLATFORM" --arg arch "$ARCH" \
        --arg host_id "$HOST_ID" --arg era "$ERA" --arg verdict "$2" \
        --arg run "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID}" \
        --slurpfile rows "$rows_jsonl" \
        '{tag: $tag, ruby: $ruby, platform: $platform, arch: $arch, host_id: $host_id,
          era: $era, verdict: $verdict, run: $run, checks: $rows}' > verdict.json
  {
    echo "## reproduce verdict — \`$TAG\` · ruby $RUBY_VERSION · $PLATFORM · $ARCH"
    echo
    echo "- leg host_id: \`$HOST_ID\`"
    echo "- tag era: \`$ERA\` (the reproducible-build arc's machinery in the tag's tree)"
    echo "- verdict: **$word**"
    echo
    echo "| check | expected | actual | result |"
    echo "|---|---|---|---|"
    jq -rs '.[] | "| " + .check + " | `" + .expected + "` | `" + .actual + "` | **" + .result + "** |"' "$rows_jsonl"
    echo
    noted=$(jq -rs '.[] | select(.note != "") | "- **" + .check + "**: " + .note' "$rows_jsonl")
    if [ -n "$noted" ]; then
      echo "### Notes"
      echo
      echo "$noted"
    fi
    if [ -n "${toolchain:-}" ]; then
      echo
      echo "### The shard's built_from.toolchain (the first suspect list on a red row)"
      echo
      echo '```json'
      echo "$toolchain" | jq .
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
  exit "$code"
}

die() { # die <message> — a named hard failure independent of the row flow
  echo "::error::$1"
  row "verdict" "" "" fail "$1"
  finish 1 red
}

echo "== reproduce verdict: $TAG / ruby $RUBY_VERSION / $PLATFORM / $ARCH ($HOST_ID), era=$ERA, rebuild=$REBUILD_RESULT"

# --- locate the leg's shard on the release (era-invariant: the tail
# -<ruby>-<host_id>.manifest.json matches both the pre- and post-tebako#716
# name grammars, and the segment-anchored ruby version cannot
# substring-collide with another version) -------------------------------
if ! assets="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')"; then
  die "release $TAG not found (or unreadable) in $REPO"
fi
ruby_rx="${RUBY_VERSION//./\\.}" # literal dots — the tail match must not regex-collide across versions
shard_assets="$(printf '%s\n' "$assets" | grep -E -- "-${ruby_rx}-${HOST_ID}\.manifest\.json$" || true)"
if [ "$(printf '%s\n' "$shard_assets" | grep -c .)" != "1" ]; then
  echo "::error::expected exactly one *-${RUBY_VERSION}-${HOST_ID}.manifest.json asset on $TAG, found:"
  printf '%s\n' "$shard_assets"
  echo "::error::the release carries these ${HOST_ID} shards:"
  printf '%s\n' "$assets" | grep -- "-${HOST_ID}\.manifest\.json$" || echo "(none)"
  die "no unique shard for ruby $RUBY_VERSION on $HOST_ID — the (ruby, platform, arch) triple names no published leg of $TAG"
fi
shard_asset="$shard_assets"
echo "== shard: $shard_asset"

mkdir -p published rebuilt
gh release download "$TAG" --repo "$REPO" --pattern "$shard_asset" --dir published --clobber
shard="published/$shard_asset"

exe_name="$(jq -r '.filename' "$shard")"
exe_sha="$(jq -r '.sha256' "$shard")"
img_name="$(jq -r '.image.filename' "$shard")"
img_sha="$(jq -r '.image.sha256' "$shard")"
presign="$(jq -r '.built_from.exe_sha256_presign // empty' "$shard")"
toolchain="$(jq -c '.built_from.toolchain // empty' "$shard")"
shard_src_sha="$(jq -r '.built_from.sources[0].sha256 // empty' "$shard")"
shard_abi="$(jq -r '.abi // empty' "$shard")"

[ "$(jq -r '.ruby_version' "$shard")" = "$RUBY_VERSION" ] ||
  die "the shard's ruby_version is $(jq -r '.ruby_version' "$shard"), not $RUBY_VERSION — the inputs are incoherent"
[ "$(jq -r '.tebako_version' "$shard")" = "${TAG#v}" ] ||
  die "the shard's tebako_version is $(jq -r '.tebako_version' "$shard"), not ${TAG#v} — the tag input names the wrong release line"

# --- 1. published integrity (the era-invariant floor) -------------------
for a in "$exe_name" "$exe_name.sha256" "$img_name" "$img_name.sha256"; do
  printf '%s\n' "$assets" | grep -qx "$a" ||
    die "the shard names $a but $TAG does not serve it — the release and its shard disagree (drift)"
  gh release download "$TAG" --repo "$REPO" --pattern "$a" --dir published --clobber
done

if (cd published && sha256sum -c "$exe_name.sha256"); then
  row "published exe ↔ .sha256 sidecar" "$exe_sha" "$exe_sha" pass "the trust anchor verifies the served bytes"
else
  echo "::error::the published exe $exe_name fails its own .sha256 sidecar on $TAG — the anchor and the bytes disagree"
  row "published exe ↔ .sha256 sidecar" "$(cut -d' ' -f1 < "published/$exe_name.sha256")" \
      "$(sha256sum "published/$exe_name" | cut -d' ' -f1)" fail "the trust anchor does not verify the served bytes"
fi
if (cd published && sha256sum -c "$img_name.sha256"); then
  row "published image ↔ .sha256 sidecar" "$img_sha" "$img_sha" pass "the trust anchor verifies the served bytes"
else
  echo "::error::the published image $img_name fails its own .sha256 sidecar on $TAG — the anchor and the bytes disagree"
  row "published image ↔ .sha256 sidecar" "$(cut -d' ' -f1 < "published/$img_name.sha256")" \
      "$(sha256sum "published/$img_name" | cut -d' ' -f1)" fail "the trust anchor does not verify the served bytes"
fi

sidecar_exe_sha="$(cut -d' ' -f1 < "published/$exe_name.sha256")"
sidecar_img_sha="$(cut -d' ' -f1 < "published/$img_name.sha256")"
if [ "$exe_sha" = "$sidecar_exe_sha" ]; then
  row "shard exe sha256 ↔ sidecar" "$sidecar_exe_sha" "$exe_sha" pass "the shard mirrors the anchor"
else
  echo "::error::the shard's exe sha256 ($exe_sha) disagrees with the published sidecar ($sidecar_exe_sha) — the mirror drifted from the anchor"
  row "shard exe sha256 ↔ sidecar" "$sidecar_exe_sha" "$exe_sha" fail "the shard drifted from the trust anchor"
fi
if [ "$img_sha" = "$sidecar_img_sha" ]; then
  row "shard image sha256 ↔ sidecar" "$sidecar_img_sha" "$img_sha" pass "the shard mirrors the anchor"
else
  echo "::error::the shard's image sha256 ($img_sha) disagrees with the published sidecar ($sidecar_img_sha) — the mirror drifted from the anchor"
  row "shard image sha256 ↔ sidecar" "$sidecar_img_sha" "$img_sha" fail "the shard drifted from the trust anchor"
fi

# --- 2./3. rebuilt identity + provenance (era=post only) ----------------
if [ "$ERA" = "pre" ]; then
  row "rebuilt exe identity" "" "" skip \
    "tag predates the reproducible-build arc: its tree carries no ci/record-toolchain.sh and its image stamps wall-clock time (no SOURCE_DATE_EPOCH honor), so the bytes can never reproduce — this run stands on the published-integrity floor"
  row "rebuilt image identity" "" "" skip "same era gap as the exe row"
  echo "::notice::$TAG predates the reproducible-build arc — published-integrity floor only (the identity rows light up on the first post-arc release)"
  if [ "$failures" -eq 0 ]; then finish 0 green; else finish 1 red; fi
fi

case "$REBUILD_RESULT" in
  success) : ;;
  failure|cancelled)
    row "rebuild job" "success" "$REBUILD_RESULT" fail "the tag-tree rebuild went red — see this run's rebuild job log"
    die "the rebuild job $REBUILD_RESULT — no rebuilt bytes to diff (the published-integrity rows above still stand)"
    ;;
  *)
    row "rebuild job" "success" "$REBUILD_RESULT" fail "era=post but the rebuild job did not run to success — a workflow-logic fault, not drift"
    die "era=post yet rebuild result is '$REBUILD_RESULT'"
    ;;
esac

if [ "${REBUILD_RUN:-}" != "true" ]; then
  die "the rebuild's compute stage ran with run='${REBUILD_RUN:-}': the (ruby $RUBY_VERSION, $PLATFORM, $ARCH) leg does not exist at $TAG (deferred in its matrix.json, or filtered out)"
fi

artifact="runtime-packages-${PLATFORM}-${ARCH}-${RUBY_VERSION}"
echo "== downloading this run's rebuilt artifact: $artifact"
if ! gh run download "$GITHUB_RUN_ID" --repo "$REPO" --name "$artifact" --dir rebuilt; then
  echo "::error::artifact $artifact not found on this run; the run carries:"
  gh api "repos/$REPO/actions/runs/$GITHUB_RUN_ID/artifacts" --jq '.artifacts[].name' || true
  die "no rebuilt artifact $artifact — the leg did not upload (a red leg gates the upload by design)"
fi
[ -f rebuilt/.leg-complete ] ||
  die "the rebuilt artifact lacks .leg-complete — the leg's gates did not all pass, so its bytes prove nothing"

rebuilt_exe="rebuilt/$(basename "$exe_name")"
[ -s "$rebuilt_exe" ] || rebuilt_exe="$rebuilt_exe.exe" # the windows artifact once shipped the .exe spelling
[ -s "$rebuilt_exe" ] || die "the rebuilt artifact carries no $(basename "$exe_name")[.exe]"
rebuilt_img="rebuilt/$(basename "$img_name")"
[ -s "$rebuilt_img" ] || die "the rebuilt artifact carries no $(basename "$img_name")"
rebuilt_exe_sha="$(sha256sum "$rebuilt_exe" | cut -d' ' -f1)"
rebuilt_img_sha="$(sha256sum "$rebuilt_img" | cut -d' ' -f1)"

# The exe row's scope (see the header): a shard whose presign digest differs
# from the published exe digest records a SIGNED leg — the hard compare is
# the presign digest; otherwise the leg shipped unsigned and the published
# bytes themselves are the claim. Both diffs always report.
if [ -n "$presign" ] && [ "$presign" != "$exe_sha" ]; then
  exe_scope="pre-signing digest (the published exe is signed — signing rewrites the bytes after this digest by design)"
  exe_expected="$presign"
else
  exe_scope="published exe digest (the leg shipped unsigned — the published bytes are the claim)"
  exe_expected="$exe_sha"
fi
if [ "$rebuilt_exe_sha" = "$exe_expected" ]; then
  row "rebuilt exe identity" "$exe_expected" "$rebuilt_exe_sha" pass "$exe_scope"
else
  hard_mismatch "$exe_name" "$exe_expected" "$rebuilt_exe_sha"
  row "rebuilt exe identity" "$exe_expected" "$rebuilt_exe_sha" fail "$exe_scope"
fi
if [ -n "$presign" ]; then
  if [ "$exe_expected" = "$presign" ]; then
    other="$exe_sha"; other_note="the published (signed) exe — expected to differ: signing rewrote the bytes after the presign digest"
  else
    other="$presign"; other_note="the shard's built_from.exe_sha256_presign — equals the published digest on this unsigned leg"
  fi
  if [ "$rebuilt_exe_sha" = "$other" ]; then
    row "rebuilt exe vs the other digest" "$other" "$rebuilt_exe_sha" info "$other_note"
  else
    row "rebuilt exe vs the other digest" "$other" "$rebuilt_exe_sha" info "$other_note (differs)"
  fi
fi

if [ "$rebuilt_img_sha" = "$img_sha" ]; then
  row "rebuilt image identity" "$img_sha" "$rebuilt_img_sha" pass "rebuilt .tfs vs the published image digest"
else
  hard_mismatch "$img_name" "$img_sha" "$rebuilt_img_sha"
  row "rebuilt image identity" "$img_sha" "$rebuilt_img_sha" fail "rebuilt .tfs vs the published image digest"
fi

# --- provenance (informational) ------------------------------------------
card="rebuilt/$(basename "$exe_name").contract.yaml"
[ -s "$card" ] || card=""
if [ -n "$card" ]; then
  card_json="$(ruby -ryaml -rjson -e 'print JSON.generate(YAML.load_file(ARGV[0]))' "$card")"
  card_src_sha="$(printf '%s' "$card_json" | jq -r '.built_from.sources[0].sha256 // empty')"
  card_toolchain="$(printf '%s' "$card_json" | jq -c '.built_from.toolchain // empty')"
  if [ -n "$shard_src_sha" ] && [ "$card_src_sha" = "$shard_src_sha" ]; then
    row "source roll sha256 (rebuilt card ↔ shard)" "$shard_src_sha" "$card_src_sha" info "the chain-gate roll did not move between the release and this rebuild"
  else
    row "source roll sha256 (rebuilt card ↔ shard)" "$shard_src_sha" "$card_src_sha" info \
      "DIFFERS — the chain-gate source roll moved since the release (tamatebako/ruby@main is pinned by design); a red identity row above names this drift"
  fi
  if [ -n "$card_toolchain" ] && [ "$card_toolchain" = "$toolchain" ]; then
    row "toolchain identity (rebuilt card ↔ shard)" "match" "match" info "the recorded toolchains are identical"
  else
    row "toolchain identity (rebuilt card ↔ shard)" "see the shard block below" "$card_toolchain" info \
      "the recorded toolchains differ — on a red identity row this is the suspect list (a floating runner image or brew/MSYS2 resolution is the usual mover)"
  fi
else
  row "contract card" "present" "absent" fail "era=post yet the rebuilt artifact carries no .contract.yaml — the arc's provenance sidecar chain broke"
fi

abi_file="rebuilt/$(basename "$exe_name").abi"
if [ -s "$abi_file" ] && [ -n "$shard_abi" ]; then
  rebuilt_abi="$(tr -d '[:space:]' < "$abi_file")"
  if [ "$rebuilt_abi" = "$shard_abi" ]; then
    row "abi (rebuilt .abi ↔ shard)" "$shard_abi" "$rebuilt_abi" info ""
  else
    row "abi (rebuilt .abi ↔ shard)" "$shard_abi" "$rebuilt_abi" info "DIFFERS — the rbconfig arch record moved"
  fi
fi

if [ "$failures" -eq 0 ]; then finish 0 green; else finish 1 red; fi
