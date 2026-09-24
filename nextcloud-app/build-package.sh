#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir=${1:-"$source_dir/../.build/server"}
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/apc-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
app="$stage/apple_photos_connector"
mkdir -p "$app"
cp -R "$source_dir/appinfo" "$source_dir/lib" "$source_dir/img" "$app/"
# Unregistered development commands and legacy test aliases have no runtime consumers.
rm "$app/lib/Command/AlbumTestResolveCommand.php" "$app/lib/Command/AlbumTestAddMembershipCommand.php" \
   "$app/lib/Service/AlbumTestService.php" "$app/lib/Service/AlbumMembershipTestService.php"
cp "$source_dir/LICENSE" "$source_dir/CHANGELOG.md" "$source_dir/README.md" "$source_dir/composer.json" "$app/"
find "$app" -type f \( -name '.DS_Store' -o -name '._*' \) -delete
sh "$source_dir/check-package.sh" "$stage" "${INFO_XSD:-}"
archive="$output_dir/apple_photos_connector-0.8.7.tar.gz"
if tar --version | grep -q bsdtar; then
    COPYFILE_DISABLE=1 tar --no-xattrs --no-acls --no-fflags -czf "$archive" -C "$stage" apple_photos_connector
else
    COPYFILE_DISABLE=1 tar -czf "$archive" -C "$stage" apple_photos_connector
fi
if tar -tzf "$archive" | grep -E '(^|/)(\._[^/]*|\.DS_Store)$' >/dev/null; then
    echo 'Refusing package containing AppleDouble or .DS_Store entries' >&2
    exit 1
fi
printf 'Created: %s\n' "$archive"
