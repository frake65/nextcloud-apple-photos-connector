# Apple Photos Connector — Nextcloud-Prototyp

App-ID: `apple_photos_connector`, Version 0.8.0 laut `appinfo/info.xml`. PHP ab 8.2; App-Metadaten deklarieren Nextcloud 30–34. Source-Registrierung, Inventarläufe und Bestätigung von Original-Uploads über Nextclouds WebDAV. Album-Inventarisierung und separater Abgleich mit Nextcloud Photos sind implementiert.

## Frische Serverinstallation

Voraussetzung ist ein vollständiger Neustart des serverseitigen Connector-Zustands: keine bisherige Connector-Installation, keine übernommenen Connector-Tabellen, Import-Historien, Upload-Reservierungen oder Album-Zuordnungen. Frühere Entwicklungsstände werden nicht migriert. Eine frische Nextcloud-Testinstanz erfüllt diese Voraussetzung. Dies beschreibt den Ausgangszustand; es ist keine Anleitung zum Löschen vorhandener Nextcloud-Dateien.

Den Inhalt dieses Verzeichnisses unter `<nextcloud>/custom_apps/apple_photos_connector/` ablegen (der installierte Ordner muss der App-ID entsprechen), anschließend als Nextcloud-Webserverbenutzer ausführen:

```sh
php occ app:enable apple_photos_connector
php occ app:list
```

Bei der Installation legt Nextcloud die Connector-Tabellen und Indizes mit dem konfigurierten Tabellenpräfix an. Source-Registrierung, Inventar, Uploads und Album-Zuordnungen beginnen leer. Die App benötigt keine Composer-Pakete im Produktivbetrieb; Nextcloud übernimmt das Autoloading des Namespace `OCA\ApplePhotosConnector`.

## Endpunkte

`new` bedeutet „ohne bestätigten Upload“. Das Inventar liefert dafür Upload-Aufträge; bestätigte Dateien werden als `known` erkannt. Den aktuellen Client mit der frisch installierten Server-App verwenden. Details: [Upload-Protokoll](../protocol/uploads.md).

`POST /index.php/apps/apple_photos_connector/api/v1/inventory`

Request, Antwort, Authentifizierung, Run-Lebenszyklus und Identitätsregeln stehen in [protocol/README.md](../protocol/README.md); dort liegen die JSON-Schemas für Request, Erfolg und Controller-Fehler. Zum manuellen Test einen Request als `inventory.json` speichern:

```sh
curl --user 'NEXTCLOUD_USER' \
  --header 'Content-Type: application/json' \
  --data-binary @inventory.json \
  'https://cloud.example/index.php/apps/apple_photos_connector/api/v1/inventory'
```

Curl fragt das App-Passwort interaktiv ab. Sources und Assets werden durch den authentifizierten Benutzer isoliert. Der Source-Name kann bei weiteren Läufen aktualisiert werden; die Source-UUID bleibt die logische Identität.

## Aufbau

- `lib/Migration`: persistente Tabellen und Indizes; Source-UUID pro Benutzer eindeutig.
- `lib/Db/InventoryRepository`: Nextcloud-QueryBuilder und Transaktionen.
- `lib/Service/AssetIdentity`: bevorzugte Cloud-Identität und vorläufiger lokaler Fallback.
- `lib/Db/ImportRun`: zufällige Run-UUID und initialer Audit-Datensatz.
- `lib/Service/InventoryValidator`: Validierung vor Source-/Asset-Änderungen.
- `lib/Service/InventoryService`: Registrierung, `new`/`known`-Verarbeitung und transaktionaler Run-Abschluss.
- `lib/Controller`: authentifizierter JSON-Endpoint.
- `lib/Service/UploadService`: benutzergebundene Upload-Bestätigung und atomare Zähler.
- `lib/Service/UploadedFileLocator`: tatsächliche Datei-ID aus dem Benutzerdateisystem.

Für den Prototyp wird das bestehende Inventar einer Source einmal pro Lauf gelesen und im Speicher indiziert. SHA-256 dient ausschließlich der Verifikation reservierter Uploads, nicht der Deduplizierung. Keine Vergleiche zwischen Sources und keine automatischen Löschungen. Große Sources benötigen entsprechend Speicher; eine spätere indexierte Identitätssuche kann im Repository ergänzt werden.

Upload-Recovery verwendet dauerhaft gespeicherte Ziele. `POST /api/v1/uploads/prepare` reserviert bzw. prüft den Zielpfad anhand Byteanzahl und SHA-256. Derselbe Asset-Datensatz behält seinen Pfad über Runs und Client-Neustarts. Bestehende fremde Dateien werden übersprungen; unklare Prüfergebnisse führen zum Abbruch statt zu einem weiteren Dateinamen. Die Bestätigung prüft die tatsächlichen Bytes erneut. Details und Schemas im [Upload-Protokoll](../protocol/uploads.md).

## Tests und statische Prüfungen

