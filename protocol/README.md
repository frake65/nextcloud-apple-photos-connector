# Connector API v1

Diese Beschreibung setzt eine frische Serverinstallation mit leerem Connector-Zustand voraus. Daten und Upgrade-Pfade früherer Entwicklungsstände werden nicht übernommen.

## Album-Inventar

`POST /index.php/apps/apple_photos_connector/api/v1/albums/inventory` überträgt ein versioniertes Album-Inventar mit HTTP Basic/App-Passwort und JSON. Album-Identität ist die Kombination aus Benutzer, `sourceId` und PhotoKit-`localIdentifier`; Namen sind nie technische Schlüssel. Beispiel:

```json
{"version":1,"source":{"sourceId":"550e8400-e29b-41d4-a716-446655440000","name":"Franks iCloud Photos"},"albums":[{"localIdentifier":"folder/a","kind":"album","cloudIdentifier":null,"name":"Sommer","parentLocalIdentifier":null,"assets":["asset/L0/1","asset/L0/2"]},{"localIdentifier":"folder/b","kind":"album","name":"Sommer","parentLocalIdentifier":"folder/a","assets":["asset/L0/1"]}]}
```

Das Schema steht in `album-inventory-request.schema.json`. Fehlende Alben und Mitgliedschaften werden nicht gelöscht; wiederholte Inventare sind idempotent. Alben verschiedener Sources bleiben getrennt. PhotoKit liefert Ordnerhierarchien nur, soweit `PHCollectionList` sie verfügbar macht; Cloud-Identifier können fehlen.

`POST /index.php/apps/apple_photos_connector/api/v1/inventory`

HTTPS, HTTP Basic Authentication mit Nextcloud-Benutzername und App-Passwort sowie `Content-Type: application/json` verwenden. Der Server authentifiziert über Nextcloud. Der Endpoint ist für normale angemeldete Benutzer verfügbar; anonyme und Cookie-only-Aufrufe werden abgewiesen. Keine CORS-Freigabe. Der Webserver muss den Authorization-Header an PHP weitergeben.

## Request

```json
{
  "source": {
    "sourceId": "550e8400-e29b-41d4-a716-446655440000",
    "name": "Franks iCloud Photos",
    "createdAt": "2026-09-07T20:00:00Z"
  },
  "assets": [
    {
      "localIdentifier": "example/L0/001",
      "cloudIdentifier": "opaque-photokit-string",
      "filename": "Midsommar_2015.jpg",
      "mediaType": "image",
      "creationDate": "2015-06-20T19:03:37Z"
    }
  ]
}
```

Das maschinenlesbare Schema steht in `inventory-request.schema.json`. `sourceId` und `name` sowie pro Asset `localIdentifier` und `mediaType` sind erforderlich. Fehlende optionale Asset-Felder werden als `null` behandelt. `createdAt` darf fehlen oder `null` sein; für neue Sources wird dann die Serverzeit verwendet. Das mac-agent-Scanformat ohne `source.createdAt` bleibt zulässig.

UUIDs werden kleingeschrieben gespeichert. Apple-Identifier bleiben unverändert und werden case-sensitive verglichen. Datumswerte müssen gültige RFC3339-Werte mit Zeitzone und höchstens sechs Nachkommastellen sein; Speicherung erfolgt als UTC-String mit Mikrosekunden. Ein Request enthält maximal 10.000 Assets. Größere Inventare können in mehrere Requests derselben Source aufgeteilt werden. Stringlimits gelten zusätzlich in UTF-8-Bytes (`x-maxBytes` im Schema); NUL-Zeichen und leere Identifier werden abgewiesen. Zusätzliche Felder werden ignoriert.

## Antwort und Identität

HTTP 200:

```json
{
  "assets": [
    {"cloudIdentifier": "opaque-photokit-string", "state": "new", "upload": {"uploadId": "73c6caa6-832c-44a5-a3b3-14ed9db25942", "assetId": "42"}}
  ],
  "runId": "c8e43b70-3c5b-4dd4-9f68-38d6b11902e0",
  "summary": {"seen": 1, "new": 1, "known": 0}
}
```

**Zustände:** `new` bedeutet ohne bestätigte Dateizuordnung, auch wenn das Asset bereits inventarisiert wurde. Erst nach erfolgreicher Upload-Bestätigung wird es `known` mit `upload: null`. Nur `new` erhält einen Upload-Auftrag. Reihenfolge und Anzahl der Antworten entsprechen dem Request. Doppelte unbestätigte Einträge bleiben beide `new`, teilen aber einen Auftrag. Der aktuelle Client dedupliziert seine Auftragsliste nicht ausdrücklich; siehe [Upload-Ablauf](uploads.md). Fehlt der Cloud-Identifier, enthält die Antwort explizit `"cloudIdentifier": null`; Zuordnung zum Request über die Position. Schema: `inventory-response.schema.json`. Client und Server müssen zueinander passende Upload-Endpunkte unterstützen.

