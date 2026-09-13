# macOS-Agent: Auswahl und Importworkflow

## Ergebnis

Die frühere Einstellung „Übertragungsumfang“ und ihre fachliche `ImportScope`-Logik wurden aus dem macOS-Agenten entfernt. Die Photos-Auswahl ist der lokale Kandidatenfilter. Der aktuelle Workflow verbindet Fotoimport und Albumverarbeitung als eine Benutzeraktion: **„Fotos & Alben übernehmen“**.

Der Agent sendet ausgewählte Assets als Inventory. Der Server entscheidet weiterhin authoritative über `new`, `known` und `present`; Uploads werden nur für tatsächlich erforderliche Dateien geplant.

## Album-aware Selection

Manuell ausgewählte Fotos und ausgewählte Alben werden getrennt geführt. Die effektive Auswahl ist:

```text
manuelle Auswahl ∪ Mitglieder der ausgewählten Alben
```

- Das Abwählen eines Albums entfernt nur diesen Auswahlgrund.
- Fotos, die manuell oder durch ein anderes Album ausgewählt sind, bleiben ausgewählt.
- `Select All` und `Deselect All` haben eine konsistente, explizite Semantik.
- Ein Album wird nur angelegt/verwendet, wenn mindestens ein relevantes ausgewähltes oder importiertes Foto dazugehört.
- Bei Teilmengen werden nur tatsächlich ausgewählte/importierte Fotos dem Album zugeordnet.
- Ein Foto in mehreren Alben wird nur einmal übertragen, aber mehreren Alben zugeordnet.
- Fehlende Fotos oder Albumzuordnungen führen zu keinen Löschungen.

Die Auswahl bleibt unabhängig von sichtbaren Gallery-Zellen und deren Lebenszyklus erhalten. Ein Album-Membership-Schritt kann daher auch für ein bereits importiertes Asset ausgeführt werden.

## Gemeinsamer Importworkflow

Die primäre Aktion heißt „Fotos & Alben übernehmen“; die Begriffe „Synchronisieren“ und „Spiegeln“ sind dafür nicht die fachliche Bezeichnung.

Der Ablauf ist:

1. effektive Fotoauswahl und relevante Albumstruktur als Snapshot bestimmen,
2. Fotos inventarisieren,
3. nur notwendige Dateien hochladen oder vorhandene Dateien wiederverwenden,
4. nach erfolgreichem Foto-Workflow Album-Mappings und Memberships verarbeiten.

Serverseitig bekannte Assets (`known`) gelten als erfolgreich und werden nicht erneut hochgeladen. Ein Ziel mit Zustand `present` führt ebenfalls zu keinem erneuten PUT. Recovery-, Reservation- und Kollisionslogik bleiben erhalten.

Die Regeln bleiben idempotent: keine doppelten Dateien, keine doppelten Alben oder Memberships, keine Entfernung bestehender Memberships und keine bidirektionale oder destruktive Synchronisation.

## Lazy Gallery

Die PhotoKit-Galerie wird lazy geladen. Die Galerie arbeitet indexbasiert mit der PhotoKit-Quelle, statt beim Öffnen die gesamte Mediathek in umfangreiche ViewModels zu materialisieren. Thumbnail-Anforderungen sind an den Zell-Lebenszyklus gekoppelt, begrenzt und abbrechbar.

Thumbnail-Erzeugung und Gallery-Layout wurden stabilisiert und verbessert: Die Grid-Zellbreite wird verbindlich vom Grid bestimmt, unabhängig vom Seitenverhältnis des Bildes. Die Zielgröße berücksichtigt Zellgröße und Display-Scale; die bestehende Begrenzung aktiver Thumbnail-Worker bleibt erhalten.

## Stale Album Mappings

Veraltete oder verwaiste Album-Mappings werden sicher repariert. Ein nicht mehr vorhandenes Zielalbum blockiert den aktuellen Lauf nicht dauerhaft. Gehört eine gemappte Album-ID inzwischen einem anderen Benutzer, wird das fremde Album nicht übernommen, verändert oder gelöscht; für den aktuellen Benutzer kann ein neues Mapping entstehen.

Die historische Apple-Album-Identität bleibt erhalten. Eine destruktive Synchronisation wird nicht eingeführt: Fremde Alben werden niemals gelöscht oder überschrieben, und fehlende Source-Daten entfernen keine bestehenden Memberships.

## Aufnahmedatum und Nextcloud Photos Timeline

