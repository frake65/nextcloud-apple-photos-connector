# Settings pause

## Lifecycle and pending work

`SettingsWorkGate.shared` is the central, in-memory admission barrier for library
work. `SettingsWindowLifecycle` binds it to the single SwiftUI Settings window:
opening pauses work; `NSWindow.willCloseNotification` resumes it. Reopening a
retained window is also observed through `didBecomeKeyNotification`. Losing
focus, presenting a sheet, minimizing, or hiding the app does not resume work.
The initial incomplete-configuration path activates the pause before requesting
that Settings open, preserving the deferred initial gallery load.

`CoalescingWorkRequest` owns the gallery refresh task and one pending flag.
Requests during the pause collapse into one refresh. Requests during an active
refresh produce at most one follow-up. Closing Settings without pending work
does not create a refresh. Waiters recheck the current gate state after waking;
a close/open sequence cannot grant stale permission. Existing UI scan and
album-run guards remain in place. `UploadCoordinator` also rejects concurrent
calls to `run`, including while its first call is waiting for Settings to close.

Settings connection checks, login flow and directory selection remain available.
There is no periodic import timer in the current agent.

## Operation boundaries and queue

Checkpoints protect gallery loading, asset and album inventory, album inventory
submission/sync, upload-run admission, inventory requests, new exports, and new
WebDAV upload steps. Photo authorization may suspend, so scans check again after
it returns. Thumbnail requests also wait. Gallery identity mappings are cached
per inventory so rendering and selection do not start new PhotoKit lookups.

An admitted operation is allowed to finish; opening Settings never cancels it.
A synchronous inventory batch can finish. An export already in progress can
finish, but its subsequent WebDAV upload waits. An admitted WebDAV upload step
(including directory preparation and PUT) and its completion acknowledgement
can finish. Receipts and completion results continue to be processed during the
pause. The queue admits no replacements while paused, retains its next index,
and refills to at most three active jobs after resume. Admission is the boundary:
pausing does not retroactively revoke a step already admitted on another actor.
Waits support task cancellation without requiring Settings to close.

Pending work is process-local; this is not a persistent job scheduler.

## Configuration snapshot

The UI captures connection, target root and `retransferMissing` after admission
and before scanning. It retains the selected-asset snapshot through inventory
filtering. Every upload job receives the same target root and connection. The
coordinator reads default target/retry values only once when omitted by a caller.
Later Settings edits affect a later run, not the remainder of the active run.
No additional credentials are persisted or logged.

## MainActor limitation

Gallery enumeration and initial cloud-identity mapping still execute on the
MainActor. Caching removes repeated PhotoKit mapping from view rendering, but
does not move the initial inventory off the UI actor. A synchronous batch that
started before opening Settings can therefore delay window presentation until
it returns. Once the window lifecycle activates the pause, no new protected
step is admitted. Moving gallery data acquisition to a background actor with a
well-defined transferable result remains separate concurrency work; this change
does not introduce unchecked transfers of PhotoKit objects.

## Tests and manual verification

`SettingsWorkGateTests` covers admission, paused/coalesced triggers, immediate
close/open, one follow-up after an active run, and cancellation.
`SettingsUploadPauseTests` exercises the production coordinator with fake
exporter/transport implementations: pause/drain/resume, the three-job bound,
duplicate-run rejection, cancellation and immutable configuration across queued
jobs and later runs. These tests require no Photos permission or live server.

Run `swift test --disable-sandbox` from `mac-agent`, with a writable scratch path
and `CLANG_MODULE_CACHE_PATH` where the execution sandbox requires it. The prior
baseline had 60 tests and three assertion failures in H4/H6h; the receipt path
under Application Support was not writable in the sandbox. Those tests and
receipt storage are unchanged.

Validation on 2026-09-12: 69 tests, 67 passed, two failing test cases (H4/H6h)
with the same three baseline assertions. All nine new tests passed.

AppKit/SwiftUI presentation is not exercised by the unit tests. Manual verification
should cover first launch, Settings via the menu/keyboard shortcut, repeated
close/reopen of the retained window, focus changes, and closing during upload.
