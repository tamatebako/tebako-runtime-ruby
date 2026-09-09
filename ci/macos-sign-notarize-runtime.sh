#!/usr/bin/env bash
# ci/macos-sign-notarize-runtime.sh — spec 31 §5/§8.4: sign the freshly
# built macOS runtime exe (Developer ID Application, hardened runtime,
# the ci/runtime.entitlements pair) and notarize it, in-leg, BEFORE the
# S51 provenance check and the boot smoke — every downstream gate, and
# the publish stage's .sha256 sidecar, then anchors the exact SIGNED
# bytes (sign-then-hash is mandatory).
#
# The spec 31 §5 gate: the repo variable APPLE_SIGNING_ENABLED=true
# arms; anything else ships unsigned BY DESIGN (spec 00 invariant 7 —
# a loud notice, exit 0). Armed + an unresolved APPLE_* secret is a
# FAST named failure, never a partial release.
#
# The exe is left quarantine-marked on success: the leg's own boot
# smoke (and its JIT canaries) then runs under Gatekeeper's exact
# download path. Bare Mach-O keeps an online ticket — stapling is
# unsupported and spctl rejects bare CLI tools BY DESIGN (sign-probe,
# tamatebako/tebako run 34319254822), so the documented verification is
# codesign's notarization check.
#
# Required env when armed: APPLE_DEVELOPER_ID_P12 (base64),
# APPLE_DEVELOPER_ID_P12_PASSWORD, APPLE_TEAM_ID, APPLE_ASC_KEY_P8,
# APPLE_ASC_KEY_ID, APPLE_ASC_ISSUER_ID. Runner env: RUNNER_TEMP.
# Runs from the workspace root (ci/runtime.entitlements resolves).
#
# Usage: ci/macos-sign-notarize-runtime.sh <runtime-exe>
set -euo pipefail

exe="$1"
[ -f "$exe" ] || { echo "::error::no such runtime exe: $exe"; exit 64; }

if [ "${APPLE_SIGNING_ENABLED:-false}" != "true" ]; then
  echo "::notice::spec 31: APPLE_SIGNING_ENABLED != true — this leg ships UNSIGNED (spec 00 invariant 7)"
  exit 0
fi
missing=""
for v in APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_TEAM_ID \
         APPLE_ASC_KEY_P8 APPLE_ASC_KEY_ID APPLE_ASC_ISSUER_ID; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "::error::APPLE_SIGNING_ENABLED=true but unset:$missing — spec 31 §5: fast failure, never a partial release"
  exit 1
fi

step() { echo; echo "=== $*"; }

step "keychain + identity (Developer ID Application)"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/tebako-sign.XXXXXX")"
printf '%s' "$APPLE_DEVELOPER_ID_P12" | base64 -d > "$work/devid.p12"
KC="$work/sign.keychain"
security create-keychain -p sign-kc-pass "$KC"
security unlock-keychain -p sign-kc-pass "$KC"
# codesign resolves identities through the user search list — a freshly
# created keychain is not on it (the sign-probe's attempt-2 lesson).
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security import "$work/devid.p12" -k "$KC" -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -k sign-kc-pass "$KC" >/dev/null
# Sign by cert SHA-1, never by name — a duplicate identity in any
# search-listed keychain makes name resolution ambiguous.
HASH=$(security find-identity -v -p codesigning "$KC" | awk '/Developer ID Application/ {print $2; exit}')
[ -n "$HASH" ] || { echo "::error::no Developer ID Application identity in the p12"; exit 1; }
echo "signing identity cert: ${HASH:0:10}…"

step "codesign (hardened runtime + the spec 31 §3 pair)"
codesign --force --options runtime --timestamp --keychain "$KC" \
  --entitlements ci/runtime.entitlements --sign "$HASH" "$exe"
codesign --verify --strict --verbose=1 "$exe"
codesign -dvv "$exe" 2>&1 | grep -q "TeamIdentifier=$APPLE_TEAM_ID" \
  || { echo "::error::TeamIdentifier is not $APPLE_TEAM_ID — signed by an unexpected identity"; exit 1; }
# macOS 15 emits the embedded plist single-line — count <true/> values,
# never key lines.
codesign -d --entitlements :- "$exe" > "$work/embedded.xml" 2>/dev/null || true
TRUES=$(grep -o '<true/>' "$work/embedded.xml" | wc -l | tr -d ' ')
[ "$TRUES" = "2" ] || { cat "$work/embedded.xml"; echo "::error::entitlement pair not embedded (got $TRUES <true/>)"; exit 1; }
echo "entitlements embedded: disable-library-validation + allow-jit"

step "notarize (App Store Connect API key)"
printf '%s' "$APPLE_ASC_KEY_P8" > "$work/AuthKey.p8"
( cd "$(dirname "$exe")" && zip -q -j "$work/runtime.zip" "$(basename "$exe")" )
xcrun notarytool submit "$work/runtime.zip" --key "$work/AuthKey.p8" \
  --key-id "$APPLE_ASC_KEY_ID" --issuer "$APPLE_ASC_ISSUER_ID" \
  --wait --timeout 20m | tee "$work/notary.txt"
grep -q 'status: Accepted' "$work/notary.txt" || {
  xcrun notarytool log "$(grep -m1 -oE '[0-9a-f-]{36}' "$work/notary.txt")" \
    --key "$work/AuthKey.p8" --key-id "$APPLE_ASC_KEY_ID" --issuer "$APPLE_ASC_ISSUER_ID" 2>&1 | tail -20
  echo "::error::notarytool did not Accept the submission"; exit 1; }

step "verify the online ticket + quarantine-mark (the boot smoke is the exec canary)"
codesign --verify --strict --check-notarization -R=notarized "$exe"
xattr -w com.apple.quarantine '0081;00000000;Safari;' "$exe"
echo "signed + notarized + quarantine-marked: $(basename "$exe")"
