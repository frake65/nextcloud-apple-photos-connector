# mac-agent — 0.8.3

Lokaler SwiftUI-Prototyp für macOS 14.0 oder neuer. Benötigt Swift 6 (Xcode bzw. Xcode Command Line Tools), keine externen Abhängigkeiten.

## Build und Start

Im Verzeichnis `mac-agent/`:

```sh
bash build-app.sh
open ".build/Nextcloud APC.app"
```

Das Skript baut standardmäßig einen Universal-Release für arm64 und x86_64 und signiert das lokale Bundle ad-hoc, ohne Notarisierung. `CONFIGURATION=debug bash build-app.sh` erstellt einen Debug-Build. Achtung: Im Release-Zweig kann das Skript nach einem fehlgeschlagenen Build auf vorhandene ausführbare Dateien zurückfallen; für einen frischen Build deshalb auch die Build-Ausgabe prüfen. Bitte das App-Bundle starten, nicht `swift run`: Es enthält die für den Fotozugriff erforderliche `NSPhotoLibraryUsageDescription`.

Für einen Developer-ID-Release muss das finale Bundle-Signieren ebenfalls über `build-app.sh` laufen, damit das Photos-Entitlement aus `Resources/MacAgent.entitlements` zusammen mit der Hardened Runtime signiert wird:

```sh
APC_SIGNING_IDENTITY="Developer ID Application: Example Name (TEAMID)" bash build-app.sh
codesign --verify --deep --strict ".build/Nextcloud APC.app"
codesign -d --entitlements :- ".build/Nextcloud APC.app"
```

`APC_SIGNING_IDENTITY` ist durch den tatsächlich installierten Developer-ID-Identitätsnamen zu ersetzen. Ohne diese Variable bleibt das lokale Ad-hoc-Signieren der Standard. Ein nachfolgendes `codesign --force` ohne `--entitlements Resources/MacAgent.entitlements` ersetzt die Codesignatur und kann das Photos-Entitlement entfernen; daher muss die Entitlement-Datei beim letzten Signierschritt angegeben werden. Der Agent verwendet im Quellcode keine AppleScript- oder expliziten Apple-Events-APIs; `com.apple.security.automation.apple-events` wird deshalb nicht angefordert.

In der App **Zugriff anfordern & inventarisieren** wählen und den macOS-Fotodialog bestätigen. Bei verweigertem Zugriff die Freigabe unter **Systemeinstellungen → Datenschutz & Sicherheit → Fotos** ändern und erneut scannen. PhotoKit verwendet hierfür die Zugriffsstufe `readWrite`; der Prototyp führt ausschließlich Leseoperationen aus.

Das Textfeld zeigt das vollständige JSON-Dokument mit `source` und `assets` zum Markieren und Kopieren. Ein erneuter Scan ersetzt das Inventar. Die Source-Konfiguration wird lokal gespeichert; das Asset-Inventar wird weder automatisch gespeichert noch übertragen.

Die Oberfläche zeigt zusätzlich die Anzahl aller Assets, mit und ohne Cloud-Identifier sowie Bilder und Videos. Audio- und unbekannte Medientypen zählen zur Gesamtzahl. Zusammenfassung und Fehler werden nicht in das JSON-Dokument gemischt.

## Lokale Source

Beim ersten Scan wird `~/Library/Application Support/Apple Photos Connector/source.json` angelegt. Sie enthält `sourceId` (zufällige `UUID()`), `name` (anfangs `Apple Photos`) und `createdAt` (ISO-8601 in UTC). Die UUID ist eine logische Connector-Identität und wird aus keinerlei Mediathek-, Asset-, Datei- oder Hardwaremerkmalen abgeleitet.

Weitere Scans und Programmstarts laden diese Konfiguration unverändert. Gleichzeitige Zugriffe werden über eine lokale Lock-Datei koordiniert, Schreibvorgänge erfolgen atomar. Beschädigte oder unlesbare Konfigurationen führen zum Scanfehler, nicht zur stillen Vergabe einer neuen UUID. Die Konfiguration ist dauerhaft aufzubewahren: Wird sie entfernt, erzeugt der nächste Scan eine neue logische Source.

