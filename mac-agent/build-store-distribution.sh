#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Photos Connector.app"
APP="$(pwd)/.build/$APP_NAME"
STORE_ROOT="$(pwd)/.build/store-distribution"
ARM_ROOT="$STORE_ROOT/arm64"
X86_ROOT="$STORE_ROOT/x86_64"
ARM_BIN="$ARM_ROOT/MacAgent"
X86_BIN="$X86_ROOT/MacAgent"
ARM_DSYM="$ARM_ROOT/MacAgent.dSYM"
X86_DSYM="$X86_ROOT/MacAgent.dSYM"
UNIVERSAL_DSYM="$STORE_ROOT/MacAgent.dSYM"
PKG="$(pwd)/.build/Photos-Connector-Mac-App-Store.pkg"
PROFILE="${APC_STORE_PROVISIONING_PROFILE:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/d5bef3cd-c2b5-4229-92ad-91d2cbd51386.provisionprofile}"
APP_SIGNING_IDENTITY="${APC_STORE_APP_SIGNING_IDENTITY:-Apple Distribution: Frank Kettenbeil (Q3PGXQ5B45)}"
INSTALLER_SIGNING_IDENTITY="${APC_STORE_INSTALLER_SIGNING_IDENTITY:-3rd Party Mac Developer Installer: Frank Kettenbeil (Q3PGXQ5B45)}"
EXPECTED_BUNDLE_ID="de.kettenbeil.photosconnector"
TEAM_ID="Q3PGXQ5B45"
EXPECTED_APP_IDENTIFIER="$TEAM_ID.$EXPECTED_BUNDLE_ID"
ENTITLEMENTS="Resources/MacAgent.Store.entitlements"

fail() { printf 'Store-Build abgebrochen: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Werkzeug fehlt: $1"; }
for tool in swift codesign lipo dwarfdump security openssl productbuild pkgutil plutil; do need "$tool"; done
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy fehlt"
[[ -f "$PROFILE" ]] || fail "Provisioning Profile fehlt: $PROFILE"
[[ -f "$ENTITLEMENTS" ]] || fail "Store-Entitlements fehlen: $ENTITLEMENTS"

cleanup_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  for attempt in 1 2 3; do
    dot_clean -m "$path" >/dev/null 2>&1 || true
    rm -rf -- "$path" || true
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
  done
  fail "Store-Build-Arbeitsbereich konnte nicht entfernt werden: $path"
}

cleanup_path "$STORE_ROOT"
cleanup_path "$APP"
cleanup_path "$PKG"
mkdir -p "$ARM_ROOT" "$X86_ROOT"

export CLANG_MODULE_CACHE_PATH="$(pwd)/.build/store-clang-module-cache"

printf '==> Baue arm64 Release-Binary\n'
swift build --product MacAgent --configuration release --arch arm64 \
  --scratch-path "$ARM_ROOT/scratch" --disable-sandbox
cp "$ARM_ROOT/scratch/out/Products/Release/MacAgent" "$ARM_BIN"

printf '==> Baue x86_64 Release-Binary\n'
swift build --product MacAgent --configuration release --arch x86_64 \
  --scratch-path "$X86_ROOT/scratch" --disable-sandbox
cp "$X86_ROOT/scratch/out/Products/Release/MacAgent" "$X86_BIN"

printf '==> Erzeuge arm64 dSYM\n'
xcrun dsymutil "$ARM_BIN" -o "$ARM_DSYM"
printf '==> Erzeuge x86_64 dSYM\n'
xcrun dsymutil "$X86_BIN" -o "$X86_DSYM"

ARM_UUID="$(dwarfdump --uuid "$ARM_BIN" | awk '{print $2}')"
X86_UUID="$(dwarfdump --uuid "$X86_BIN" | awk '{print $2}')"
ARM_DSYM_UUID="$(dwarfdump --uuid "$ARM_DSYM" | awk '{print $2}')"
X86_DSYM_UUID="$(dwarfdump --uuid "$X86_DSYM" | awk '{print $2}')"
[[ "$ARM_DSYM_UUID" == "$ARM_UUID" ]] || fail "arm64 dSYM UUID passt nicht zum Binary"
[[ "$X86_DSYM_UUID" == "$X86_UUID" ]] || fail "x86_64 dSYM UUID passt nicht zum Binary"