Identitätsregeln, gekapselt in `AssetIdentity`:

1. Bei vorhandenem Cloud-Identifier zählt ausschließlich dessen exakte Übereinstimmung innerhalb desselben Benutzers und derselben Source.
2. Ohne Cloud-Identifier dient vorläufig `source_id + local_identifier` als Fallback. Dieser kann auch eine frühere Beobachtung mit Cloud-Identifier wiedererkennen.
3. Ein später neu verfügbarer Cloud-Identifier wird nicht automatisch mit einem bisherigen lokalen Datensatz zusammengeführt. Ein anderer Cloud-Identifier mit gleichem lokalem Identifier gilt ebenfalls als `new`.
4. Unterschiedliche Sources werden niemals zusammengeführt. Derselbe Source-UUID-Wert in unterschiedlichen Nextcloud-Konten gehört zu voneinander isolierten Registrierungen.

Der lokale Fallback ist ausdrücklich vorläufig: Zwischen mehreren Macs einer Source kann er Kollisionen haben. Eine separate Client-Identität ist in diesem Protokollschritt noch nicht enthalten. Bei mehreren gespeicherten Datensätzen mit gleichem lokalen Identifier wird vorläufig einer erkannt; Cloud-Identifier sind vorzuziehen.

## Import-Runs

Jeder authentifizierte JSON-Request, der den Inventory-Service erreicht, erzeugt genau einen persistenten Run mit einer serverseitig zufälligen UUIDv4. Wiederholungen, leere Inventare und einzelne Batches erhalten jeweils neue Run-IDs. Der Client gibt keine Run-ID vor. `summary.seen` entspricht der Anzahl übermittelter Einträge und der Antwortliste; `new + known = seen`. Doppelte Einträge werden entsprechend ihrer jeweiligen Antwort mitgezählt.

`apc_import_runs` speichert `run_id`, `source_id`, `user_id`, `started_at`, `completed_at`, `status`, `assets_seen`, `assets_new`, `assets_known`, `assets_uploaded`, `assets_failed` und einen optionalen technischen `error_code`. Zugriffe sind benutzergebunden; Zeitpunkte sind UTC mit Mikrosekunden. `completed` und `completed_at` beziehen sich weiterhin auf das Inventar. Die zwei Upload-Zähler beginnen mit 0 und werden durch spätere Bestätigungen atomar mit der Dateizuordnung aktualisiert. Sie zählen unterschiedliche Upload-Aufträge, nicht doppelte Request-Einträge. Wiederholte Bestätigungen erhöhen die Zähler nicht erneut.

Zuerst wird `running` separat committed. Source-/Asset-Änderungen und der Übergang zu `completed` werden danach gemeinsam atomar committed. Bei einem Verarbeitungsfehler wird die Inventartransaktion zurückgerollt und derselbe Run separat auf `failed` gesetzt. `completed_at` bezeichnet bei beiden Endzuständen den Abschlusszeitpunkt. Fehlgeschlagene Läufe haben `new = known = 0`; `seen` enthält die Länge der übermittelten Asset-Liste, bei ungültiger Listenstruktur 0.

Auch Validierungsfehler werden protokolliert. Ohne gültige Source-UUID ist `source_id` im fehlgeschlagenen Run `null`. Ein fehlgeschlagener erster Lauf kann eine gültige Source-UUID speichern, obwohl die Source-Anlage zurückgerollt wurde; deshalb besteht kein Fremdschlüssel auf die Source-Tabelle.

Authentifizierungs-, Content-Type- und Framework-Fehler vor dem Service erzeugen keinen Run. Kann bereits die Run-Anlage nicht gespeichert werden, ist ebenfalls kein Run garantiert. Bei Prozessabbruch oder Ausfall der Fehlerprotokollierung kann `running` bestehen bleiben; es gibt keine automatische Wiederaufnahme. Ein bereits gespeicherter `completed`-Status wird bei verlorener Commit-Bestätigung nicht auf `failed` überschrieben.

## Persistenz und Fehler

