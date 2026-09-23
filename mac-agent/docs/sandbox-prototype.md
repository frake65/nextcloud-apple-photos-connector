# App Sandbox prototype

The prototype is built with `build-store-sandbox.sh`. It uses the separate
`Resources/MacAgent.Store.entitlements` file and produces
`.build/Photos Connector Sandbox.app`. The existing Developer ID path continues
to use `Resources/MacAgent.entitlements` through `build-app.sh` and
`scripts/release-macos.sh`.

## Entitlements

The prototype contains only:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.personal-information.photos-library`

No broad filesystem entitlement and no Security-Scoped Bookmark entitlement is
used.

## Data-flow assessment

PhotoKit authorization uses `PHPhotoLibrary` with `.readWrite`. Inventory uses
`PHAsset` and `PHAssetResource`. Original export uses
`PHAssetResourceManager.writeData` into a unique directory below
`FileManager.default.temporaryDirectory`; the file is hashed/read for upload
and the directory is removed after the upload attempt. iCloud-optimized
resources request network access through `PHAssetResourceRequestOptions`.

Application Support stores the source identity, upload configuration and
recovery receipts. UserDefaults stores connection and target preferences.
These locations resolve inside the app container in a sandboxed build. A
future Store migration must explicitly copy or reconcile the existing
Developer ID locations; this prototype performs no migration and does not
delete old data.

The configured Nextcloud target is a relative WebDAV path sent over HTTPS. It
is not a local filesystem directory. Therefore Security-Scoped Bookmarks are
not required for this target. A bookmark would only be needed if a future
feature lets the user select a local directory outside the container and
retains access to it.

## ATS and networking

The generated Info.plist contains no `NSAppTransportSecurity` exception and no
`NSAllowsArbitraryLoads`. `URLSession` is used for the Nextcloud API and
WebDAV. The connection model already requires HTTPS. Self-signed or otherwise
untrusted certificates remain a TLS-error case and are not bypassed.

## Manual validation required

On a clean macOS user account, install the prototype and verify:

1. Photo permission prompt and authorized/limited/denied states.
2. Inventory of at least one local and one iCloud-optimized asset.
3. Original export, SHA-256/byte-size calculation, and temporary-file cleanup.
4. Keychain create, read, update and delete using the existing service
   `ApplePhotosConnector.Nextcloud` without clearing the Developer ID item.
5. HTTPS API status, inventory, WebDAV MKCOL/PUT and upload completion.
6. Restart during/after upload and receipt recovery from the sandbox
   Application Support directory.

The current automated PhotoKit tests are not a substitute for this run: the
XCTest process can block in the PhotoKit/gallery path in the non-interactive
test environment. No production workaround is justified by that behavior.
