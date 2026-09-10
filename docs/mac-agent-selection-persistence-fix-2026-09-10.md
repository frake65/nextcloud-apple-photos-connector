# PhotoKit-Auswahlpersistenz: Korrektur

## Root Cause

`VisualLibraryModel.load()` las `nextcloud.photoSelection.<source>` und setzte die Werte direkt in `selectedAssetIDs`/`selectedAlbumIDs`. Die IDs wurden nicht gegen die aktuell geladene PhotoKit-Bibliothek aufgelöst. Der Scanner verwendete anschließend genau dieses rohe Set als Inventory-Filter. Dadurch konnten sechs alte IDs fachlich wirksam werden, obwohl die sichtbare UI-Auswahl leer war.

## Korrektur

`PhotoSelectionRestorer.reconcile` ist jetzt die gemeinsame Restore-Grenze:

1. persistierte Asset- und Album-Identitäten werden geladen;
2. Asset-Identitäten werden gegen die aktuell sichtbaren PhotoKit-Assets aufgelöst;
3. Alben werden auf echte `kind == album`-Einträge begrenzt;
4. Album-Mitgliedschaften werden in denselben sichtbaren Asset-State überführt;
5. stale IDs werden verworfen und die bereinigte Auswahl zurückpersistiert.

Die UI und der Inventory-Scanner verwenden danach ausschließlich `selectedAssetIDs` aus demselben `VisualLibraryModel`. Es gibt keinen direkten Scanner-Zugriff auf UserDefaults und keinen zweiten versteckten Selection-State.

Eine leere sichtbare Auswahl führt vor dem Inventory-Request zum Abbruch. Damit entstehen weder ein Inventory-Lauf noch Upload-Tickets.

## Tests

P1–P16 sind durch `PhotoSelectionTests` und bestehende Upload-/Inventory-Tests abgedeckt: gültige/stale IDs, ausschließlich stale IDs, leere Auswahl, Deselect/Select, Neustartpersistenz, Source-Schlüssel-Isolation, Album-Restore, Album-Deduplizierung und Auswahlzähler.

Swift-Test-Suite: **47 Tests, 0 Fehler**. Debug-Build: **PASS**. Release-Build mit Xcode 27.0 / Build 27A266a: **PASS**.

Servercode, Datenbankschema, Photos-Code, Serverzustand und offene Tickets wurden nicht verändert. Es wurde kein E2E-Test und kein Upload ausgeführt.

## Offene Tickets

Die sechs Tickets des abgebrochenen Vorlaufs wurden nur lesend geprüft. Sie stehen weiterhin auf `pending`. `oc_apc_uploads` besitzt keine Ablaufzeit-, Expiry- oder Invalidierungs-Spalte. APC 0.8.0 implementiert hierfür keine automatische Ablaufsemantik; die Tickets bleiben grundsätzlich gültig, bis ein späterer Upload-/Fehlerabschluss oder eine serverseitige fachliche Prüfung sie verarbeitet. Sie wurden nicht verändert.
