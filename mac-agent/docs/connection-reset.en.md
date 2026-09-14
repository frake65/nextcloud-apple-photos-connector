# Reset connection

## Behavior

Settings offers a secondary “Reset connection” button below the connection test/account actions. It is enabled for a saved identity, a validated connection, or an active login/validation attempt, not merely an unsaved draft. Confirmation explains that only this client's server, user and credentials are removed and Nextcloud data is unchanged. This supersedes the previous partial Disconnect action.

`ConnectionSession.resetConnection` retires the attempt ID and cancels login and validation tasks, then calls `ValidatedConnectionPersistence.resetConnection`. The latter deletes only the Keychain entry for the persisted server/user pair, clears those settings and invalidates connection/target confirmation. Draft identity, password and successful-state flags are cleared only after persistence succeeds. A Keychain deletion failure preserves the saved connection and reports an error; outstanding attempts remain retired. No network operation is used by reset.

Other scoped credentials remain untouched. Legacy entries are migrated to the persisted identity and removed before Settings is loaded. Reset does not guess ownership of an unscoped leftover. Target path, local history and other preferences are retained, with target confirmation invalidated.

Settings dismisses its directory picker and clears pending target selection. It broadcasts the existing connection-state notification so the main model reloads the empty identity and cancels any upload task retaining the previous connection. API clients are created per operation rather than cached; retired login results cannot create a validation client or commit credentials. UI publication after an actor hop also checks the attempt ID. Programmatic field clearing bypasses user-edit bindings and cannot reload credentials or start a new check.

## Verification

Seven regression tests cover empty/reset state and button eligibility, exact credential deletion and preservation of other accounts, late login/validation results, cancellation of both tasks, deletion failure consistency, inability to rebuild an authenticated client after reset, programmatic clearing and local-only preference changes. These exercise the shared state model; a live SwiftUI click-through was not performed.

Full macOS suite: 119 tests, 117 passing; two pre-existing upload tests report three failed assertions because the sandbox denies their Application Support receipt writes. All reset tests pass. The local debug app builds successfully. `git diff --check` passes. No version, tag, release or notarization changes.
