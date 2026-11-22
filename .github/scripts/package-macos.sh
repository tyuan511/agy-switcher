#!/usr/bin/env bash
set -euo pipefail

app="$1"
output="$2"
for name in APPLE_CERT_P12 APPLE_CERT_PASSWORD APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing release secret $name" >&2
    exit 1
  fi
done

umask 077
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/agy-release.XXXXXX")"
keychain="$work_dir/release.keychain-db"
keychains=("$keychain")
while IFS='"' read -r _ existing _; do
  if [[ -n "$existing" ]]; then
    keychains+=("$existing")
  fi
done <<< "$(security list-keychains -d user)"

cleanup() {
  security list-keychains -d user -s "${keychains[@]:1}" || true
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

password="$(openssl rand -hex 32)"
printf '%s' "$APPLE_CERT_P12" | base64 --decode > "$work_dir/cert.p12"
printf '%s\n' "$APPLE_API_KEY_P8" > "$work_dir/AuthKey.p8"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work_dir/cert.p12" -k "$keychain" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "${keychains[@]}"
rm -f "$work_dir/cert.p12"
unset APPLE_CERT_P12 APPLE_CERT_PASSWORD APPLE_API_KEY_P8

identity="$(security find-identity -v -p codesigning "$keychain" |
  awk '/"Developer ID Application: / { print $2 }')"
if [[ ! "$identity" =~ ^[0-9A-F]{40}$ ]]; then
  echo "::error::The PKCS#12 must contain one valid Developer ID Application identity." >&2
  exit 1
fi

stage="$work_dir/stage"
mkdir "$stage"
signed_app="$stage/AGY Switcher.app"
ditto "$app" "$signed_app"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp --options runtime "$signed_app"
codesign --verify --deep --strict --verbose=2 "$signed_app"
ln -s /Applications "$stage/Applications"

dmg="$work_dir/${output##*/}"
hdiutil create -volname "AGY Switcher" -srcfolder "$stage" -format UDZO -fs HFS+ "$dmg"
codesign --sign "$identity" --keychain "$keychain" --timestamp "$dmg"

notary_auth=(--key "$work_dir/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
result="$work_dir/notary.json"
if ! xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --timeout 30m --output-format json > "$result" ||
  [[ "$(jq -r '.status' "$result")" != Accepted ]]; then
  cat "$result" >&2
  submission="$(jq -r '.id // empty' "$result")"
  if [[ -n "$submission" ]]; then
    xcrun notarytool log "$submission" "${notary_auth[@]}" >&2 || true
  fi
  echo "::error::Apple notarization did not succeed." >&2
  exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
mkdir -p "$(dirname "$output")"
mv "$dmg" "$output"