Das JSON-Scanformat lautet:

```json
{
  "source": {
    "sourceId": "550E8400-E29B-41D4-A716-446655440000",
    "name": "Apple Photos"
  },
  "assets": []
}
```

`createdAt` gehört zur lokalen Konfiguration und wird im Source-Block des Scans nicht ausgegeben. Ein Wechsel der Photos-Mediathek ändert die Source nicht automatisch. Eine automatische Zuordnung mehrerer Macs oder Mediatheken und eine Oberfläche zum Teilen/Verwalten von Sources sind noch nicht implementiert.

## Daten und Grenzen

- `localIdentifier`: unverändert aus PhotoKit, nur lokale Identität.
- `cloudIdentifier`: persistierbarer, opaker PhotoKit-String, andernfalls explizit `null`. `CloudIdentifierCodec` verwendet unter macOS 14–15.1 `stringValue` / `init(stringValue:)`, ab 15.2 `archivalStringValue` / `init(archivalStringValue:)`. Beide API-Generationen verwenden kompatible Strings. Der Build benötigt ein SDK ab macOS 15.2; das Deployment Target bleibt 14.0.
- `mediaType`: `image`, `video`, `audio` oder `unknown`.
- `creationDate`: ISO-8601 in UTC, bei fehlendem Datum `null`.
- `filename`: ursprüngliche primäre Foto-, Video- oder Audioressource; falls nicht verfügbar `null`. Bei Live Photos wird die Fotoressource gewählt, bei mehreren Originalressourcen die erste passende. Dateinamen sind keine Identifier.

Der Scanner fragt alle über PhotoKit zugänglichen PHAssets ab, einschließlich ausgeblendeter Assets und aller Serienbild-Assets. Systemseitig nicht zugängliche Assets sind nicht enthalten; eingeschränkte Freigaben werden in der Oberfläche angezeigt. Der reine Inventarscan lädt keine Bild- oder Videodaten herunter. Das Inventar wird im Speicher gesammelt und nach lokalem Identifier sortiert; sehr große Mediatheken können entsprechend viel Speicher und Zeit für die JSON-Anzeige benötigen.

`Sources/InventoryCore` enthält Datenmodell, JSON-Ausgabe, inkrementelles SHA-256 und testbaren WebDAV-Transport; `Sources/MacAgent` Oberfläche, Scanner, Originalexport und Upload-Koordination. SHA-256 dient ausschließlich der Upload-Verifikation. Album-Inventarisierung und separater Album-Abgleich sind vorhanden. Keine automatische Delta-Erkennung, Bearbeitungsübertragung oder Hash-Deduplizierung.

## Entwicklungs-Upload

Der aktuelle Server-Quellstand deklariert Version 0.8.6; der separate macOS-Agent ist Version 0.8.3. Vorausgesetzt wird eine frische Serverinstallation mit leerem Connector-Zustand gemäß [Server-Anleitung](../nextcloud-app/README.md). Die Verbindung verwendet eine HTTPS-Nextcloud-Basisadresse (gegebenenfalls mit Installations-Unterpfad), Benutzer und App-Passwort. Anmeldung über Nextcloud Login Flow v2 und das Speichern des App-Passworts im macOS-Schlüsselbund sind implementiert. Der Schlüsselbunddienst heißt `ApplePhotosConnector.Nextcloud`; der aktuelle Kontoschlüssel ist der Benutzername. Danach den Original-Upload starten. Der reine Inventarbutton überträgt weiterhin nichts.

Nur serverseitig als `new` angeforderte Assets werden exportiert. `new` bleibt bis zur bestätigten Dateizuordnung bestehen, sodass fehlgeschlagene Uploads erneut angefordert werden. PhotoKit exportiert die primäre Originalressource in ein temporäres Verzeichnis und darf dafür iCloud-Daten herunterladen. Nach dem Versuch werden ausschließlich diese lokalen temporären Exportdaten entfernt.

