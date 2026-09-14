# Browser login investigation

## Cause and reproduction

Login Flow v2 starts against the server entered in Settings and polls the endpoint returned by that server. It already builds a fresh connection from the returned `server`, `loginName`, and `appPassword`, validates it, then saves it. There is no cached authenticated API client involved: `NetworkTransport` creates an ephemeral URLSession per request.

The primary defect was a mismatch between the transport and polling service: the real transport throws `UploadError.http(404)`, whereas the service only handled a returned response with status 404. The first pending response therefore terminated the client flow as `network`, even though the browser remained open and could finish authentication. The previous mock returned 404 without throwing, masking the defect. This also affects first-time login; a server switch is not required.

`testRealTransportStyle404ContinuesPolling` reproduces this without a browser. Running that test against the original service failed with `network`; the corrected service passes.

Additional state defects: passwords were keyed by username alone; editable server/user fields wrote directly to UserDefaults while retaining the old password; the synchronous `applyingLoginFlow` flag could not protect deferred SwiftUI change callbacks from invalidating success; cancelled or superseded requests could still publish results.

## Correction

Polling now treats a thrown HTTP 404 as pending too. Form fields are local drafts. Only user-originated binding writes invalidate the draft, clear the password on server/user changes, and cancel outstanding authentication attempts. Programmatic login results do not trigger this invalidation. Each attempt has an identity checked before saving; cancellation is checked after validation. The existing persisted connection remains intact until validation and Keychain persistence succeed.

Both manual and browser authentication use a main-actor commit with no suspension between credential and settings writes. The server-confirmed tuple replaces the active settings, invalidates target confirmation, marks the connection validated, and notifies the main view to reload preferences. This is an in-process transaction, not a crash-atomic transaction across Keychain and UserDefaults.

Keychain accounts include server URL (including installation path) and username. Legacy username-only entries migrate only to the persisted installation before drafts are edited, then are removed. Old scoped entries are never looked up for another server. CLI configuration uses the same scoped store. No password, app password, token, or authorization header is logged.

## Verification

Six new tests cover transport-style pending responses, Server B initiation and authoritative poll endpoint, returned server/user/password and fresh client/transport, first and replacement commits with validated state, same-username server isolation, failed Keychain commit preservation, and legacy migration. Existing password-operation tests continue to cover manual credentials. The SwiftUI interaction itself has not been exercised against two live Nextcloud instances.

Final macOS suite: 112 tests; 110 passed, two existing upload tests failed with three assertions because the sandbox denied writing the Application Support upload-receipts file. Login and credential tests pass. The local debug app build succeeds. `git diff --check` passes. No version change, release, tag, notarization, or deployment.

## Manual acceptance

Connect to A and confirm uploads are ready. Open Settings, replace the server with B and leave credentials empty. Start browser login, wait through several pending polls, and approve in B. Confirm the returned account/server is displayed, the connection is green, and the target requires confirmation. Reopen Settings and confirm B is restored. Repeat with the same username on both servers, cancel during polling, change server while waiting, and fail validation on B: no failed or superseded attempt may replace the saved A connection. Explicit manual credentials must still validate and save normally.
