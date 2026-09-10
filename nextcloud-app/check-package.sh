#!/bin/sh
set -eu
root=${1:-$(dirname "$0")}
if [ ! -d "$root" ]; then
  printf '%s\n' "Package staging directory not found: $root" >&2
  exit 1
fi
bad=$(find "$root" \( -name '._*' -o -name '.DS_Store' \) -print)
if [ -n "$bad" ]; then
  printf '%s\n' "Refusing package: macOS metadata files found:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
printf '%s\n' 'Package metadata check passed.'
