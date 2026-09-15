#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
master="$root/assets/logo/apple-photos-connector.svg"
test -f "$master"
mkdir -p "$root/nextcloud-app/img" "$root/mac-agent/Resources/AppIcon.appiconset" "$root/.build/icons"
cp "$master" "$root/nextcloud-app/img/app.svg"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/apc-icons.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swift -module-cache-path "$tmp/swift-module-cache" "$root/scripts/render-svg.swift" "$master" "$tmp" 16 32 64 128 256 512 1024
for size in 16 32 64 128 256 512 1024; do cp "$tmp/icon_${size}x${size}.png" "$root/.build/icons/icon_${size}x${size}.png"; done
cp "$tmp/icon_16x16.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_16x16.png"
cp "$tmp/icon_32x32.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_16x16@2x.png"
cp "$tmp/icon_32x32.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_32x32.png"
cp "$tmp/icon_64x64.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_32x32@2x.png"
cp "$tmp/icon_128x128.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_128x128.png"
cp "$tmp/icon_256x256.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_128x128@2x.png"
cp "$tmp/icon_256x256.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_256x256.png"
cp "$tmp/icon_512x512.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_256x256@2x.png"
cp "$tmp/icon_512x512.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_512x512.png"
cp "$tmp/icon_1024x1024.png" "$root/mac-agent/Resources/AppIcon.appiconset/icon_512x512@2x.png"
