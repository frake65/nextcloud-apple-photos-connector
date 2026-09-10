# Apple Photos Connector

## Architektur

Das Projekt besteht aus:
- macOS Agent in Swift
- Nextcloud App in PHP
- gemeinsamem JSON-Protokoll

## Grundregeln

- Nie automatisch Dateien in Nextcloud löschen.
- Nie Album-Mitgliedschaften aufgrund fehlender Source-Daten entfernen.
- Albumnamen sind keine Identifier.
- Dateinamen sind keine Identifier.
- PHCloudIdentifier hat Vorrang vor lokalen Identitäten.
- Der Server hält die authoritative Import-History.
- Der Client darf einen lokalen Cache verwenden, aber er ist nicht authoritative.

## Entwicklung

- Kleine Commits.
- Neue Sync-Logik benötigt Tests.
- Datenbankmigrationen müssen rückwärts sicher sein.
- Keine Änderungen außerhalb des angeforderten Moduls ohne Begründung.