Ein validierter Inventarlauf wird als Transaktion geschrieben. Neue Sources erhalten `created_at` und `last_seen_at`. Bei bekannten Sources werden Name und `last_seen_at` aktualisiert; `created_at` bleibt erhalten. Neue Assets erhalten beide Seen-Zeitpunkte. Bei bekannten Assets wird ausschließlich `last_seen_at` aktualisiert. Nicht gemeldete Assets bleiben vollständig unverändert, einschließlich Zeitstempeln. Ein leeres Inventar aktualisiert die Source und schließt seinen Run mit drei Null-Zählern ab; Assets bleiben unangetastet.

Läufe einer bereits vorhandenen Source werden über die Source-Zeile serialisiert. Bei konkurrierender erstmaliger Registrierung kann HTTP 409 auftreten; der Client darf denselben Request wiederholen. Allgemeine Datenbankfehler rollen den gesamten Lauf zurück und werden als Serverfehler behandelt. Bei einem Retry nach verlorener Antwort können zuvor als `new` angelegte Assets bereits `known` sein.

| Status | Bedeutung |
| --- | --- |
| 200 | Inventar vollständig verarbeitet |
| 400 | Ungültige Felder, Datum, UUID oder Asset-Liste; keine Inventaränderung |
| 401 | Fehlende Authentifizierung bzw. erforderlicher Basic-Header fehlt |
| 415 | Kein JSON-Content-Type |
| 409 | Konkurrierende Source-Registrierung; Request wiederholen |
| 503 | Run-Anlage wegen DB-Fehler gescheitert; keine Run-ID garantiert |
| 5xx | Server-/DB-Fehler; Inventaränderungen und erfolgreicher Run-Abschluss sind atomar |

Controller-Fehler liefern `error` und, sobald verfügbar, `runId` gemäß `inventory-error.schema.json`:

```json
{
  "error": "source object and assets array required",
  "runId": "c8e43b70-3c5b-4dd4-9f68-38d6b11902e0"
}
```

Bei verlorener Antwort oder Commit-Bestätigung kann der Lauf trotz eines clientseitigen Fehlers abgeschlossen sein. Ein Retry erzeugt einen neuen Run und kann nach bestätigtem Upload `known` liefern. Framework-Fehler können ein anderes Antwortformat haben.

Nextcloud kann vor dem Controller eigene Authentifizierungsfehler liefern. Der Original-Upload nutzt Nextclouds vorhandenes WebDAV; siehe [Upload-Flow und Recovery](uploads.md). SHA-256 dient ausschließlich der Verifikation reservierter Uploads. Album-Endpunkte sind separat beschrieben. Keine Hash-Deduplizierung, Löschungen oder Source-Zusammenführung.


## Album-Abgleich

Der Album-Controller benötigt für jede Collection `kind: "album"` oder `kind: "folder"`. Mitgliedschaften können als `assets` oder `assetIdentities` übermittelt werden; referenzierte Assets müssen bereits im Inventar der Source vorhanden sein. Das vorhandene Album-Request-Schema beschreibt diese Erweiterungen noch nicht vollständig und ersetzt nicht die Controller-Validierung.

Die Speicherung des Album-Inventars erfolgt anhand Benutzer, Source und lokalem Collection-Identifier. Die anschließende Zuordnung zu Nextcloud Photos bevorzugt den Cloud-Identifier, mit lokalem Fallback. Ordner werden nicht als Photos-Alben angelegt.

`POST /index.php/apps/apple_photos_connector/api/v1/albums/sync` erwartet:

```json
{"sourceId":"550e8400-e29b-41d4-a716-446655440000"}
```

HTTP 200 enthält `status: "completed"` oder bei einzelnen Fehlern `"partial"` und `summary` mit `albumsSeen`, `albumsCreated`, `albumsReused`, `foldersSkipped`, `membershipsSeen`, `membershipsCreated`, `membershipsReused`, `membershipsSkippedNotImported` und `errors`. Fehlende Source bzw. fehlendes Album-Inventar ergibt HTTP 400. Wiederholungen ergänzen Mitgliedschaften, ohne fehlende Quelldaten als Löschauftrag zu behandeln.

## Optionale Wiederübertragung

`retransferMissing: true` im Asset-Inventar aktiviert die Prüfung bereits zugeordneter Dateipfade auf Existenz. Fehlende Dateien werden erneut als `new` mit Upload-Auftrag angefordert. Ohne Option bleibt die Prüfung ausgeschaltet. Es findet keine allgemeine Hash-Prüfung bekannter Dateien statt. Die vorhandenen JSON-Schemas sind teilweise älter als diese Erweiterung; maßgeblich für den aktuellen Implementierungsstand sind Controller und Services.
