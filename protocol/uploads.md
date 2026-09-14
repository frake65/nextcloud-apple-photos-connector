# Original-Upload, Reservierung und Recovery

1. Inventory-POST senden. Nur Einträge mit `state: new` und einem `upload`-Auftrag verarbeiten. Zuordnung zur lokalen PhotoKit-ID erfolgt über die Position im Request. Doppelte `uploadId` sollten nur einmal bearbeitet werden; der aktuelle Coordinator erzeugt allerdings einen Auftrag pro `new`-Antwortzeile und dedupliziert diese Liste nicht ausdrücklich.
2. Primäre Originalressource mit PhotoKit exportieren, einschließlich eines gegebenenfalls notwendigen iCloud-Downloads. Dateigröße und SHA-256 inkrementell aus den Originalbytes bestimmen. Kein Rendern, keine Bearbeitung, keine Live-Photo-Begleitvideos oder zusätzlichen RAW/JPEG-Ressourcen.
3. Zielordner standardmäßig `Photos/Apple Photos Connector/YYYY/MM/` im authentifizierten Nextcloud-Konto per WebDAV `MKCOL` anlegen. **Vor jedem PUT** `uploads/prepare` aufrufen: Der Server reserviert einen Pfad dauerhaft pro Asset und prüft eine dort bereits vorhandene Datei über tatsächliche Größe und SHA-256. `present` überspringt den PUT und geht direkt zur Bestätigung. `missing` erlaubt einen bedingten PUT auf genau diesen Pfad.
4. Upload per `PUT /remote.php/dav/files/{user}/{reservierter-pfad}` mit HTTP Basic Authentication und **`If-None-Match: *` bei jedem Versuch**. HTTP 201 bedeutet neu erstellt. HTTP 412 führt erneut zur Vorbereitung desselben Assets, nicht eigenständig zum nächsten Dateinamen. Transportfehler oder andere HTTP-Status lassen die serverseitige Reservierung erhalten. Kein unbedingtes PUT, kein DELETE, kein Redirect-Following.
5. Originalname bleibt unverändert, sofern frei. Bereits vorhandene unreservierte Dateien werden niemals übernommen, auch bei identischem Inhalt. Nur ein bestätigter Konflikt führt serverseitig zu `stem--apc-{assetId}.ext`, dann `stem--apc-{assetId}-1.ext` usw. Maximal 100 Kandidaten. Fremde Dateien bleiben erhalten. Fehlende, unsichere oder vom Export abweichende Originalnamen führen zum Fehler.
6. Nach HTTP 201 oder `present` die Dateizuordnung bestätigen. Der Server prüft erneut Reservierung, Größe und SHA-256 der tatsächlichen Datei sowie den Benutzerzugriff und speichert Datei-ID, Pfad und Uploadzeitpunkt. Er akzeptiert nur einen zum Benutzer, zur Source und zum abgeschlossenen Inventarlauf gehörenden Auftrag. Keine Zuordnung über eine frei angegebene Datei-ID.

## Bestätigung

`POST /index.php/apps/apple_photos_connector/api/v1/uploads/complete`

Gleiche Basic-Authentifizierung und JSON-Content-Type wie Inventory. Request-Schema: `upload-request.schema.json`.

```json
{
  "sourceId": "550e8400-e29b-41d4-a716-446655440000",
  "runId": "c8e43b70-3c5b-4dd4-9f68-38d6b11902e0",
  "uploadId": "73c6caa6-832c-44a5-a3b3-14ed9db25942",
  "status": "uploaded",
  "path": "Photos/Apple Photos Connector/Midsommar_2015.jpg"
}
```

HTTP 200, Schema `upload-response.schema.json`:

```json
{
  "runId": "c8e43b70-3c5b-4dd4-9f68-38d6b11902e0",
  "uploadId": "73c6caa6-832c-44a5-a3b3-14ed9db25942",
  "status": "uploaded",
  "summary": {"uploaded": 1, "failed": 0}
}
```

