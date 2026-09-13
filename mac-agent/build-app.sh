#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if [[ "${CONFIGURATION:-release}" == "release" ]]; then
  arm_dir="$PWD/.build/arm64/out/Products/Release"
  x86_dir="$PWD/.build/x86_64/out/Products/Release"
  arm_bin="$arm_dir/MacAgent"; x86_bin="$x86_dir/MacAgent"
  swift build --product MacAgent --configuration release --arch arm64 --scratch-path .build/arm64 --disable-sandbox || test -x "$arm_bin"
  swift build --product MacAgent --configuration release --arch x86_64 --scratch-path .build/x86_64 --disable-sandbox || test -x "$x86_bin"
  rm -rf "$arm_dir/MacAgent.dSYM" "$x86_dir/MacAgent.dSYM"
  xcrun dsymutil "$arm_bin" -o "$arm_dir/MacAgent.dSYM"
  xcrun dsymutil "$x86_bin" -o "$x86_dir/MacAgent.dSYM"
else
  swift build --configuration debug --disable-sandbox
  arm_bin="$(swift build --configuration debug --show-bin-path --disable-sandbox)/MacAgent"
  x86_bin=""
fi
app="$PWD/.build/Nextcloud APC.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
if [[ -n "$x86_bin" ]]; then
  lipo -create "$arm_bin" "$x86_bin" -output "$app/Contents/MacOS/MacAgent"
else
  cp "$arm_bin" "$app/Contents/MacOS/MacAgent"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for localization in en de fr pt nl es; do
  mkdir -p "$app/Contents/Resources/${localization}.lproj"
  cp "Resources/${localization}.lproj/Localizable.strings" "$app/Contents/Resources/${localization}.lproj/Localizable.strings"
done
codesign --force --sign - --entitlements Resources/MacAgent.entitlements "$app"
printf 'App erstellt: %s\n' "$app"
