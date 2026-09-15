# Changelog

Changes follow the Keep a Changelog categories. This package contains the server
app; companion macOS changes below are provided for context.

## [Unreleased]

### Changed
- Prepare 0.8.1 for the App Store: SPDX license, documentation and support links,
  full license text and validated app-ID archive layout.
- Declare Nextcloud 34–35 compatibility and accept Photos 8.0.0 alongside 7.0.0.
  Full Photos 8 album integration validation remains pending.
- Unregister the two development-only album OCC commands; retain administrator
  album sync and the development classes.

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
