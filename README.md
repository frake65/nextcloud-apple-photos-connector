# Apple Photos Connector

Überträgt Originalfotos und -videos aus Apple Fotos nach Nextcloud und gleicht Alben in einem separaten Vorgang ab. Der Server verwaltet die maßgebliche Import-Historie. Dateien werden nicht automatisch gelöscht; fehlende Quelldaten entfernen keine Album-Mitgliedschaften.

## Projektaufbau

| Verzeichnis | Inhalt | Einstieg |
| --- | --- | --- |
| `mac-agent/` | SwiftUI-App, PhotoKit-Scan, Originalexport und WebDAV-Upload | [Client-Dokumentation](mac-agent/README.md) |
| `nextcloud-app/` | PHP-App, Inventar, Upload-Ziele und Album-Abgleich | [Server-Dokumentation](nextcloud-app/README.md) |
| `protocol/` | API-Beschreibung und JSON-Schemas | [Protokoll](protocol/README.md) |

Stand des Quellcodes am 10. September 2026: Client-Bundle-Version 0.7.4, Server-App-Metadaten 0.8.0, API v1. Diese Angaben stammen aus den Quelldateien und bestätigen nicht den Versionsstand vorhandener Binärdateien.

## Ausgangszustand

Für den aktuellen Stand wird die Server-App vollständig frisch eingerichtet: Connector-Tabellen, Import-Historie, Reservierungen und Album-Zuordnungen beginnen leer. Upgrade-Pfade und Datenübernahmen aus früheren Entwicklungsständen sind nicht Bestandteil der Dokumentation. Siehe [Serverinstallation](nextcloud-app/README.md) und [Client-Neustart](mac-agent/README.md#verbindung-zum-frisch-eingerichteten-server).

## Ablauf

1. Die macOS-App mit Nextcloud verbinden und Zugriff auf Apple Fotos erteilen.
2. Die gesamte Mediathek oder ausgewählte Alben als Importumfang festlegen.
3. Inventar senden; der Server fordert benötigte Originale an.
4. Upload-Ziel reservieren, Original bedingt per WebDAV übertragen und bestätigen. Wiederholungen verwenden gespeicherte Reservierungen und lokale Bestätigungsquittungen.
5. Alben separat inventarisieren und abgleichen. Nur bereits importierte Dateien können in Nextcloud-Alben aufgenommen werden.

Cloud-Identifier haben Vorrang vor lokalen Identitäten. Datei- und Albumnamen sind keine Identifikatoren. Unterschiedliche Benutzer und Sources werden getrennt behandelt.

## Entwicklung und Artefakte

Die [Projektregeln](AGENTS.md) gelten für alle Module. `ChatGPT.md` enthält einen früheren UI-Arbeitsauftrag, keine aktuelle Funktionsreferenz.

`mac-agent/dist/` enthält vorhandene Release-Artefakte. `mac-agent/.build/` und `.build/` sind lokale Build-/Cache-Verzeichnisse. Alte experimentelle `mac-agent/dist-test*`-Bundles wurden bei der Dokumentationspflege entfernt; Quellcode, Tests und Release-Artefakte bleiben erhalten.

PHP-Syntaxprüfung und eigenständige SQLite-Tests liefen am 10. September 2026 erfolgreich. Das ist kein Nachweis für eine echte Nextcloud-Installation; die vollständige aktuelle Schema-Initialisierung ist lokal nicht abgedeckt. Swift- und Integrationstests wurden bei dieser Dokumentationspflege nicht ausgeführt.
