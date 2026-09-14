# Apple Photos Connector: Upstream-Gap-Analyse

Stand der Analyse: 10. September 2026. Untersucht wurden der lokale APC-0.8-Serverstand, die öffentlich dokumentierten Nextcloud-Schnittstellen und der aktuelle Nextcloud-Photos-Code für die geplante 35/8-Linie. Dieses Dokument ist eine Architekturprüfung. Es ändert weder das APC-Design noch das Nextcloud-/Photos-Repository.

## Ergebnis

Ein robuster Import ist mit WebDAV allein **teilweise** möglich. Dateien können über das normale Files-WebDAV hochgeladen und über `If-None-Match: *` vor einfachem Überschreiben geschützt werden. Photos stellt DAV-Integration, Albumanzeige und interne Albumoperationen bereit; die aktuelle `info.xml` deklariert DAV-Unterstützung und die Commands `photos:albums:create` und `photos:albums:add`.[^photos-info] Die dokumentierte WebDAV-API deckt Datei-/Ordneroperationen, Upload, MKCOL und Properties ab.[^webdav]

WebDAV allein liefert jedoch keine serverautoritative externe Asset-Identität, keine Import-Session, keine persistente Upload-Reservierung mit Hash-/Byte-Vertrag, keine Recovery nach verlorener PUT-Antwort, keine autorisierte Zieländerung und keine generische Album-Mapping-Identität. Für diese Garantien bleibt eine serverseitige generische Importkomponente erforderlich.

Die beste Upstream-Richtung ist daher **C**: eine kleine generische External Photo Import API in Photos oder einer eng gekoppelten Nextcloud-Komponente. Variante B, eine kleine Photos-Erweiterung nur für Importzustände und Commit, ist ein sinnvoller erster Upstream-Schnitt. Variante A eignet sich als eingeschränkter Prototyp, nicht als robuster Mehrgeräte-Importer.

## APC-Funktionsinventar

| Funktion | Warum benötigt | Server zwingend? | Client möglich? | Apple-spezifisch? |
|---|---|---|---|---|
| Source registration / `sourceId` | Mehrere Mediatheken und getrennte Identitätsräume | Ja, wenn mehrere Clients sicher zusammenarbeiten | Lokaler UUID-Cache möglich, aber nicht autoritativ | Nein |
| Asset inventory | Delta-Entscheidung vor Upload | Ja für geteilten Zustand; rein lokaler Einmalimport auch clientseitig | Teilweise | Nein |
| Stabile externe Asset-Identität | Cloud-Identifier bevorzugen, lokalen Fallback verwalten | Ja für Restart-/Mehrgeräte-Sicherheit | Nur für einen Client | Nein |
| `new`/`known` | Uploads begrenzen und Wiederholungen steuern | Ja | Clientcache nicht ausreichend | Nein |
| ImportRun | Audit, Korrelation, Zähler, Fehlerstatus | Ja | Nein | Nein |
| Upload reservation | Ziel und Asset atomar binden | Ja | Nein | Nein |
| Collision protection | Fremddateien niemals überschreiben | Server braucht letzte Schranke | Client kann vorprüfen | Nein |
| PUT-Recovery | verlorene Antwort über Inhalt und Reservation wiederfinden | Ja | Lokales Journal hilft nur ergänzend | Nein |
| Bytes/SHA-Verifikation | keine falsche Dateizuordnung | Server muss tatsächliche Datei prüfen | Clienthash allein nicht vertrauenswürdig | Nein |
| Target/path history | alte Targets erhalten, Current explizit wählen | Ja | Nein | Nein |
| Current target | genau ein autoritativer Bezug eines Assets | Ja | Nein | Nein |
| Recovery fehlender Dateien | beim normalen Inventar ausgewählter Medien fehlende Dateien als `new` anbieten | Entscheidung bleibt serverseitig; die frühere Option ist entfernt | Auslöser ist ein normaler Importlauf | Nein |
| Server-authorized retarget | kein willkürlicher Zielordnerwechsel | Ja | Nein | Nein |
| Album inventory | externe Collection-Identität und Mitgliedschaften abbilden | Für Wiederholung und Isolation ja | Snapshot kann clientseitig erzeugt werden | Nein |
| Album memberships | additive, idempotente Zuordnung | Server/Photos muss sie besitzen | Nein | Nein |
| Photos album creation | Zielalbum anlegen | Photos-API/Photos-Service | Client kann nur Namen senden | Nein |
| Photos album membership | Datei-ID in Album aufnehmen | Photos-Service | Client kann Pfad/Datei-ID anfordern | Nein |
| User/source isolation | keine Cross-user-/Cross-source-Zuordnung | Ja | Nein | Nein |
| Idempotency | Retries ohne Doppelobjekte | Ja | Nein | Nein |
| Replay/race protection | parallele Prepare/Complete sicher serialisieren | Ja | Nein | Nein |