Bei Dateien ohne eingebettetes EXIF-Aufnahmedatum hatte Nextcloud Photos den Uploadzeitpunkt als `photos-original_date_time` verwendet. Die verwendete Priorität ist:

1. EXIF `DateTimeOriginal`
2. unterstützte Datumsangabe im Dateinamen
3. Datei-mtime
4. Uploadzeit

Der Apple Photos Connector kennt das tatsächliche Aufnahmedatum bereits über `CaptureDateResolver`, gegebenenfalls als Fallback aus `PHAsset.creationDate`. Beim tatsächlichen WebDAV-PUT wird deshalb gesetzt:

```yaml
X-OC-MTime: <Unix-Timestamp des aufgelösten Aufnahmedatums>
```

Die Originaldatei wird nicht verändert: Es werden keine EXIF-Metadaten geschrieben, kein Re-Encoding durchgeführt und SHA-256 sowie Byteinhalt bleiben unverändert. `known` und `present` erzeugen weiterhin keinen PUT. Nextcloud kann dadurch auch bei metadatenlosen Bildern die korrekte Timeline-Zeit aus der Datei-mtime ableiten.

Im Realtest wurde ein JPEG ohne EXIF-Aufnahmedatum erfolgreich übertragen und in Nextcloud Photos dem erwarteten Aufnahmedatum zugeordnet.

## Zwischenzeitlicher HTTP-415-Fehler

Ein WebDAV-PUT wurde zunächst mit HTTP 415 abgewiesen. Die Serverantwort war:

```text
No connection to anti virus. Hochladen kann nicht abgeschlossen werden.
```

Die Ursache lag in der Nextcloud-/ClamAV- beziehungsweise Antivirus-Konfiguration und nicht bei `X-OC-MTime`. Nach Behebung der Antivirus-Verbindung funktionierte derselbe Upload einschließlich der korrekten Datumszuordnung. Eine dafür temporär ergänzte Response-Body-Diagnostik wurde anschließend vollständig entfernt.

## Tests und Qualitätsstand

- Swift Tests: 85 Tests, 0 Fehler
- `git diff --check`: sauber
- Produktiver Realtest der Aufnahmedatumszuordnung: erfolgreich
- Änderungen bis einschließlich `0dd6a96 Preserve photo capture time on upload` sind auf `origin/main`.

Relevante Commits:

```text
3e27170 Stabilize photo upload recovery flow
6ddef55 Repair stale album mappings safely
9339bda Add lazy PhotoKit gallery loading
85d3486 Improve gallery layout and thumbnail quality
ef37ad8 Implement album-aware photo selection
dc2a8fa Unify photo and album import workflow
0dd6a96 Preserve photo capture time on upload
```

## PhotoKit Library Change Observation – Phase 1 + 2

Implementiert in Commit:

```text
54d294c Observe PhotoKit library changes incrementally
```

### Funktion

Die laufende macOS-App beobachtet Änderungen der Apple-Fotomediathek über
`PHPhotoLibraryChangeObserver`, `PHChange` und
`PHFetchResultChangeDetails`. Der bestehende `PHFetchResult<PHAsset>` der
Lazy Gallery wird weiterverwendet.

Bei inkrementellen Änderungen werden neue, entfernte und geänderte Assets
erkannt. `fetchResultAfterChanges` wird übernommen; nur betroffene
Cache-Einträge werden invalidiert. Neue Assets werden weiterhin lazy über
`cell(at:)` materialisiert. Es erfolgt weder ein vollständiger Gallery-Rebuild
noch ein globales Leeren des Thumbnail-/Gallery-Caches.

Bei nicht inkrementellen Änderungen wird der Zustand als stale beziehungsweise
Full-Refresh markiert. Im Change-Callback wird die Mediathek nicht vollständig
materialisiert.

### Change Coordinator

Die neue Komponente
`mac-agent/Sources/MacAgent/PhotoLibraryChangeCoordinator.swift` implementiert
`PHPhotoLibraryChangeObserver`, registriert und deregistriert sich bei
`PHPhotoLibrary.shared()` und berücksichtigt, dass PhotoKit-Callbacks nicht auf
dem MainActor erfolgen müssen. UI- und App-State werden kontrolliert auf dem
MainActor aktualisiert.

### State

`PhotoLibraryChangeState` enthält:

- `revision`
- `galleryIsStale`
- `albumsAreStale`
- `requiresFullRefresh`
- betroffene `changedAssetIDs` und `removedAssetIDs`

### Selection und Upload

- `manuallySelectedAssetIDs` werden durch Library-Changes nicht automatisch gelöscht.
- `selectedAlbumIDs` werden nicht automatisch gelöscht.
- Lazy- oder unvollständige Gallery-Daten führen weiterhin nicht zu destruktiver Selection-Bereinigung.
- Ein bereits gestarteter Upload arbeitet unverändert mit seinem eingefrorenen Snapshot.
- PhotoKit-Änderungen verändern keinen laufenden Upload und starten keinen automatischen Upload.

### Alben

Phase 1 + 2 implementiert noch keine detaillierte Album-Membership-Beobachtung.
Albumdaten können als stale markiert werden. Für spätere Phasen offen bleiben
die gezielte Beobachtung des Albumkatalogs, neue oder gelöschte Alben,
Membership-Add/Remove und gezielte Re-Fetches relevanter Alben. Eine permanente
Beobachtung aller Album-Asset-Fetches wird nicht eingeführt.

### iCloud / Realtests

Die Implementierung wurde mit einer echten Apple-Fotomediathek und Änderungen
während laufender App getestet. Erfolgreich bestätigt wurden:

- ein neues Foto erscheint während laufender App ohne Neustart,
- Änderungen werden ohne App-Neustart erkannt,
- das Entfernen eines Fotos wird während laufender App verarbeitet,
- die Galerie bleibt stabil,
- die bestehende Auswahl bleibt erhalten,
- kein unerwünschter vollständiger Gallery-Rebuild erfolgt.

Damit ist die reale PhotoKit-/iCloud-Change-Observation bestätigt.

### Tests

Aktueller Stand: **93 Tests, 0 Fehler**.

Die neuen Tests decken eingefügte, entfernte und geänderte Assets,
nicht inkrementelle Änderungen, gezielte Cache-Invalidierung, unveränderte
Cache-Einträge, Revisionserhöhung, unveränderte Selection und einen
unveränderten eingefrorenen Upload-Snapshot ab.

### Status

Phase 1 + 2: abgeschlossen.

Nächster möglicher Schritt: Phase 3 – gezielte Erkennung von Änderungen des
Albumkatalogs.

## PhotoKit Library Change Observation – Phase 3

### Albumkatalog-Änderungen

Implementiert in Commit:

```text
363caa7 Observe PhotoKit album catalog changes
```

Für den Albumkatalog wird ein langlebiger
`PHFetchResult<PHAssetCollection>` gehalten. Änderungen werden über
`changeDetails(for:)` ausgewertet und der neue
`fetchResultAfterChanges` übernommen. Dabei werden stabile lokale
Album-IDs für folgende Fälle erkannt:

- `insertedAlbumIDs`
- `removedAlbumIDs`
- `changedAlbumIDs`

Der Zustand enthält außerdem eine `albumRevision`. Nicht inkrementelle
Änderungen markieren den Albumzustand vollständig als stale, ohne im
PhotoKit-Change-Callback einen vollständigen Scan aller Album-Mitgliedschaften
auszuführen.

`selectedAlbumIDs` und die Fotoauswahl bleiben unverändert. Diese Phase startet
weder einen automatischen Album-Sync noch einen automatischen Upload und führt
noch keine detaillierte Album-Membership-Verarbeitung durch. Gallery- und
Thumbnail-Logik bleiben unverändert.

### Tests und Realtest-Status

Der aktuelle Stand umfasst **95 Tests, 0 Fehler**. Die Tests decken Album-
Insertions, -Löschungen und -Änderungen, Revisionserhöhung sowie den Erhalt
der Selection ab.

Die PhotoKit-Change-Observation wurde mit einer echten Apple-Fotomediathek
getestet. Der Realtest-Status der Albumkatalogänderungen ist separat zu
bestätigen; die bestehende Galerie-Change-Observation bleibt erfolgreich.

### Offene Punkte / nächste Schritte

- Der sichtbare Albumkatalog wird noch nicht vollständig inkrementell fortgeschrieben.
- An definierten Checkpoints kann weiterhin ein vollständiger Albumkatalog-Load erfolgen.
- `PHCollectionList`-/Ordneränderungen werden noch nicht separat beobachtet.
- Nächste Phase ist die gezielte Beobachtung beziehungsweise Verarbeitung von Album-Mitgliedschaften.

