#!/bin/sh
set -eu
# Accept the staging parent, so unexpected sibling entries cannot be missed.
php "$(dirname "$0")/tools/check-package.php" "${1:?Usage: check-package.sh STAGING_PARENT [INFO_XSD]}" "${2:-}"