Die aktuelle APC-Implementierung trägt diese Verantwortlichkeiten in `InventoryService`, `InventoryRepository`, `UploadTargetService`, `UploadService` und den Album-Services. Die Binärdaten selbst werden bereits über Nextcloud-Dateisystem/WebDAV getrennt von der Importdatenbank übertragen.

## Was Nextcloud/Photos heute abdeckt

### Public/stable

- Files-WebDAV unterstützt authentifizierte Datei- und Ordneroperationen, PUT, MKCOL, Properties und bedingte Requests.[^webdav]
- Nextclouds öffentliche Files-API stellt unter anderem `IRootFolder`, User-Folder, Datei-/Ordnerzugriff und Dateikennungen bereit. In Nextcloud 33+ existiert auch `Folder::getOrCreateFolder`, was eine sichere Parent-Erzeugung über die Files-Abstraktion erlaubt.[^folder]
- Login Flow v2/App-Passwörter sind für externe Clients dokumentiert.[^clients]
- Photos registriert DAV-Unterstützung und einen Photos-DAV-Root. Die Photos-Dokumentation und die öffentliche App-Metadatei belegen diesen Integrationspunkt.[^photos-info]

### Photos-intern, daher keine gewünschte Integrations-API

Der aktuelle Photos-Code verwendet intern `AlbumMapper`, `RootCollection`, `PhotosHome` und SabreDAV-Klassen. `AlbumCreateCommand` erstellt Alben über `AlbumMapper::create`; `AlbumAddCommand` löst einen User-Files-Pfad auf und ruft `AlbumMapper::addFile` auf.[^album-create][^album-add] Das sind interne PHP-Services/Commands, keine stabile externe Client-API. Die Photos-Routen exponieren Album-Lesen und Vorschauen, aber keinen dokumentierten generischen Album-Create-/Membership-REST-Endpunkt.[^routes]

Photos registriert zudem eigene Sabre-Plugins über `SabrePluginAddEvent`; diese Erweiterbarkeit ist für eine Photos-interne oder separate App-Erweiterung relevant, macht `AlbumMapper` aber nicht zu einer public API.[^sabre]

Datei-IDs, Photos-Alben und Metadaten können deshalb nicht sicher über direkte Zugriffe auf Photos-Tabellen oder interne Mapper als langfristige Integrationsvertrag behandelt werden. Ein Upstream-Vorschlag sollte eine öffentliche Schnittstelle definieren und die interne Persistenz verborgen lassen.

## Issue #3623

Issue #3623 trägt den Titel „Synching Apple Photos to NextCloud photos“ und ist aktuell offen, mit den Labels `0. Needs triage` und `enhancement`; es steht im Community-Triage-Projekt im Backlog, ohne Assignee, Milestone, PR oder Maintainer-Entscheidung.[^issue]