Ziel ist `Photos/Apple Photos Connector/YYYY/MM/` im Nextcloud-Konto. Der Basisordner ist in `UploadConfiguration.json` unter `~/Library/Application Support/Apple Photos Connector/` dauerhaft konfigurierbar und verwendet standardmäßig `Photos/Apple Photos Connector`. Originalnamen bleiben bei freiem Ziel erhalten. Bedingte WebDAV-PUTs und deterministische Suffixe schützen vorhandene Dateien vor Überschreiben. Erfolgreiche Uploads werden beim Connector bestätigt; offene Bestätigungen liegen ohne Passwort im lokalen `upload-receipts.json` neben `source.json` und werden vor dem nächsten Inventar wiederholt. Vollständiger Ablauf, JSON und Fehlergrenzen: [Upload-Protokoll](../protocol/uploads.md).

Vor jedem PUT reserviert bzw. prüft der Connector-Server einen dauerhaft dem Asset zugeordneten Pfad. Bereits vorhandene erwartete Inhalte werden über Größe und SHA-256 verifiziert und ohne weiteren Upload bestätigt. Die Reservierung überlebt neue Inventarläufe und Client-Neustarts, auch ohne lokales Erfolgsjournal. Unklare PUT-/Prüfantworten führen niemals eigenständig zum nächsten Dateinamen. Der Prototyp verarbeitet höchstens 10.000 Assets pro Inventar und verarbeitet bis zu drei Upload-Aufträge parallel, ohne Chunking. Live-Photo-Begleitvideos und zusätzliche Originalvarianten werden nicht exportiert.

Die Cloud-Zuordnung verwendet ausschließlich `cloudIdentifierMappings(forLocalIdentifiers:)`, gebündelt in Blöcken von maximal 500 Assets auf dem Scanner-Actor. Jedes fehlgeschlagene oder fehlende Mapping lässt das Asset mit `cloudIdentifier: null` im Inventar; der Scan läuft weiter. Fehler werden über `OSLog` separat protokolliert (Subsystem `de.applephotosconnector.macagent`, Kategorie `CloudIdentifier`). Asset-Identifier und Fehlertexte sind als privat markiert. Anzeige z. B. mit:

```sh
log stream --predicate 'subsystem == "de.applephotosconnector.macagent" AND category == "CloudIdentifier"' --level error
```

