#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Separate prototype path. The Developer-ID path remains build-app.sh with
# Resources/MacAgent.entitlements and the existing release script.
APC_APP_NAME="Photos Connector Sandbox.app" \
APC_ENTITLEMENTS_FILE="Resources/MacAgent.Store.entitlements" \
APC_SIGNING_IDENTITY="-" \
bash ./build-app.sh
