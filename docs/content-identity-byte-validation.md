# Content identity byte validation

This manual DEBUG-only diagnostic compares the PhotoKit original resource selected by the Mac agent and iOS app. It exports to a unique temporary directory, computes SHA-256 and byte count with `InventoryCore.ContentIdentity`, and removes the temporary directory. It does not contact Nextcloud or perform an inventory request or upload. The action is compiled only in DEBUG builds.

## Test 1: normal photo

1. Use a Mac and iPhone signed in to the same iCloud Photos library. Build/run the DEBUG app on each device.
2. On each device, select exactly the same ordinary photo (no RAW or Live Photo handling in this phase).
3. On Mac, enable the existing Debug mode, then choose **Original-Hash berechnen**. On iPhone, open the selection review screen and choose its separate **DEBUG: Original-Hash berechnen** action. Do not choose **Auswahl prüfen**; that is an independent server inventory action.
4. Wait for the original export/iCloud download and hash to finish. Compare the reported resource type, filename, bytes, and SHA-256. Record local and cloud identifiers separately.

Expected: resource type, byte count, and SHA-256 match. Local identifiers may differ. Note whether cloud identifiers are present and whether they match.

## Test 2: normal video (optional)

Repeat with the same ordinary video on both devices. The expected comparisons are the same.

## Later cases (not implemented or automated)

- Live Photo
- edited photo
- RAW/JPEG pair
- iCloud-only asset

## Values to report

- resource type: Mac / iPhone
- original filename: Mac / iPhone
- byte count: Mac / iPhone
- SHA-256: Mac / iPhone
- cloud identifier: present on each device, and equal or different

The local identifier can also be included if useful, but it is not a content comparison value.