Ein Cloud-Identifier allein beweist nicht, dass ein Asset bereits zu iCloud hochgeladen ist; PhotoKit kann solche Identifier auch für nicht synchronisierte Mediatheken liefern. Es wird kein Uploadstatus geprüft. Siehe Apples [PHCloudIdentifier-Dokumentation](https://developer.apple.com/documentation/photos/phcloudidentifier).

Die Dateinamen stammen aus Apples dokumentierter [PHAssetResource.originalFilename-API](https://developer.apple.com/documentation/photos/phassetresource/originalfilename).

## Tests

Reproduzierbarer JSON-Smoke-Test ohne XCTest:

```sh
bash smoke-test.sh
codesign --verify --deep --strict ".build/Nextcloud APC.app"
```

Der Smoke-Test prüft den Source-Block und die fünf Asset-JSON-Felder inklusive archiviertem Cloud-Identifier, `null` bei fehlenden Werten, Sonderzeichen, Datum und leere Inventare sowie die Zusammenfassung bei gemischten Medientypen. Zusätzlich prüft er den Codec mit fehlenden und leeren Eingaben. Beide Versionszweige werden für Deployment Target 14.0 kompiliert; ein Lauf auf einem einzelnen Betriebssystem deckt nur dessen API-Zweig ab. Seine synthetischen Cloud-Strings testen die verlustfreie Ausgabe, nicht die PhotoKit-Auflösung.

Der Source-Smoke-Test startet zwei getrennte Prozesse mit derselben isolierten Testkonfiguration unter `.build/` und vergleicht die Scan-Ausgaben sowie die persistierte Konfiguration inklusive `createdAt`. Er prüft außerdem unterschiedliche UUIDs für unabhängige Konfigurationen und die unveränderte Beibehaltung beschädigter Dateien nach einem Fehler. Die echte Source-Konfiguration wird dabei nicht angefasst.

Der Upload-Smoke-Test verwendet den echten WebDAV-Uploader mit einem isolierten, dateibasiert persistenten Servermodell: gleich große fremde Dateien, belegte Suffixe, bedingte PUTs, SHA-256-Testvektor, URL-Kodierung, fehlgeschlagener Upload und irreführende HTTP-Antwort. Zwei getrennte Prozesse simulieren erfolgreichen PUT mit verlorener Antwort und Neustart: Der zweite Prozess muss dieselbe Datei erkennen und der PUT-Zähler muss bei 1 bleiben. Keine Netzwerkverbindung und kein Zugriff auf echte Fotodateien. PhotoKit-Export und ein vollständiger WebDAV-Lauf benötigen zusätzlich eine manuelle Testmediathek und Testinstanz.

Für die XCTest-Tests wird eine Toolchain mit importierbarem XCTest benötigt. Falls `swift test` mit `no such module 'XCTest'` scheitert, die aktive Xcode-/Toolchain-Auswahl prüfen. Die Verfügbarkeit wurde bei dieser Dokumentationspflege nicht neu getestet.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox
```

Die Tests prüfen JSON-Felder, Sonderzeichen, Datum, fehlende Metadaten und ein leeres Inventar ohne Zugriff auf private Fotos. Manuell zu prüfen: Erstfreigabe, Ablehnung, erneuter Scan sowie Vergleich mit bekannten Fotos/Videos in der eigenen Mediathek, Cloud-Zuordnung mit iCloud Photos sowie fehlende Zuordnungen und deren Fehlerprotokoll. Ein automatisierter Zugriffstest auf eine echte Mediathek ist nicht enthalten.

## Verbindung zum frisch eingerichteten Server

Der Server beginnt ohne frühere Import-Historie. Ein vorhandenes lokales `upload-receipts.json` gehört zum vorherigen Serverzustand und darf für denselben neu eingerichteten Server nicht weiterverwendet werden: Der Client versucht sonst vor dem Inventar, alte Aufträge zu bestätigen. Für den Neustart eine frische Client-Konfiguration verwenden oder das bisherige Quittungsjournal bei beendeter App separat archivieren. Ein neues Inventar registriert die Source und Assets erneut.

Bereits vorhandene Nextcloud-Dateien werden ohne serverseitige Reservierung nicht als frühere Imports übernommen, auch bei identischen Bytes. Sie bleiben erhalten; neue Uploads können Kollisionsnamen erhalten.

## Importumfang und Alben

Als Importumfang stehen die ganze Mediathek und ausgewählte Alben zur Verfügung. Die Auswahl wird pro Source gespeichert; Cloud-Identifier bzw. lokale Identifier halten sie unabhängig vom Albumnamen. Ordner sind keine auswählbaren Fotoalben.

Foto-/Video-Upload und Album-Abgleich sind separate Vorgänge. Der Album-Scan sendet Collections und Mitgliedschaften; der anschließende Abgleich erstellt oder verwendet Nextcloud-Photos-Alben. Ordner werden übersprungen, noch nicht importierte Dateien werden nicht als Mitglied aufgenommen. Fehlende Alben und Mitgliedschaften führen zu keiner Löschung. Der Adapter unterstützt aktuell genau Photos-Version 7.0.0 mit den erwarteten AlbumMapper-Methoden; siehe Server-Code und Server-Dokumentation.

Bei einem normalen Importlauf prüft der Server für die ausgewählten Medien, ob die zugeordnete Nextcloud-Datei vorhanden ist: vorhanden bedeutet `known`, fehlend bedeutet `new` mit Upload-Ticket. Die erneute Übertragung setzt ein weiterhin verfügbares Original in Apple Fotos voraus. Allein das Fehlen einer Datei startet keinen Import. Die frühere Einstellung wurde entfernt; alte gespeicherte Preference-Werte werden ignoriert. Es findet keine allgemeine Inhaltsprüfung aller bereits importierten Dateien statt.

Die Oberfläche ist für Deutsch, Englisch, Französisch, Portugiesisch, Niederländisch und Spanisch lokalisiert; Englisch ist Fallback. Tests unter `Tests/InventoryCoreTests` behandeln unter anderem JSON, Login, Zugangsdaten, Importumfang, Fortschritt, Parallelität und Logging.
