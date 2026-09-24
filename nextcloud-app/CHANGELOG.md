# Changelog

Changes follow the Keep a Changelog categories. This package contains the server
app; companion macOS changes below are provided for context.

## [0.8.7] - 2026-09-24

### Changed
- Publish the Photos Connector product metadata in English and German.
- Document photo and video import, album transfer, additive delta imports and non-destructive overwrite protection.
- Publish the signed `apple_photos_connector-0.8.7-signed.tar.gz` release archive.

## [0.8.6] - 2026-09-18

### Fixed
- Recover deleted Nextcloud Photos albums selected through the memberships of
  already imported assets, including requests with no explicit album selection.
- Restore every already imported membership in each directly affected album;
  skip unimported assets, do not expand recovery into other albums, and do not
  upload known files again.
- Clear an earlier album-resolution error only when a later membership
  operation successfully resolves that same album. Count the actual Photos
  action in `albumsCreated` / `albumsReused` and preserve genuine membership
  failures in `summary.errors`.
- Keep repeated recovery runs idempotent.

### Changed
- Prepare 0.8.1 for the App Store: SPDX license, documentation and support links,
  full license text and validated app-ID archive layout.
- Declare Nextcloud 34–35 compatibility and accept Photos 8.0.0 alongside 7.0.0.
- Unregister the two development-only album OCC commands; retain administrator
  album sync and the development classes.

### Verified
- Manually verified album recovery and idempotence against Nextcloud 35 and
  Photos 8.0.0: selected imported assets restored affected albums and their
  imported memberships without duplicate uploads or false error results.

## [Unreleased]

## [0.8.5] - 2026-09-18

### Fixed
- Recover all previously imported asset memberships in affected albums without
  expanding selection transitively or uploading files again.
- Report newly created and reused Photos albums based on the actual Photos lookup.

### Tests
- Cover multi-album recovery, unselected imported memberships, unrelated albums,
  skipped unimported assets and idempotent recovery.

## [0.8.4] - 2026-09-18

### Fixed
- Use Nextcloud's supported query expression for selected-asset album membership lookup.
- Add DEBUG-only album recovery stage diagnostics and sanitized failure details without stack traces.

### Tests
- Match Photos 8.0.0 `AlbumMapper` method signatures in the SQLite harness and remove the unsupported `col()` test helper.

## [0.8.3] - 2026-09-18

### Fixed
- Recover albums related to selected imported assets even when the client sends
  an empty explicit album selection; match stable `local:` and `cloud:` asset IDs.
- Restrict asset-scoped recovery to albums containing selected imported assets.

## [0.8.2] - 2026-09-15

### Fixed
- Improve cancellation feedback and preserve completed upload results when an
  import is cancelled.
- Clarify that known media were already present before the current import run.
- Make the import-status detail list visibly scrollable and keep long messages readable.

## [0.8.1] - 2026-09-14

### Changed
- Remove obsolete retransferMissing behavior. Normal inventory of selected
  assets still recovers missing files; present files remain known. Legacy fields
  are tolerated.

### Fixed
- Companion macOS app: Login Flow v2 polling, credential handling, connection
  reset, Settings layout and localization of changed UI elements.
- Companion macOS app: central 20-second normal request timeout; the 1800-second
  upload timeout remains unchanged.
- Companion macOS app: per-item upload failure visibility, partial-run summaries,
  coordinated WebDAV folder creation and bounded retries for locked folders.

### Added
- Companion macOS app: separate debug window and library/selection summary.

## [0.8.0]

### Added
- Source-scoped identities, server-authoritative inventory and import runs.
- Original WebDAV uploads with reservations, collision protection, byte/hash
  verification and recovery after interrupted acknowledgements.
- Additive album inventory and Nextcloud Photos membership synchronization.
- Universal macOS companion app distributed separately from the server package.
