# Shared InventoryCore

This package contains platform-neutral APC inventory data, selection state,
content identity, transport contracts, and small client helpers. It targets
macOS 14 and iOS 17. PhotoKit, AppKit, and application UI composition belong in
the platform app targets.

## Source identity before iOS uploads

Before the iOS upload MVP, decide how macOS and iOS identify the same logical
Apple Photos library to the APC server. The server scopes import history by
user and `sourceId`; a new device-local `sourceId` can therefore make an asset
already imported by the Mac appear new on iPhone. Stable cloud identifiers can
match assets across devices only within the intended source scope; local
PhotoKit identifiers are device-local and must not be used to infer a shared
source identity. This package does not choose or implement a source-sharing
policy.