Der beschriebene Bedarf ist Metadaten-erhaltender Export aus Apple Photos: Titel, Beschreibung, Keywords und Aufnahmedatum sollen beim Übergang in Nextcloud Photos erhalten bleiben. Der Issue-Text spricht von einer Exportfunktion und einer Integration in Nextcloud Photos; er legt keinen Two-way-Sync-Vertrag fest. Favorites, Deletes, Live Photos, Konfliktauflösung und Albumsemantik sind dort nicht entschieden. Aus dem Issue lässt sich keine Akzeptanz einer bestimmten Architektur ableiten.

## Minimalvariante ohne Server-App

`PhotoKit → WebDAV Files + Photos-DAV` reicht für einen einfachen one-way Export mit optionaler Albumanlage, sofern der Client die Zielpfade und die Photos-DAV-Semantik genau kennt. Für einen robusten Import verliert man dabei:

- serverautoritative Identität über mehrere Macs/Libraries;
- sichere Delta-Erkennung nach Client-Neuinstallation;
- dauerhafte Reservation und Recovery nach unklarer PUT-Antwort;
- atomare SHA-/Byte-Bestätigung mit Datei-ID;
- serverseitig erlaubtes Retargeting bei fehlender Datei;
- belastbare Replay-/Race-Semantik;
- stabile Zuordnung externer Albumidentitäten;
- Schutz davor, dass ein beschädigter oder manipulierter Client fremde Pfade übernimmt.

Clientseitige Quittungen und Hashes reduzieren Risiken, ersetzen aber keine serverseitige Autorität. Fehlende Apple Assets dürfen weiterhin keine Löschung in Nextcloud auslösen; das lässt sich clientseitig einhalten, sollte aber als Serverregel gelten.

Bewertung: **TEILWEISE**. Für einen einzelnen, kontrollierten Client genügt die Minimalvariante; für den APC-Garantiekatalog nicht.

## Kleinste generische Erweiterung

Eine generische API sollte keine Apple-/PhotoKit-Begriffe enthalten. Ein mögliches Modell:

1. `ExternalPhotoSource`: user-scoped `sourceId`, display name, provider-neutral metadata.
2. `ExternalAsset`: `(sourceId, externalIdentity)`, optional media metadata, current imported file reference.
3. `ImportSession`: server-generated session ID, seen/new/known counters, status and error state.
4. `ImportItem`/`ImportTicket`: asset ID, expected filename, bytes, SHA-256, current target ID, base target ID, server-authorized `retargetAllowed`.
5. `ImportTarget`: immutable historical reservations; unique `(user, pathKey)`, non-unique asset index, one explicit current target.
6. `AlbumBinding`: provider-neutral external collection identity to a Photos album, plus additive file memberships.

The API should expose `inventory`, `prepare`, `complete`, and an additive album-binding operation. WebDAV remains the binary transport. `prepare` returns a server-chosen path and state (`missing`/`present`); `complete` re-hashes the actual file and atomically commits current target, file reference and ticket state. No endpoint should allow a client to set `retargetAllowed`; only the server may issue it after checking that the current file is genuinely missing and the session requested retransfer.

This same model can serve Apple Photos, digiKam, Lightroom-like archives and other external photo stores. Apple-specific CloudIdentifier resolution, PhotoKit export rules, Live Photo policy and source scanning remain in the macOS agent.

## Security and idempotency boundary

These guarantees must remain server-side: user/source ownership, identity uniqueness, path uniqueness, conditional target selection, actual file verification, current-target transition, ticket lifecycle, replay handling and serialization. WebDAV should receive only the server-selected path and the client’s conditional PUT. The server must never delete old targets or files because an external inventory omits them.

The client may cache source configuration, upload receipts and album selections. Those are recovery hints, never authority. A changed client folder is data for a new authorized reservation, not permission to move an existing current target.

## Architecture comparison

