# Shared InventoryCore

This package contains platform-neutral APC inventory data, selection state,
content identity, transport contracts, and small client helpers. It targets
macOS 14 and iOS 17. PhotoKit, AppKit, and application UI composition belong in
the platform app targets.

## Source identity for the iOS inventory client

Before the iOS upload MVP, decide how macOS and iOS identify the same logical
Apple Photos library to the APC server. The server scopes import history by
Nextcloud user and `sourceId`. The current iOS inventory client therefore lets
the user enter the Mac's existing UUID; it does not derive a shared ID or alter
the macOS store. Apple's `PHCloudIdentifier` is intended to identify synced
iCloud Photos objects across devices, so matching those opaque identifiers
within the same user/source namespace can reuse existing import history.
Assets without a cloud identifier use `local:<localIdentifier>` and cannot be
reliably recognized across devices. Apple documents local identifiers as valid
only on their originating device. No server contract or database change is
needed for the cloud-identifier path; a future release should decide whether
the source UUID should be shared automatically and how to handle multiple
libraries/accounts safely.

Use a different source UUID for a distinct Photos library. Reusing one UUID
across unrelated libraries places them in the same server namespace.

## Current components

`InventoryCore` targets macOS 14 and iOS 17. It contains platform-neutral
inventory, album, selection, media, progress, content-identity, DAV contract,
connection, and upload helpers. PhotoKit, AppKit, SwiftUI app composition,
settings windows, credentials UI, and concrete exporters remain in platform
targets. The macOS agent retains its existing upload coordinator and release
flow; the iOS target adds a foreground-only importer using the same contracts.

## Content identity and reconcile

Source identity remains authoritative for `new`/`known` matching:
`sourceId`, `localIdentifier`, and `cloudIdentifier` are never replaced or
merged. A separate content identity is `user_id + sha256 + byte_size`. It is
evidence for cross-device reconcile, not a global deduplication key. Equal
bytes must not merge, delete, or connect two logical Apple Photos assets, and
users must never match one another.

The upload path is inventory and source matching; export and hash for `new`;
`uploads/prepare`; PUT only when the target is missing; then `uploads/complete`.
A confirmed existing target or `contentAlreadyPresent` is a completed import for
album synchronization and requires no PUT or Complete. Only confirmed APC
upload targets populate the server content index. Reserved, failed, incomplete,
orphaned, and deleted targets do not. Existing files are not re-hashed during
backfill. The current server does not use content hits to change inventory
status or globally skip uploads.

## Albums

Album inventory is source-scoped and uses the same cloud/local asset identity.
Empty albums are preserved and multiple memberships are independent. The
selected albums determine the affected set; every inventoried membership whose
asset is imported is restored. Missing members are skipped, there is no
transitive album selection, and repeated sync is idempotent.

## Security, performance, and backlog

The iOS credential store uses a device-only, unlock-required Keychain item.
Content identity is user-scoped and `sourceId` is not a secret. PhotoKit access
uses public APIs only. Album cloud identifiers are resolved in a batch, though
some MainActor-bound fetches can still be synchronous; large-library
performance should be profiled on device. Open follow-up work is background
URLSession upload/resume and interruption recovery, optional JPEG/PNG
conversion, and any future policy for hashing historical files outside
confirmed APC uploads. Optional server-side deduplication requires a separate
design.