printf '==> Erzeuge Universal Binary und Universal dSYM\n'
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/MacAgent"
xcrun dsymutil "$APP/Contents/MacOS/MacAgent" -o "$UNIVERSAL_DSYM"
UNIVERSAL_UUID="$(dwarfdump --uuid "$APP/Contents/MacOS/MacAgent")"
UNIVERSAL_DSYM_UUID="$(dwarfdump --uuid "$UNIVERSAL_DSYM")"
for uuid in $(dwarfdump --uuid "$APP/Contents/MacOS/MacAgent" | awk '{print $2}'); do
  [[ "$UNIVERSAL_DSYM_UUID" == *"$uuid"* ]] || fail "Universal dSYM UUID fehlt: $uuid"
done

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for localization in en de fr pt nl es; do
  mkdir -p "$APP/Contents/Resources/${localization}.lproj"
  cp "Resources/${localization}.lproj/Localizable.strings" "$APP/Contents/Resources/${localization}.lproj/Localizable.strings"
done
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "Unerwartete Bundle-ID: $BUNDLE_ID"

PROFILE_XML="$STORE_ROOT/profile.plist"
if ! security cms -D -i "$APP/Contents/embedded.provisionprofile" -o "$PROFILE_XML" 2>/dev/null; then
  openssl smime -inform der -verify -noverify \
    -in "$APP/Contents/embedded.provisionprofile" -out "$PROFILE_XML" >/dev/null
fi
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_XML")"
[[ "$PROFILE_APP_ID" == "$EXPECTED_APP_IDENTIFIER" ]] || fail "Profil-App-ID stimmt nicht: $PROFILE_APP_ID"
PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_XML")"
[[ "$PROFILE_TEAM_ID" == "$TEAM_ID" ]] || fail "Profil-Team-ID stimmt nicht: $PROFILE_TEAM_ID"

STORE_SIGNING_ENTITLEMENTS="$STORE_ROOT/signing-entitlements.plist"
cp "$ENTITLEMENTS" "$STORE_SIGNING_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$STORE_SIGNING_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM_ID" "$STORE_SIGNING_ENTITLEMENTS"

# The profile authorizes the application/team identity. The functional sandbox
# entitlements are supplied by the Store entitlements file. The profile also
# advertises a wildcard keychain capability, but this app uses generic-password
# access without a shared access group, so it is intentionally not claimed.

printf '==> Signiere Store-App\n'
codesign --force --timestamp --sign "$APP_SIGNING_IDENTITY" \
  --entitlements "$STORE_SIGNING_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=4 "$APP"

SIGNED_ENTITLEMENTS="$STORE_ROOT/signed-entitlements.plist"
codesign -d --entitlements :- --xml "$APP" > "$STORE_ROOT/signed-entitlements.raw" 2>&1
awk '/<plist/{inside=1} inside{print} /<\/plist>/{inside=0; found=1} END{if (!found) exit 1}' \
  "$STORE_ROOT/signed-entitlements.raw" > "$SIGNED_ENTITLEMENTS"
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
if /usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$SIGNED_ENTITLEMENTS")" != "true" ]] || fail "get-task-allow=true im Store-Bundle"
fi

printf '==> Erzeuge signiertes PKG\n'
productbuild --component "$APP" /Applications --sign "$INSTALLER_SIGNING_IDENTITY" "$PKG"
codesign --verify --deep --strict --verbose=4 "$APP"
pkgutil --check-signature "$PKG"

printf '\nStore-Build erfolgreich\n'
printf 'App: %s\n' "$APP"
printf 'dSYM: %s\n' "$UNIVERSAL_DSYM"
printf 'PKG: %s\n' "$PKG"
printf 'Bundle-ID: %s\n' "$BUNDLE_ID"
printf 'Architekturen: '; lipo -archs "$APP/Contents/MacOS/MacAgent"
printf 'Binary UUIDs:\n%s\n' "$UNIVERSAL_UUID"
printf 'dSYM UUIDs:\n%s\n' "$UNIVERSAL_DSYM_UUID"
printf 'Profile App-ID: %s\n' "$PROFILE_APP_ID"
printf 'Signierte Entitlements: %s\n' "$SIGNED_ENTITLEMENTS"
