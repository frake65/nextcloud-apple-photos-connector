# Changelog

Changes follow the Keep a Changelog categories.

## [0.8.3] - 2026-09-18

### Fixed
- Run album synchronization for affected albums identified through selected
  imported assets, including when no explicit album selection is supplied.
- Keep album inventory and synchronization failures separate from file
  transfer failures. Successful uploads and `nothingToDo` runs no longer become
  "Transfer failed" solely because an album operation failed.
- Classify `uploaded=0 failed=0` and `errors=0` album summaries as successful,
  report partial album summaries as warnings, and preserve genuine upload
  failures as transfer failures.

### Verified
- Manually verified both the idempotence path and album recovery against the
  deployed server: known files were not uploaded again, existing memberships
  were reused or restored, and the client reported success correctly.
- Release bundle is Developer-ID signed and Apple-notarized, with a stapled
  ticket; it is universal for arm64 and x86_64 and targets macOS 14 or newer.
