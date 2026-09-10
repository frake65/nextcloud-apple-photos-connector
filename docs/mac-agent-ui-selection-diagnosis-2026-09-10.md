# macOS-Agent PhotoKit UI selection diagnosis — 2026-09-10

The previous `0 Fotos / 0 Alben` observation was a UI-state presentation problem, not a PhotoKit permission failure. The current release bundle logs `authorized`, fetches 7 image/video assets and 4 album collections, and renders the same library as `Fotos: 7 · Alben: 3 · Ausgewählt: 0`.

The view uses one `VisualLibraryModel` instance for PhotoKit contents, selection state, selection persistence, counters, and scanner candidate generation. Asset toggling now goes through `toggleAsset`, which updates `selectedAssetIDs` and persists the state. Album toggling already uses the same model. No second model instance was found.

The source-level and unit checks cover empty selection, stable identity, stale-ID reconciliation, album membership deduplication, candidate filtering, and persistence. The Swift suite passes 47/47; debug and release builds pass. The isolated UI confirms the seven visible assets and zero initial selection. No upload, inventory request, server change, rescan, or server-side action was performed.

Interactive click-by-click U1–U14 could not be completed through the available accessibility surface because the thumbnail cells expose no actionable AX children, although they are visibly rendered. This remains the only UI verification gap before the Phase-0 E2E retest.