## PhotoKit Membership Observation – Phase 4

### Album-Mitgliedschaftsänderungen

Implementiert in Commit:

```text
10b2295 Observe selected album membership changes
```

Membership-Änderungen werden nur für relevante Alben beobachtet. Die
`observedAlbumFetches` sind nach lokaler Album-ID indiziert; aktuell werden
die ausgewählten Alben beobachtet. Für jedes beobachtete Album wird ein
`PHAsset.fetchAssets(in: album, ...)`-Ergebnis gehalten und über
`PHChange` beziehungsweise `changeDetails(for:)` aktualisiert. Erkannt
werden:

- `insertedAssetIDs`
- `removedAssetIDs`
- `changedAssetIDs`

Das jeweilige `fetchResultAfterChanges` wird übernommen. Nicht inkrementelle
Membership-Änderungen setzen `requiresFullRefresh`. Es werden nicht alle
Alben dauerhaft beobachtet. Membership-Änderungen lösen weder eine
Serveraktion noch einen automatischen Upload oder Album-Sync aus.

`selectedAlbumIDs` und `manuallySelectedAssetIDs` bleiben erhalten. Die
dynamische Auswahlsemantik lautet weiterhin:

```text
effectiveSelection = manuallySelectedAssetIDs
  UNION Mitglieder der selectedAlbumIDs
```

Ein neues Foto in einem ausgewählten Album wirkt auf die zukünftige
`effectiveSelection`. Das Entfernen eines Fotos entfernt nur diesen
Auswahlgrund; andere Auswahlgründe bleiben erhalten. Ein laufender Upload
arbeitet unverändert mit seinem eingefrorenen Snapshot.

### UI-Auswahlanzahl

Membership-Deltas aktualisieren `selectedAssetIDs` korrekt. Zunächst blieb
die Button-Anzahl stale, weil `refreshEffectiveSelectionCounts()` nach
Membership-Deltas nicht aufgerufen wurde. Der Fix führt diese Aktualisierung
nach einer Membership-Änderung aus; dadurch werden `selectedPhotos` und
`selectedVideos` korrekt neu publiziert. Ein separater Counter wurde nicht
eingeführt.

### Tests und Realtests

Aktueller Stand: **105 Tests, 0 Fehler**. Die fachlichen Tests decken
Membership-Insert, -Remove und -Change, mehrere ausgewählte Alben, manuelle
Auswahl als weiteren Auswahlgrund, den Wegfall des letzten Auswahlgrunds,
den unveränderten Zustand von `selectedAlbumIDs` und
`manuallySelectedAssetIDs`, einen unveränderten Upload-Snapshot,
non-incremental Membership-Changes, Revisionen, mehrere Membership-Deltas,
das Ausbleiben einer Serveraktion und die abgeleitete Selection-Anzahl ab.

Erfolgreich realgetestet wurden das Hinzufügen und Entfernen von Fotos in
ausgewählten Alben, die automatische Selection, die aktualisierte
Button-Anzahl sowie die Union-Semantik über mehrere Alben und manuelle
Auswahl. Ein Foto bleibt über einen zweiten Auswahlgrund erhalten und fällt
erst nach Entfernung des letzten Auswahlgrunds aus der Selection.

Eine Membership-Änderung während eines laufenden Imports wurde bewusst nicht
manuell durchgeführt. Dies ist ein **akzeptiertes Restrisiko / nicht manuell
realgetestet**. Die Unveränderlichkeit des Upload-Snapshots ist durch
Unit-Tests abgesichert; es gibt keinen Hinweis auf einen bekannten Fehler.

### Offene Punkte / nächste Schritte

- Membership-Beobachtung für geöffnete, aber nicht ausgewählte Alben ist noch nicht implementiert.
- Es gibt keine dauerhaften Fetches für alle Alben.
- `PHCollectionList`-/Ordneränderungen werden nicht separat beobachtet.
- PhotoKit-Membership-Changes lösen keine automatische Server-Synchronisation aus.
- PhotoKit-Membership-Changes lösen keinen automatischen Upload aus.

## Offene Grenze

Die Auswahl wird im aktuellen Browsermodell gehalten; eine separate persistent
gespeicherte PhotoKit-Auswahl über einen App-Neustart hinweg ist nicht
Bestandteil dieses Dokuments. Der aktuelle Ablauf bricht bei leerer Auswahl
sicher ab, statt die gesamte Mediathek zu importieren.
