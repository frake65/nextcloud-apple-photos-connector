# Nextcloud APC for iOS (PhotoKit proof of concept)

This Xcode project is a PhotoKit gallery proof of concept. It does not connect
to Nextcloud or upload media. It uses the shared local Swift package at
`../shared/InventoryCore`.

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
