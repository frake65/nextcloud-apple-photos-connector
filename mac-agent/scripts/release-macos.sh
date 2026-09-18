#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$AGENT_DIR/.." && pwd)"
APP="$AGENT_DIR/.build/Nextcloud APC.app"
APP_EXECUTABLE="$APP/Contents/MacOS/MacAgent"
ENTITLEMENT_KEY="com.apple.security.personal-information.photos-library"

fail() {
  printf 'Release abgebrochen: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Benötigtes Programm nicht gefunden: $1"
}

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  fail "Aufruf: $0 <Agent-Version, z. B. 0.8.3>"
fi
EXPECTED_VERSION="$1"

[[ "$(uname -s)" == "Darwin" ]] || fail "Dieses Release-Script benötigt macOS."
for tool in xcodebuild xcrun swift codesign ditto shasum security lipo spctl plutil awk; do
  need_command "$tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy fehlt (/usr/libexec/PlistBuddy)."

[[ -n "${APC_SIGNING_IDENTITY:-}" ]] || fail "APC_SIGNING_IDENTITY muss gesetzt sein; ad-hoc-Releases sind nicht zulässig."
[[ -n "${APC_NOTARY_PROFILE:-}" ]] || fail "APC_NOTARY_PROFILE muss auf ein notarytool-Keychain-Profil gesetzt sein."

identity_list="$(security find-identity -v -p codesigning 2>&1)" || fail "Developer-ID-Identitäten konnten nicht gelesen werden."
printf '%s\n' "$identity_list"
grep -Fq "\"$APC_SIGNING_IDENTITY\"" <<< "$identity_list" || \
  fail "Signing Identity nicht in security find-identity gefunden: $APC_SIGNING_IDENTITY"

if ! git -C "$REPO_ROOT" diff --quiet HEAD -- mac-agent; then
  fail "Tracked mac-agent-Dateien sind geändert. Bitte Änderungen vor einem Release committen oder verwerfen. Untracked Dateien werden ignoriert."
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/apc-release.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

OUTPUT_ZIP="$AGENT_DIR/.build/Nextcloud-APC-${EXPECTED_VERSION}-macos-universal.zip"
mkdir -p "$AGENT_DIR/.build"

printf '\n==> Baue und signiere Agent %s\n' "$EXPECTED_VERSION"
# Remove only release outputs so build-app.sh cannot fall back to a stale binary
# after a failed Swift build.
rm -rf "$APP" \
  "$AGENT_DIR/.build/arm64/out/Products/Release/MacAgent" \
  "$AGENT_DIR/.build/x86_64/out/Products/Release/MacAgent"
APC_SIGNING_IDENTITY="$APC_SIGNING_IDENTITY" bash "$AGENT_DIR/build-app.sh"
[[ -d "$APP" && -x "$APP_EXECUTABLE" ]] || fail "Der Build hat kein verwendbares App-Bundle erzeugt."

verify_app() {
  local app_path="$1"
  local expected_version="$2"
  local executable="$app_path/Contents/MacOS/MacAgent"
  local entitlements_plist="$TEMP_ROOT/entitlements-$(basename "$app_path").plist"
  local entitlements_stream="$TEMP_ROOT/entitlements-$(basename "$app_path").stream"
  local arches version build_version bundle_id entitlement_value

  [[ -x "$executable" ]] || fail "Bundle-Executable fehlt: $executable"
  codesign --verify --deep --strict --verbose=2 "$app_path" || fail "codesign verification fehlgeschlagen: $app_path"
  printf '\nSignaturinformationen für %s:\n' "$app_path"
  codesign -dv --verbose=4 "$app_path" 2>&1 || fail "Signaturinformationen konnten nicht gelesen werden."

  # codesign may write display output to stderr; extract the embedded plist
  # from its actual signed entitlements output and reject absent/malformed data.
  codesign -d --entitlements :- "$app_path" >"$entitlements_stream" 2>&1 || \
    fail "Signierte Entitlements konnten nicht ausgelesen werden: $app_path"
  awk '/<plist/{inside=1} inside{print} /<\/plist>/{inside=0; found=1} END{if (!found) exit 1}' \
    "$entitlements_stream" > "$entitlements_plist" || \
    fail "codesign lieferte keine lesbare Entitlements-Plist: $app_path"
  plutil -lint "$entitlements_plist" >/dev/null || fail "Entitlements-Plist ist ungültig: $app_path"
  entitlement_value="$(/usr/libexec/PlistBuddy -c "Print :$ENTITLEMENT_KEY" "$entitlements_plist" 2>/dev/null)" || \
    fail "Photos-Entitlement fehlt in der signierten App: $app_path"
  [[ "$entitlement_value" == "true" ]] || fail "Photos-Entitlement ist nicht true in der signierten App: $app_path"

  arches="$(lipo -archs "$executable")" || fail "Architekturen konnten nicht ermittelt werden: $app_path"
  [[ " $arches " == *" arm64 "* && " $arches " == *" x86_64 "* ]] || \
    fail "Universal Binary muss arm64 und x86_64 enthalten; gefunden: $arches"

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")" || \
    fail "CFBundleShortVersionString fehlt: $app_path"
  [[ "$version" == "$expected_version" ]] || \
    fail "Bundle-Version $version entspricht nicht der angeforderten Version $expected_version."
  build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")" || \
    fail "CFBundleVersion fehlt: $app_path"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" || \
    fail "CFBundleIdentifier fehlt: $app_path"
  [[ "$bundle_id" == "de.applephotosconnector.macagent" ]] || \
    fail "Unerwartete Bundle-ID: $bundle_id"
  printf 'Verifiziert: version=%s build=%s bundle=%s archs=%s %s=true\n' \
    "$version" "$build_version" \
    "$bundle_id" "$arches" "$ENTITLEMENT_KEY"
}

