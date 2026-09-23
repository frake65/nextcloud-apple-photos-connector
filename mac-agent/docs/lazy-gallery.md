# Lazy gallery

## Source and startup

`GalleryLibrary` owns a media-type-filtered `PHFetchResult<PHAsset>` on a background
actor. Opening the gallery fetches this reference and its count, without walking
the assets, mapping all cloud identifiers, or requesting images. `LazyVGrid`
uses integer indices. A cell task retrieves one small `GalleryAsset`; its local
identifier identifies the loaded content. A new fetch generation replaces the
grid identity, so indices cannot retain content from an earlier fetch.

The persisted selection is read in full, independently of cells. Only that
selection is resolved after the gallery is published, to restore counts and
selected album members. A very large persisted selection still takes time;
selection controls and upload wait for this operation while the gallery and
Settings remain responsive. An empty selection does not cause album queries.

## Identity and selection

Cloud mappings run on `GalleryLibrary`, in blocks of at most 128 assets, with
`SettingsWorkGate` checkpoints between blocks. Visible cells resolve one asset;
the metadata/identity cache holds at most 512 entries. Mapping failure retains
the local-identifier fallback. No `PHAsset` or `PHFetchResult` crosses the actor
boundary. Selection and counts are independent of the bounded metadata cache.

`PhotoSelectionRestorer.reconcile()` is no longer used for the gallery. Missing
or inaccessible persisted identities are not silently removed. Successfully
resolved local selections can be promoted to cloud identities. Upload first
resolves the frozen membership again in case a local fallback has since gained
a cloud identity. Later UI edits cannot change that snapshot. The unchanged
upload scanner checks the complete selection and rejects incomplete
inventory rather than uploading just the visible part.

Single-cell selection uses the already resolved identity and updates counts
without scanning the gallery. Select All explicitly walks the complete fetch
in background batches and returns the identity set and media totals. Album
selection resolves all members of the selected album. The existing additive
selection/deselection behavior for overlapping albums is retained.

## Albums

The gallery no longer invokes the full album inventory at startup. Opening the
album tab, or restoring a saved album selection, requests a catalog of album
names, identities, PhotoKit media counts and one cover identifier per album.
It does not enumerate membership lists. Full members are resolved only for
selected albums. Before catalog loading, the album total is shown as unknown.
Album sync and the upload scanner/protocol are unchanged.

## Images and cancellation

The existing 180-by-180, fast-format, aspect-fill, local-only PhotoKit request
settings are preserved. `GalleryThumbnailLoader` admits at most eight workers;
queued cells that disappear are removed, active cells cancel the PhotoKit
request. The callback bridge records the request ID and consumes its continuation
once, even with cancellation before ID delivery or duplicate/late callbacks.
Cell tasks check cancellation before publishing images and release image state
on disappearance.

`PHCachingImageManager` remains in use. An `NSCache` reuses up to 128 images with
a 16 MiB estimated-cost limit; these are cache eviction targets, not a hard
process-memory limit. PhotoKit manages its own internal memory. There is no
scroll preheating or custom paging. Fetch reloads invalidate the image cache.

## Settings and main actor

Initial PhotoKit fetches, identity resolution, album queries and thumbnail
requests run outside the MainActor and check the shared gate. Already admitted
bounded work may finish. Opening Settings does not itself cancel a request;
disappearing cells do. At most eight thumbnail workers wait for admission and
cancelled queued cells do not restart when Settings closes. Gallery reloads and
album catalog requests are coalesced.

The MainActor publishes UI state, maintains selection sets, persists selection
and manages the thumbnail queue/cache. Selection persistence and large set
updates still have a cost proportional to selection size. Full-library PhotoKit
enumeration and per-asset cloud mapping no longer block the UI actor.

## Verification and manual build

`GalleryLoadingTests` exercises the production model and request loader with a
100,000-asset simulated source, offscreen/persisted selection, Select All, album
selection, bounded requests, reuse, late completion, direct callback races and
Settings admission/coalescing. It does not measure real PhotoKit latency or
SwiftUI's precise visible/prefetch range. Existing settings and upload tests
remain part of `swift test`.

Validation on 2026-09-12: all 82 Swift tests passed, including 13 new gallery
tests and all 69 existing tests. The run used approved access to the normal
compiler caches and Application Support paths; the earlier sandbox-only cache
and receipt failures did not occur. No test paths or receipt storage were changed.

Build with `CONFIGURATION=debug bash build-app.sh` from `mac-agent`. The script
ad-hoc signs .build/Photos Connector.app and does not launch it. Gallery events are
written only when Debug is enabled, to
`~/Library/Logs/Apple Photos Connector/debug.log`: `gallery.fetch.count`,
`gallery.initial.ready`, identifier batch sizes, and thumbnail active/cancel
events. They contain no asset identifiers or filenames.

Manually verify startup/CPU/RAM with a large library, fast scrolling away/back,
selection in distant regions and upload of that selection, then opening/closing
Settings during scrolling and Select All. Actual iCloud availability and Photos
permissions are outside the simulated tests. There is no new live-library change
observer; an existing explicit reload replaces the fetch snapshot.