Bei Export-/Uploadfehler `status: failed` und keinen Pfad senden. Das Asset bleibt ohne erfolgreiche Zuordnung erhalten und wird im nächsten Inventar erneut `new`. Ein bestätigter Erfolg bleibt auch bei verspäteten Fehlermeldungen anderer Aufträge erhalten. Derselbe Auftrag darf nach `failed` noch erfolgreich bestätigt werden, etwa nach Wiederherstellung einer verlorenen Antwort; der Fehlerzähler wird entsprechend korrigiert. Eine erfolgreiche Zuordnung wird nicht durch einen anderen Pfad ersetzt.

HTTP 400: ungültiger Auftrag/Status/Pfad, fehlende Reservierung oder abweichender Inhalt; 401: Authentifizierung; 415: Content-Type; 500: Dateisystem-/Datenbankfehler. Fehlerformat `{ "error": "..." }`. Fehlgeschlagene Bestätigungstransaktionen rollen Dateizuordnung, Auftragsstatus und Zähler gemeinsam zurück.

## Reservierung und Recovery

`POST /index.php/apps/apple_photos_connector/api/v1/uploads/prepare`

Gleiche Authentifizierung wie bei der Bestätigung. Request-Schema: `upload-prepare-request.schema.json`. Beispiel für Originalbytes `abc`:

```json
{
  "sourceId": "550e8400-e29b-41d4-a716-446655440000",
  "runId": "c8e43b70-3c5b-4dd4-9f68-38d6b11902e0",
  "uploadId": "73c6caa6-832c-44a5-a3b3-14ed9db25942",
  "bytes": 3,
  "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
}
```

HTTP 200, Schema `upload-prepare-response.schema.json`:

```json
{
  "assetId": "42",
  "path": "Photos/Apple Photos Connector/Midsommar_2015.jpg",
  "bytes": 3,
  "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  "state": "missing"
}
```

Nach tatsächlich erfolgreichem PUT mit verlorener Antwort liefert ein erneuter Aufruf `state: present`, sofern **Byteanzahl und SHA-256** stimmen. Die neue Run-/Upload-ID darf anders sein; die persistente Asset-ID verbindet den Lauf mit derselben Reservierung. Kein lokales Erfolgsjournal ist dafür erforderlich. Ein tatsächlich fehlgeschlagener PUT erhält beim Retry denselben noch fehlenden Pfad. Ein unbekannter Prüfausgang (Lesefehler, Dateisperre, DB-Fehler) bricht ab und verschiebt den Zielpfad nicht. HTTP-Fehler entsprechen der Bestätigung; bei konkurrierender erstmaliger Pfadreservierung kann ein DB-Konflikt auftreten, der Vorbereitungsvorgang darf wiederholt werden.

Die erste Reservierung überspringt sowohl vorhandene Dateien als auch Pfade anderer Asset-Reservierungen. Ein eindeutiger Index pro Benutzer/Pfad verhindert eine beabsichtigte gemeinsame Dateizuordnung unterschiedlicher Sources. Ein bereits reservierter Pfad wird erst nach bestätigtem Inhaltskonflikt weitergesetzt. Änderungen an Größe/Hash des exportierten Originals werden abgewiesen; Bearbeitungs-/Versionslogik bleibt außerhalb dieses Schritts.

## Persistenz und Grenzen

Assets speichern `nextcloud_file_id`, `nextcloud_path` und `uploaded_at`; Runs besitzen Upload- und Fehlerzähler. `apc_uploads` speichert Aufträge, `apc_upload_targets` die Asset-/Benutzer-/Source-Zuordnung, Originalname, Zielpfad, Kollisionsindex, Byteanzahl und SHA-256. Der Pfad ist unabhängig vom Inventarlauf persistent. Die Serverinstallation beginnt mit leeren Connector-Tabellen. Fehlende Assets und Dateien werden nie verändert oder gelöscht.

Der Client speichert nach erfolgreichem PUT eine lokale Bestätigungsquittung ohne Zugangsdaten unter `~/Library/Application Support/Apple Photos Connector/upload-receipts.json`. Vor weiteren Inventaren derselben Server-/Benutzerkonfiguration werden offene Bestätigungen wiederholt. Der Server ist weiterhin maßgeblich; diese Datei ist ausschließlich ein Wiederholungsjournal.