| Variant | Complexity | Robustness | Upstream chance | Maintenance | Security | Portability |
|---|---:|---:|---:|---:|---:|---:|
| A. Agent + existing APIs | Low | Low/medium | High as a prototype | Low initially, high edge-case burden | Medium | High |
| B. Agent + small Photos extension | Medium | High for import state | Medium/high | Medium | High | High for generic clients |
| C. Agent + generic External Photo Import API | Medium/high | Highest | Medium, if scoped narrowly | Lowest after adoption | Highest | Highest |

Recommendation: pursue B as the first reviewable upstream proposal, with the data model and endpoint semantics shaped so it can become C. Keep APC-0.8 as the reference implementation and do not couple the proposal to its table names.

## Draft comment for issue #3623 (not posted)

> We have a working PhotoKit/macOS prototype that exports originals and preserves Apple Photos metadata while uploading to Nextcloud. Our initial implementation uses a separate server app for source identity, import sessions, durable upload reservations, recovery after lost PUT responses, collision-safe paths, and additive album membership.
>
> We would like to understand which direction the Photos maintainers would consider appropriate before proposing code. Basic file transfer can remain ordinary Files WebDAV, while Photos could expose a small provider-neutral import contract for external source identity, asset state, import tickets, commit/recovery, and album bindings. Apple-specific PhotoKit and CloudIdentifier logic would stay in the macOS client. This could also serve digiKam or Lightroom-like clients.
>
> Would maintainers prefer a small Photos-specific extension, a generic external-photo-import API, or an existing API combination? In particular, which parts of album creation/membership and metadata import are intended to be public for external clients? We would be happy to reduce the proposal to the smallest upstreamable slice and provide the working prototype as a reference, without assuming that its current server architecture should be adopted.

## Conclusions

APC server functions: source/asset identity, inventory sessions, upload tickets and reservations, collision/recovery/hash verification, current-target history, retarget authorization, album inventory/mapping, user/source isolation and replay/race safety.

Existing Nextcloud APIs: authenticated Login Flow, Files/WebDAV upload/MKCOL/properties, Files filesystem abstractions and Photos DAV/read paths. Existing Photos internals: album mapper and commands, useful as implementation evidence but not a stable external API.

Missing without APC server: authoritative external identity, durable import state, reservation/commit/recovery, authorized retarget and provider-neutral album binding.

Minimal variant: partially viable only.

Generic import API: justified if Nextcloud wants robust external-library imports; it should be provider-neutral and retain WebDAV for bytes.

Recommended architecture: a small Photos extension first, designed as a generic External Photo Import API; retain the APC-0.8 implementation as a reference and do not change it for this analysis.

Risks: public API design and long-term compatibility, album semantics, metadata schema, Photos version support, large-library performance, concurrent clients, and unresolved product decisions around deletes, favorites, Live Photos and two-way sync.

[^photos-info]: [Nextcloud Photos `appinfo/info.xml`](https://github.com/nextcloud/photos/blob/master/appinfo/info.xml)
[^webdav]: [Nextcloud WebDAV documentation](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/index.html)
[^folder]: [Nextcloud public Files `Folder` API](https://github.com/nextcloud/server/blob/stable34/lib/public/Files/Folder.php)
[^clients]: [Nextcloud client APIs and Login Flow](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/index.html)
[^album-create]: [Photos `AlbumCreateCommand`](https://github.com/nextcloud/photos/blob/master/lib/Command/AlbumCreateCommand.php)
[^album-add]: [Photos `AlbumAddCommand`](https://github.com/nextcloud/photos/blob/master/lib/Command/AlbumAddCommand.php)
[^routes]: [Photos routes](https://github.com/nextcloud/photos/blob/master/appinfo/routes.php)
[^sabre]: [Photos `SabrePluginAddListener`](https://github.com/nextcloud/photos/blob/master/lib/Listener/SabrePluginAddListener.php)
[^issue]: [nextcloud/photos issue #3623](https://github.com/nextcloud/photos/issues/3623)