Ohne Nextcloud, mit PHP 8.2+ und PDO SQLite:

```sh
php tests/lint.php
php tests/run.php
```

Alternativ `composer lint` und `composer test`. Die Tests führen die echte Migration, das Repository und die Services gegen eine SQLite-In-Memory-Datenbank aus. `SQLiteHarness.php` bildet dafür nur die verwendete OCP-Schnittstelle nach. Dies prüft das Verhalten, ersetzt aber keinen Nextcloud-Integrationslauf und keinen Test der Datenbank-Sperren unter MySQL/PostgreSQL.

In einer separaten, installierten Nextcloud-Testinstanz mit aktivierter App:

```sh
NEXTCLOUD_ROOT=/path/to/nextcloud APC_TEST_DATABASE=disposable php tests/nextcloud.php
```

Dieser Lauf verwendet Nextclouds echten QueryBuilder und dieselben Inventarszenarien. Er erzeugt zufällig benannte Testbenutzer-Namespaces in den App-Tabellen; die Zeilen bleiben absichtlich in der wegwerfbaren Testdatenbank. Keine produktive Instanz verwenden.

Run-Tests prüfen neue, bekannte und leere Inventare, separate Runs, Benutzertrennung sowie Rollback bei Fehlern während des Abschlusses. Weitere Fehlerproben decken fehlgeschlagene Run-Anlage, ausgefallene Fehlerprotokollierung und verlorene Commit-Bestätigung ab. Die dabei absichtlich ausgelöste Meldung `failed to finalize import run` ist erwartete Testausgabe.

Upload-Tests prüfen Aufträge, Retry nach Fehler, idempotente Bestätigung, Benutzer-/Pfadgrenzen und erhaltene Dateien bei leeren Folgescans. Der Datei-Locator ist dabei ein Testdouble; echte WebDAV-/Nextcloud-Dateisystemintegration ist nicht Teil dieses lokalen Tests. Die Identitätstests verwenden zwischen Scans bestätigte Dateireferenzen als Fixtures, damit sie weiterhin die unveränderte Apple-Identitätslogik prüfen.

Am 10. September 2026 bestanden die lokale PHP-Syntaxprüfung (45 Dateien) und alle eigenständigen SQLite-Szenarien einschließlich der vollständigen Fresh-Install-Migration. Eine echte Nextcloud-Integration wurde dabei nicht ausgeführt. Die deklarierte Nextcloud-Spanne ist keine getestete Versionsmatrix; insbesondere sind MySQL/PostgreSQL-Sperrverhalten und die Photos-Adapter-Integration separat zu prüfen.


## API und Alben

Alle Pfade liegen unter `/index.php/apps/apple_photos_connector/api/v1` und erfordern HTTP Basic Authentication mit Nextcloud-Benutzer und App-Passwort. POST-Aufrufe als JSON senden.

| Methode | Pfad | Aufgabe |
| --- | --- | --- |
| GET | `/status` | Verbindung und Anmeldung prüfen |
| POST | `/inventory` | Source und Assets inventarisieren, Upload-Aufträge erhalten |
| POST | `/uploads/prepare` | Ziel reservieren und vorhandenen Inhalt prüfen |
| POST | `/uploads/complete` | Upload bestätigen oder Fehler melden |
| POST | `/albums/inventory` | Album-Metadaten und Mitgliedschaften speichern |
| POST | `/albums/sync` | Gespeicherte Alben mit Nextcloud Photos abgleichen |

Die Source muss vor dem Album-Inventar registriert sein. Der Abgleich nutzt die Photos-Mapper über `NextcloudAlbumAdapter`. Dieser akzeptiert derzeit genau Photos 7.0.0 und prüft die benötigten Mapper-Methoden; andere Versionen werden abgewiesen. Ordner werden übersprungen. Mitgliedschaften werden nur für importierte Assets ergänzt. Namen sind keine Schlüssel. Details und Antwortfelder stehen im [Protokoll](../protocol/README.md).

## Aktuelles Datenmodell und Fresh-Install-Grenze

Die App 0.8.0 startet mit einer einzigen vollständigen Fresh-Install-Migration. Historische APC-Migrationen und Backfills gehören bewusst nicht zum Clean-Cut-Schema; eine bestehende APC-Installation wird deshalb nicht automatisch umgebaut.

Das Datenmodell umfasst Sources, Assets, Import-Runs, Upload-Aufträge, mehrere historisierte Upload-Ziele pro Asset, Album-Inventar, Mitgliedschaften und Photos-Zuordnungen. `current_upload_target_id` ist die alleinige aktuelle Dateizuordnung. Ein Retargeting darf nur bei serverseitig erlaubtem Wiederherstellungsfall erfolgen; das alte Ziel bleibt als Historie erhalten. `retarget_allowed` und `base_target_id` werden ausschließlich aus dem Serverzustand gesetzt, nicht aus Clientdaten.
