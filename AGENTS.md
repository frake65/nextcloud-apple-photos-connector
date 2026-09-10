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

## Documentation

- English is the technical reference language.
- Public documentation is maintained in English and German where a language pair exists.
- When changing one member of a bilingual documentation pair, review and update the corresponding language version in the same change when necessary.
- Headings and document structure of language pairs should remain aligned where practical.
- Protocol identifiers and code-level terminology must not be translated inconsistently.
