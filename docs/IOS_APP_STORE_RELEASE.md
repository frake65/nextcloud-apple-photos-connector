# iOS App Store release preparation

Status: prepare an external TestFlight beta first, then decide on the public
App Store submission after tester feedback. No build has been submitted yet.

## Current repository findings

- App target: `de.applephotosconnector.iosagent`; minimum iOS: 17.0; iPhone
  and iPad are enabled.
- Release code-signing team is configured in the Xcode project, but the
  distribution archive, App Store Connect app record, and signing access have
  not been verified from this checkout.
- Explicit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` values are not
  present in the project settings. Choose the version/build in coordination
  with App Store Connect before archiving; do not infer it from the macOS or
  Nextcloud app versions.
- The iOS README had described an older inventory-only prototype. It has been
  corrected to match the current transfer and background-recovery code.
- The app uses required-reason APIs for app preferences, file metadata, and
  elapsed-time diagnostics. A privacy manifest is now included; verify that
  it appears in the archived app bundle and re-audit it if these call sites
  change. No public privacy-policy URL, localized store listing,
  review account, or store screenshot set was found in this repository. The
  App Privacy label must be based on the actual data flow, not inferred from
  source alone.
- This environment is Linux and has no `xcodebuild`; release archive,
  signing, TestFlight upload, and device verification must run on the
  project's Mac.

## TestFlight beta information draft

Beta description (German):

> Teste Photos Connector für iOS: Verbinde dich mit einer Nextcloud-Instanz
> mit installierter APC-Server-App und übertrage ausgewählte Fotos, Videos und
> Alben. Diese Beta dient besonders dazu, Upload-Fortschritt, Abbruch und
> Wiederaufnahme bei WLAN-/Mobilfunkwechseln zu prüfen.

What to test:

1. Connect to the dedicated review/test Nextcloud and grant the intended Photos
   access level.
2. Import a small photo selection and a larger video; confirm final status and
   server-side results.
3. Exercise the cellular-transfer preference, Wi-Fi loss/restoration, active
   upload cancellation, and app relaunch during recovery.
4. Import an album and confirm expected memberships.
5. Send feedback with device model, iOS version, approximate time, and steps;
   use test media only.

Feedback email: **to be supplied by the app owner**.

Apple requires TestFlight beta description, test instructions, and feedback
contact details for external testing; the first external build is reviewed
before testers can access it. Internal testing can be used for the initial
smoke test.

## Proposed product-page draft

Working name: **Photos Connector**

Working subtitle (German): **Fotos sicher nach Nextcloud**

Working subtitle (English): **Send Photos to Nextcloud**

Working description (German):

> Übertrage ausgewählte Fotos, Videos und Alben aus Apple Fotos direkt auf
> deinen Nextcloud-Server. Verbinde die App mit deiner Nextcloud-Installation,
> wähle Inhalte aus und behalte den Überblick über Fortschritt und
> Wiederaufnahme unterbrochener Übertragungen.
>
> • Fotos, Videos und Alben aus der iPhone- oder iPad-Fotomediathek auswählen
> • Übertragung an den selbst gewählten Nextcloud-Server
> • Mobilfunknutzung für Dateiübertragungen separat erlauben oder auf WLAN
>   beschränken
> • Zugangsdaten im iOS-Schlüsselbund speichern
>
> Erfordert eine Nextcloud-Installation mit der APC-Server-App. Die App
> überträgt nur die von dir ausgewählten Inhalte.

Working description (English):

> Transfer selected photos, videos, and albums from Apple Photos directly to
> your Nextcloud server. Connect to your Nextcloud installation, choose what
> to import, and follow transfer progress and recovery after interruptions.
>
> • Select photos, videos, and albums from your iPhone or iPad library
> • Transfer to a Nextcloud server you choose
> • Allow cellular data for media transfers or restrict them to Wi-Fi
> • Store your app password in the iOS Keychain
>
> Requires a Nextcloud installation with the APC server app. Only media you
> select is transferred.

This is draft copy, not approved metadata. Confirm the product name, exact
feature wording, localization, and server prerequisites against the release
build before use. The current app has many German-only UI strings and only a
small set of English translations. Either finish and review the full English
localization or launch with German as the only supported storefront language.

## Release gates

### Product and technical readiness

- [x] Release path selected: external TestFlight beta first; public App Store
  submission follows only after the beta and device test matrix pass.
- [ ] Agree on the App Store version and build number; set explicit Xcode
  versioning values and verify the generated archive metadata.
- [ ] On the project Mac, run the full iOS, shared-core, macOS, and server
  suites from the exact release commit; archive the Release configuration.
- [ ] Install the archived build on physical iPhone and iPad hardware and
  complete the release test matrix below.
- [ ] Resolve any remaining transfer-state or progress defects before
  submission. In particular, verify completion counters, cancellation, and
  Wi-Fi/cellular changes while a large upload is active.
- [ ] Confirm the release build contains no temporary diagnostic banner,
  verbose sensitive response logging, test endpoints, or development-only
  behavior.
- [ ] Check accessibility, dynamic type, VoiceOver labels, limited/full Photos
  permission, and the first-run experience.
- [ ] Resolve localization scope: the permission prompt is localized, but much
  of the app UI is still German-only despite an `en.lproj` resource folder.

### TestFlight beta and external review

- [ ] Confirm the App Store Connect app record uses bundle ID
  `de.applephotosconnector.iosagent` and that the name is available.
- [ ] Confirm account agreements, tax/banking setup if applicable, and access
  for the submitting developer.
- [ ] Set up an internal TestFlight group and complete a smoke test before
  external invitations.
- [ ] Enter beta description, test instructions, and a monitored feedback
  email in App Store Connect.
- [ ] Provide TestFlight review a dedicated Nextcloud/APC backend and working
  account; keep the service available through beta review.
- [ ] Submit the first external build for TestFlight App Review, then invite a
  small external group after approval. Hold off on a public invitation link
  until the network-transition and recovery cases pass.

### Before public App Store submission

- [ ] Provide a public privacy-policy URL and complete the App Privacy
  questionnaire based on the shipped app and any included SDKs.
- [ ] Complete the age-rating questionnaire and export-compliance questions.
- [ ] Prepare localized name, subtitle, description, keywords, support URL,
  marketing URL (if used), and copyright/contact details.
- [ ] Capture final screenshots from the release build for supported iPhone
  and iPad storefront sizes; use fictional account/server data.
- [ ] Keep a dedicated review Nextcloud/APC backend available and reachable
  for the review period. Provide App Review a working account and concise
  setup steps; never use a personal production account.
- [ ] Explain that the app requires the APC Nextcloud server app and describe
  how the reviewer can connect, grant Photos access, select sample media, and
  test an import. Avoid exposing real photos or personal server data.
- [ ] Choose manual release after approval for the first submission, so the
  app does not go live before a final check.

### Physical-device release test matrix

- [ ] Fresh install, first launch, denied/limited/full Photos permission.
- [ ] Login and connection validation on Wi-Fi and cellular.
- [ ] Inventory of known/new media and album synchronization.
- [ ] Successful photo and large-video uploads; verify destination and
  server-side completion.
- [ ] Wi-Fi to cellular with cellular transfers enabled.
- [ ] Wi-Fi loss with cellular transfers disabled, then Wi-Fi restoration.
- [ ] Disable cellular permission during an active cellular upload; verify it
  stops, remains recoverable, and resumes over Wi-Fi without duplicate or
  lost content.
- [ ] Cancel during foreground work, an active background PUT, and
  `waitingForConnectivity`; verify no later upload resumes.
- [ ] Background the app, force-quit, relaunch, and recover interrupted work;
  verify the final counters and terminal state.
- [ ] Repeat with a multi-item run and confirm completed items are not sent
  again.

## App Review notes draft

> Photos Connector transfers user-selected photos, videos, and albums from
> the iOS Photos library to a Nextcloud server running the APC server app.
> Review setup: [provide review server URL and dedicated credentials in
> App Store Connect, not in this repository]. Grant Photos access, open
> Transfers, choose the supplied sample items, and start the import. The
> transfer network preference applies to media uploads; login and connection
> checks may use cellular data. The review server and test account will remain
> available during review.

Replace the bracketed instruction in App Store Connect. Do not commit review
credentials or private server details.

## Apple references checked on 2026-09-25

- [Submitting an app](https://developer.apple.com/app-store/submitting/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App privacy details](https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy/)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)
- [App Store submission SDK requirements](https://developer.apple.com/news/?id=k1mtkt1k)

Apple's September 9, 2026 notice says Xcode 27 RC is available for submissions
using the new OS SDKs and that the iOS 27 SDK requirement begins in April 2027.
Confirm the currently accepted Xcode/SDK in App Store Connect when the archive
is prepared.
