#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -module-cache-path .build/clang-module-cache \
    Sources/InventoryCore/AssetInventory.swift Sources/InventoryCore/PhotoSource.swift Sources/MacAgent/CloudIdentifierCodec.swift SmokeTests/JSONSmoke.swift \
    -o .build/json-smoke
.build/json-smoke

# Two independent process starts use the same isolated Connector configuration.
source_test_dir="$(mktemp -d "$PWD/.build/source-smoke.XXXXXX")"
.build/json-smoke --source "$source_test_dir/source.json" > "$source_test_dir/first.json"
cp "$source_test_dir/source.json" "$source_test_dir/persisted-first.json"
.build/json-smoke --source "$source_test_dir/source.json" > "$source_test_dir/second.json"
cmp "$source_test_dir/persisted-first.json" "$source_test_dir/source.json"
cmp "$source_test_dir/first.json" "$source_test_dir/second.json"
# A separate configuration must receive a different logical UUID.
.build/json-smoke --source "$source_test_dir/other.json" > "$source_test_dir/other-scan.json"
if cmp -s "$source_test_dir/first.json" "$source_test_dir/other-scan.json"; then
    echo "FAIL: independent configurations share a source" >&2
    exit 1
fi
# Never silently replace a corrupt existing configuration.
printf 'invalid json' > "$source_test_dir/corrupt.json"
if .build/json-smoke --source "$source_test_dir/corrupt.json" > /dev/null 2>&1; then
    echo "FAIL: corrupt configuration accepted" >&2
    exit 1
fi
test "$(cat "$source_test_dir/corrupt.json")" = 'invalid json'
echo "PASS: stable source across two process starts, independent configuration, corruption preserved"

xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" -module-cache-path .build/clang-module-cache \
    Sources/InventoryCore/ContentIdentity.swift Sources/InventoryCore/WebDAVUploader.swift SmokeTests/UploadSmoke.swift -o .build/upload-smoke
.build/upload-smoke
recovery_test_dir="$(mktemp -d "$PWD/.build/recovery-smoke.XXXXXX")"
.build/upload-smoke lost "$recovery_test_dir"
.build/upload-smoke recover "$recovery_test_dir"
