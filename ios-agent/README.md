# Photos Connector for iOS

This Xcode project configures an APC connection, selects accessible PhotoKit
assets, and posts their metadata to the existing APC `/inventory` endpoint. It
does not export originals, perform WebDAV PUTs, synchronize albums, or run
background uploads. New assets may receive server-side upload tickets as part
of the existing inventory response; this client ignores those tickets and has
no UI or code path that transfers files. It uses the shared local Swift
package at `../shared/InventoryCore`.

The iOS 17 target provides a foreground PhotoKit import path: inventory,
original export, SHA-256/byte-size calculation, upload prepare, WebDAV PUT
when required, upload completion, content reconciliation, and album
inventory/synchronization. It also contains the gallery and album UI with a
3/4/5/6-column grid, shared selection markers, long-press drag selection, and
edge auto-scroll. Background URLSession uploads and interruption recovery are
not implemented; imports run in the foreground.

## Source ID and Mac import history

The APC server isolates history by Nextcloud user and `sourceId`. In
**Verbindung → Quellen-ID**, enter the UUID from the Mac file
`~/Library/Application Support/Apple Photos Connector/source.json` to check
against that source's import history. The iOS app does not automatically read
or synchronize the Mac's UUID. With that same UUID, PhotoKit cloud identifiers
can match iCloud-synced assets across devices. Assets without a cloud identifier
fall back to device-local PhotoKit identifiers and may be reported as new on
the iPhone. See `../shared/InventoryCore/ARCHITECTURE.md` for the decision and
limits.

## Manual no-upload integration check

Configure the same Nextcloud user and Mac `sourceId` on iOS, test the connection,
then use **Auswahl prüfen**:

1. Select a photo already imported by the Mac. Expected: **Bereits in
   Nextcloud** (`known`).
2. Select a photo never imported. Expected: **Neu** (`new`).
3. Select both. Expected: **1 already known / 1 new**.

This sends inventory JSON only. The app does not follow any returned upload
ticket, and no file bytes are sent.

## Open and run

1. Open `ApplePhotosConnector.xcodeproj` in Xcode.
2. Select the `ApplePhotosConnector` scheme and an iOS 17 or later simulator.
3. Build and run. The app explains its Photos access before the user taps
   **Zugriff auf Fotos erlauben**; it does not request access on launch.

## Run on an iPhone

1. Connect and unlock the iPhone, accept **Trust This Computer** if prompted,
   and make sure the device runs iOS 17 or later.
2. Open `ApplePhotosConnector.xcodeproj` and select the `ApplePhotosConnector`
   scheme.
3. In the project editor, select the `ApplePhotosConnector` target, then
   **Signing & Capabilities**. Turn on **Automatically manage signing** and
   choose your Apple **Development Team**. No distribution certificate or
   App Store setup is required.
4. Keep the bundle identifier `de.applephotosconnector.iosagent`. If Xcode
   reports that it is already registered to another team, use a unique
   development bundle identifier for your team before running; the intended
   project identifier remains the default shown above.
5. Select the connected iPhone as the run destination and press **Run**.
   On first launch, tap **Zugriff auf Fotos erlauben** and choose Full Access
   or Limited Access in the iOS prompt. Limited Access displays only the
   selected items and is labelled as restricted in the app.

The app uses `NSPhotoLibraryUsageDescription` from `Resources/Info.plist`.
PhotoKit does not require an additional iOS Photos entitlement or capability
for this read-only proof of concept.

## Album import semantics

The configured source identity is used for inventory, upload reconciliation,
and album membership. A `known` asset or a `contentAlreadyPresent` prepare
result can proceed to album synchronization without another file transfer.
Album sync restores imported memberships, skips non-imported members, retains
empty albums, supports one asset in multiple albums, and performs no transitive
selection. Album names are never identifiers.

## Security and PhotoKit limits

The Nextcloud password is stored in the iOS Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; credentials are not stored in
`UserDefaults`. `sourceId` is an import namespace, not a secret. Server content
identity is scoped by `user_id + sha256 + byte_size`, so users are never
matched against one another. The adapter prefers `cloud:<cloudIdentifier>` and
falls back to `local:<localIdentifier>`.

Album cloud-identifier resolution is batched to avoid a per-member fetch. Some
public PhotoKit fetches remain synchronous on the MainActor because the current
UI model is MainActor-bound; no private PhotoKit APIs are used. Large-library
performance, background uploads, and resume after interruption remain backlog
items.

## Verification

The current tree is covered by 15 iOS tests, 24 shared-core tests, 125 macOS
tests, and the standalone PHP/SQLite server suite. Debug and Release builds
include the APC icon copied from the macOS artwork and the Photos usage
description.
