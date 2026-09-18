# Nextcloud Apple Photos Connector

[English](README.md) | Deutsch

Der aktuelle Server-App-Patch ist 0.8.6; der separate macOS-Agent **Nextcloud APC**
ist bei 0.8.3. Die App-Store-Einreichung wird vorbereitet; das
Signierungszertifikat steht noch aus. Die macOS-App
bleibt erforderlich und wird nicht über den Nextcloud App Store verteilt.
Die Server-Metadaten unterstützen NC34–35. Idempotenz und Album-Recovery wurden
manuell mit Nextcloud 35 und Photos 8.0.0 verifiziert.

## Was ist APC?

Ein sicherer, nicht-destruktiver Apple-Photos-Importer für Nextcloud mit inkrementellen Uploads, Album-Erhalt und stabilen Asset-Identitäten.

## Grundprinzipien

- Der macOS-Agent liest Apple Photos lokal über PhotoKit.
- Der Server hält die maßgebliche Import-Historie.
- Die Auswahl bestimmt das Inventory; der Server bestimmt die Übertragung.
- Stable Asset Identity statt Dateiname als Identität.
- Mehrere Sources bleiben getrennt.
- Vorhandene Nextcloud-Dateien werden nicht automatisch überschrieben.
- Fehlende Apple-Photos-Assets löschen weder Nextcloud-Dateien noch Album-Mitgliedschaften.
- Binärdaten werden über WebDAV übertragen; interne Photos-Datenbanken sind nicht erforderlich.

## Architektur

| Komponente | Zuständigkeit |
| --- | --- |
| `mac-agent/` | SwiftUI-App, PhotoKit-Auswahl, Inventory, Originalexport und WebDAV-Transport |
| `nextcloud-app/` | PHP-App, Import-Historie, Upload Targets, Tickets und Album Membership |
| `protocol/` | JSON-Schemas und gemeinsamer API-Vertrag |

Album Membership und Dateiübertragung sind getrennte Vorgänge. Albumnamen sind keine Identitäten; Source- und Asset-Identitäten bleiben über Wiederholungen hinweg stabil.

## Aktueller Stand

Der letzte gemeinsame Release ist APC 0.8.2; die Server-App liegt inzwischen als Patch 0.8.6 vor, während der Agent bei 0.8.3 steht. Die manuellen Idempotenz- und Album-Recovery-Tests waren erfolgreich:

Apple Photos → PhotoKit-Auswahl → Stable Identity → Inventory → Upload-Ticket → Originalexport → Prepare → WebDAV PUT → Complete → Datei im konfigurierten Nextcloud Target Root.

> **Zuerst die Nextcloud-Server-App installieren.** Die macOS-App kann erst
> verbunden werden, wenn `apple_photos_connector` nach `custom_apps` kopiert und
> mit `occ` aktiviert wurde. Die [Server-Installation](README.md#nextcloud-server-app--standard-installation)
> muss vor der Installation der macOS-App erfolgen.

Der zuletzt dokumentierte macOS-Teststand umfasst 134 erfolgreiche Tests; die PHP/SQLite-Suite prüft die Serverdienste. Multi-Source-Betrieb, Album-Synchronisation, Re-Inventory und Retarget-Verhalten sind lokal dokumentiert und getestet; eine breitere Betriebsvalidierung steht noch aus.

## Alben

Album-Inventar und Synchronisation sind ein eigener Schritt. Membership ist Source-bezogen und idempotent. Fehlende Quelldaten werden nicht als Löschauftrag behandelt; Ordner werden nicht als Photos-Alben angelegt.

## Voraussetzungen

- macOS 14 oder neuer
- Xcode/Swift 6 für die Entwicklung
- Nextcloud mit APC-Server-App und HTTPS
- Ein Nextcloud-App-Passwort für den Client
- Erteilter Apple-Photos-Zugriff für die macOS-App

## Installation

Das Repository enthält Client, Server-App und Protokollreferenz. Folge der [Server-Dokumentation](nextcloud-app/README.md), der [macOS-Dokumentation](mac-agent/README.md) und der [Protokolldokumentation](protocol/README.md). Für Entwicklungsprüfungen wird ein frischer Connector-Zustand verwendet; Upgrade-Pfade früherer Experimente gehören nicht zu diesem Meilenstein.

## Entwicklung

```sh
cd mac-agent
CONFIGURATION=debug bash build-app.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox
```

Die PHP/SQLite-Suite läuft mit `php nextcloud-app/tests/run.php`. Die genannten Befehle benötigen keinen laufenden Server.

## Dokumentation

- [macOS-Agent](mac-agent/README.md)
- [Nextcloud-App](nextcloud-app/README.md)
- [Protokoll](protocol/README.md)
- [Upload-Ablauf](protocol/uploads.md)

Historische Entwicklungs- und Testberichte liegen unter `docs/`; sie sind keine normative API-Dokumentation.

## Roadmap

- Breitere manuelle Prüfung mit mehreren Sources und Mediatheken
- Vollständigere Validierung der Photos-Album-Kompatibilität
- App-Store-Signierung und Einreichung abschließen
- Upstream-Abstimmung zu einer generischen Abstraktion für externe Fotoquellen

## Projektstatus

Das Projekt ist ein aktiver Entwicklungsprototyp. Die dokumentierten Schutzmechanismen und lokalen Tests gehören zum aktuellen Design; Deployment, Migration und operativer Betrieb benötigen zusätzliche Validierung.
