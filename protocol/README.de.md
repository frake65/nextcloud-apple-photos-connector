# Connector API v1

[English](README.md) | Deutsch

Diese Beschreibung setzt eine frische Serverinstallation mit leerem Connector-Zustand voraus. Daten und Upgrade-Pfade früherer Entwicklungsstände werden nicht übernommen.

## Album-Inventar

`POST /index.php/apps/apple_photos_connector/api/v1/albums/inventory` überträgt ein versioniertes Album-Inventar als JSON über HTTPS und HTTP Basic/App-Passwort. Die Album-Identität kombiniert Benutzer, `sourceId` und PhotoKit-`localIdentifier`; Namen sind keine technischen Schlüssel. Fehlende Alben und Memberships werden nicht gelöscht; wiederholte Inventare sind idempotent und Sources bleiben getrennt.

## Inventory und Identität

`POST /index.php/apps/apple_photos_connector/api/v1/inventory` erwartet `source` und `assets` gemäß `inventory-request.schema.json`. Der Server verwaltet die autoritative Import-Historie und antwortet mit `runId`, Zuständen und Upload-Tickets. `new` bedeutet, dass noch keine bestätigte Dateizuordnung existiert; erst nach Complete wird ein Asset `known`.

Stable Asset Identity bevorzugt den PhotoKit Cloud-Identifier. Fehlt er, wird die vorgesehene Source-/lokale Fallback-Identität verwendet. Unterschiedliche Sources werden niemals zusammengeführt. Datei- und Albumnamen sind keine Identitäten.

## Upload

Der Client sendet die Binärdaten über Nextclouds vorhandenes Files WebDAV. Prepare reserviert ein Upload Target unter dem konfigurierten Target Root und liefert den maßgeblichen Zielpfad zurück. Der Client validiert Root, Status, Identität, Größe, SHA-256 und deterministischen Dateinamen, führt den PUT aus und bestätigt anschließend mit Complete. Vorhandene Dateien werden nicht automatisch überschrieben.

Der vollständige Ablauf und Recovery-Fälle stehen in [uploads.md](uploads.md). Die JSON-Schemas in diesem Verzeichnis definieren Request- und Response-Strukturen; für die aktuelle Semantik sind zusätzlich die Implementierung und die Upload-Dokumentation maßgeblich.

## Albums

Album Membership ist von der Dateiübertragung getrennt. Nicht importierte Assets werden nicht als Membership aufgenommen. Fehlende Quelldaten führen nicht zu destruktiven Löschungen. Ordner werden nicht als Photos-Alben angelegt.

## Statuscodes und Sicherheit

Die API verwendet HTTPS, Nextcloud-Benutzer und App-Passwort sowie `Content-Type: application/json`. Anonyme und Cookie-only-Aufrufe werden abgewiesen. Requests sind benutzer- und source-isoliert; Validierungs- und Datenbankfehler dürfen keine Teiländerungen hinterlassen.

Für genaue Felder, Limits und Fehlerobjekte siehe die englische Referenz, die maschinenlesbaren Schemas und die Implementierung.