WebDAV und App-Datenbank bilden keine gemeinsame Transaktion. Eine nach verlorenem PUT-Ergebnis zunächst unzugeordnete Datei wird beim Retry über die vorher gespeicherte Reservierung geprüft und nachträglich verknüpft. Auch gleichzeitige Clients desselben Assets verwenden denselben Pfad; bedingtes PUT und erneute Vorbereitung nach HTTP 412 verhindern einen spekulativen zweiten Kollisionsnamen. Keine Bereinigung, Löschungen oder Ersetzungen.

Client und Server hashen inkrementell in 1-MiB-Blöcken. Der Server liest den Dateiinhalt unter einer gemeinsamen Nextcloud-Dateisperre, sodass laufende Schreibvorgänge nicht als Inhaltskonflikt behandelt werden. Die Prüfung vertraut weder ETags noch ungeprüften WebDAV-Checksum-Properties. Sie verursacht vollständige Datei-Lesezugriffe bei Recovery und Bestätigung; Serverlimits für Laufzeit und Dateigröße gelten weiterhin. Bei einem normalen Inventar für ausgewählte Medien prüft der Server die Existenz zugeordneter Dateien: vorhanden ergibt `known`, fehlend ergibt `new` mit Upload-Ticket. Das Original muss für eine erneute Übertragung weiterhin in Apple Fotos verfügbar sein. Eine fehlende Datei startet für sich allein keinen Import. Die Existenzprüfung prüft nicht den Inhalt bekannter Dateien. Kein Chunk-Upload; maximal 10.000 Assets pro Inventar.

APIs: [PhotoKit Originalexport](https://developer.apple.com/documentation/photos/phassetresourcemanager/writedata(for:tofile:options:completionhandler:)), [Nextcloud WebDAV](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html).


## Retargeting und Fresh-Install-Semantik

Die 0.8.0-Fresh-Install-Migration legt alle APC-Tabellen direkt an; es gibt keine historische Upgrade-Kette oder automatische Backfills. Pro Asset können mehrere Upload-Ziele als Historie existieren, aber nur `current_upload_target_id` bestimmt die aktuell verknüpfte Nextcloud-Datei.

Ein neues Ziel wird nur serverseitig für einen fehlenden oder nachweislich wiederherzustellenden aktuellen Pfad freigegeben. Der Client kann `retarget_allowed` nicht setzen. `base_target_id` bindet das Ticket an den zum Zeitpunkt der Freigabe aktuellen Zustand; konkurrierende oder veraltete Tickets werden abgewiesen. Nach erfolgreichem, byte- und hash-verifiziertem Upload wird die aktuelle Zuordnung atomar auf das neue Ziel gesetzt. Alte Ziele bleiben erhalten und werden nicht gelöscht. Album-Mitgliedschaften bleiben an Source und externer Asset-Identität erhalten; ein erneuter Album-Sync kann dadurch die aktuelle Datei referenzieren, ohne fehlende Source-Daten destruktiv zu löschen.

## Aktuelle Client-Erweiterungen

Der Client verarbeitet höchstens drei Upload-Aufträge parallel. `uploads/prepare` erhält zusätzlich `folder`: den konfigurierten Basisordner mit Jahres-/Monatsunterordner. Der Server liefert den verbindlichen vollständigen Zielpfad zurück; die oben gezeigten JSON-Pfade sind vereinfachte Beispiele. Aktive Tickets und nachweislich recoverbare vorhandene Dateien behalten ihre Reservierung. Eine historische, fehlende Reservierung aus einem abgeschlossenen oder fehlgeschlagenen Lauf darf einen abweichenden neuen Ordnerwunsch nicht dauerhaft überschreiben; in diesem Fall wird ein neues Ziel reserviert, während das alte Target als Historie erhalten bleibt.

Validierungsfehler können neben `error` ein maschinenlesbares `code` enthalten: `invalid_folder`, `content_changed`, `invalid_ticket`, `target_conflict`, `invalid_request` oder `unknown`. Die älteren JSON-Schemas bilden nicht alle aktuellen Erweiterungen ab.

Die beschriebenen Recovery-Abläufe verwenden die integrierte Zielhistorie und Retargeting-Prüfungen. Die älteren JSON-Schemas bilden nicht alle aktuellen Felder ab; maßgeblich bleiben Controller-Validierung und die Serverantwort.