verify_app "$APP" "$EXPECTED_VERSION"

printf '\n==> Erzeuge frisches Notarisierungs-ZIP\n'
NOTARY_ZIP="$TEMP_ROOT/Nextcloud-APC-${EXPECTED_VERSION}-notary.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
[[ -s "$NOTARY_ZIP" ]] || fail "Notarisierungs-ZIP wurde nicht erzeugt."

printf '\n==> Sende an Apple Notary Service (Profil: %s)\n' "$APC_NOTARY_PROFILE"
NOTARY_RESULT="$TEMP_ROOT/notary-result.json"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$APC_NOTARY_PROFILE" \
  --wait --output-format json > "$NOTARY_RESULT" || fail "notarytool submission fehlgeschlagen."
cat "$NOTARY_RESULT"
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null)" || \
  fail "Status der Notarisierung konnte nicht gelesen werden."
NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
printf 'Notary Submission ID: %s\nNotary Result: %s\n' "${NOTARY_ID:-unbekannt}" "$NOTARY_STATUS"
[[ "$NOTARY_STATUS" == "Accepted" ]] || fail "Notarisierung nicht akzeptiert (Status: $NOTARY_STATUS)."

printf '\n==> Staple und Gatekeeper-Prüfung\n'
xcrun stapler staple "$APP" || fail "Ticket konnte nicht gestapelt werden."
xcrun stapler validate "$APP" || fail "Stapler-Validierung fehlgeschlagen."
spctl --assess --type execute --verbose=2 "$APP" || fail "Gatekeeper hat das App-Bundle abgelehnt."

printf '\n==> Prüfe gestapelte App erneut\n'
verify_app "$APP" "$EXPECTED_VERSION"
xcrun stapler validate "$APP" || fail "Stapler-Validierung nach dem Stapling fehlgeschlagen."

printf '\n==> Erzeuge finales Release-ZIP\n'
FINAL_CANDIDATE="$TEMP_ROOT/Nextcloud-APC-${EXPECTED_VERSION}-macos-universal.zip"
ditto -c -k --keepParent "$APP" "$FINAL_CANDIDATE"
[[ -s "$FINAL_CANDIDATE" ]] || fail "Finales ZIP wurde nicht erzeugt."

EXTRACT_ROOT="$TEMP_ROOT/extracted-final-zip"
mkdir -p "$EXTRACT_ROOT"
ditto -x -k "$FINAL_CANDIDATE" "$EXTRACT_ROOT"
EXTRACTED_APP="$EXTRACT_ROOT/Nextcloud APC.app"
[[ -d "$EXTRACTED_APP" ]] || fail "Das finale ZIP enthält nicht das erwartete App-Bundle."
verify_app "$EXTRACTED_APP" "$EXPECTED_VERSION"
xcrun stapler validate "$EXTRACTED_APP" || fail "Stapler-Validierung der entpackten ZIP-App fehlgeschlagen."
spctl --assess --type execute --verbose=2 "$EXTRACTED_APP" || \
  fail "Gatekeeper hat die aus dem finalen ZIP entpackte App abgelehnt."

ZIP_SHA256="$(shasum -a 256 "$FINAL_CANDIDATE" | awk '{print $1}')" || fail "SHA-256 konnte nicht berechnet werden."
ZIP_SIZE="$(stat -f '%z' "$FINAL_CANDIDATE")" || fail "ZIP-Größe konnte nicht ermittelt werden."
mv -f "$FINAL_CANDIDATE" "$OUTPUT_ZIP" || fail "Finales ZIP konnte nicht installiert werden: $OUTPUT_ZIP"

printf '\nRelease erfolgreich\n'
printf 'Agent-Version:       %s\n' "$EXPECTED_VERSION"
printf 'Build-Version:       %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
printf 'Bundle-ID:           de.applephotosconnector.macagent\n'
printf 'Architekturen:       arm64 x86_64\n'
printf 'Signing Identity:    %s\n' "$APC_SIGNING_IDENTITY"
printf 'Photos Entitlement:  OK (true)\n'
printf 'Notarization:        Accepted (%s)\n' "${NOTARY_ID:-unbekannt}"
printf 'Stapling:            OK\nGatekeeper:          OK\n'
printf 'ZIP:                 %s\n' "$OUTPUT_ZIP"
printf 'Größe:               %s Bytes\nSHA-256:             %s\n' "$ZIP_SIZE" "$ZIP_SHA256"
printf 'GitHub-Veröffentlichung: nicht durchgeführt\n'
