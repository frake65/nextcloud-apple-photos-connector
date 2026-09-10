# APC 0.8.0 – Realintegration auf nextcloud.example.com

Datum: 10. September 2026. Zugriff über <ssh-user>@<nextcloud-host>. Kein produktiver Fotoimport.

## Umgebung und Preflight

| Prüfung | Ergebnis |
| --- | --- |
| Nextcloud | 34.0.4 RC1, intern 34.0.4.0 |
| PostgreSQL | 18.6 |
| Photos | 7.0.0, aktiviert |
| Memories | 8.1.0, aktiviert |
| APC vor Installation | nicht in App-Liste, App-Verzeichnis nicht vorhanden |
| APC-Tabellen/Appconfig/Migrationseinträge vorher | keine |
| Tabellenpräfix | oc_ |
| Aktiver App-Pfad | /var/www/html/custom_apps |
| Status vorher und nachher | installed=true, maintenance=false, needsDbUpgrade=false |

Der Statuscheck ist kein vollständiger Nextcloud-Systemaudit. Der erste psql-Aufruf mit Datenbankrolle postgres scheiterte ohne Änderungen; der konfigurierte Datenbankbenutzer oc_nextcloud wurde anschließend verwendet.

## Staging und Fresh Install

Nur nextcloud-app wurde paketiert, ohne .DS_Store, AppleDouble ._*, dist und test-build-Verzeichnisse. Die beiden lokalen .DS_Store-Dateien wurden nicht gelöscht. Das Archiv enthielt noch macOS-xattr-PAX-Header; GNU tar ignorierte diese mit Warnungen. PHP-Syntax lokal und im Container: PASS, jeweils 45 Dateien.

Staging außerhalb des aktiven Pfads: /tmp/apc-080-integration-20260910 im Nextcloud-Container. Danach Kopie nach custom_apps/apple_photos_connector, Eigentümer www-data, Installation ausschließlich über `occ app:enable apple_photos_connector`. Ergebnis: 0.8.0 enabled. Keine manuellen Tabellen- oder Schemaänderungen.

Acht Tabellen vorhanden: oc_apc_sources, oc_apc_assets, oc_apc_import_runs, oc_apc_uploads, oc_apc_upload_targets, oc_apc_source_albums, oc_apc_album_memberships, oc_apc_nextcloud_album_map.

Schema-Schlüsselprüfungen bestanden:

- current_upload_target_id: bigint, nullable.
- retarget_allowed: boolean, NOT NULL, DEFAULT false.
- base_target_id und target_id: bigint, nullable.
- Mehrere Targets je Asset real angelegt.
- apc_target_asset_idx: normaler Index auf asset_id, nicht UNIQUE.
- apc_target_path: UNIQUE(user_id,path_key), Kollision real abgewiesen.
- 23 Indizes einschließlich Primärschlüsseln, passend zur Initialmigration.
- Keine Datenbank-Foreign-Keys; auch die Initialmigration definiert keine. Eigentümer-/Source-/Asset-Prüfungen erfolgen im Repository und in Services. Diese Aussage ist keine Zusicherung einer FK-basierten referenziellen Integrität.

## PostgreSQL-Tests

Testtreiber: /tmp/apc-real-p-20260910.php und /tmp/apc-real-race-20260910.php, jeweils lokal, auf dem Host und im Nextcloud-Container. Fachliche Writes ausschließlich über APC-Repository/Services. SQL wurde nur lesend eingesetzt.

| Test | Ergebnis und tatsächlicher Umfang |
| --- | --- |
| P1 | PASS: gleiche externe Asset-Identität in zwei Sources ergibt getrennte Assets |
| P2 | PASS: Cloud-Identität bleibt bei geändertem lokalen Identifier dieselbe |
| P3 | PASS: zwei Target-Datensätze für ein Asset |
| P4 | PASS: kein impliziter Current; expliziter Verweis bestimmt genau ein Target |
| P5 | PASS: gleicher path_key wird vom PostgreSQL-Unique-Index abgewiesen; kein zusätzlicher Target-Datensatz |
| P6 | PASS: Default false im echten Schema; normaler Inventarauftrag hat keine Retarget-Freigabe. Kein separater Insert ohne dieses Feld getestet |
| P7 | PASS: Current-Wechsel über Repository; zusätzlich kompletter Servicewechsel im T-Test |
| P8 | PASS: fremder Benutzer und fremde Source werden abgewiesen |
| P9 | PASS auf Sperrebene: zwei unabhängige PHP-/DB-Verbindungen; zweiter Prozess wartet 2,687 Sekunden und sieht den Commit des ersten. Keine vollständige Wiederholung sämtlicher R13-Service-Races auf PostgreSQL |
| P10 | PASS: absichtlich abgebrochene Repository-Transaktion rollt Current-Wechsel zurück |

## Photos-Adapter und Retarget

Testtreiber: /tmp/apc-real-at-20260910.php, lokal/Host/Container. Neuer Nextcloud-Testbenutzer über IUserManager; kein Zugriff auf bestehende Benutzeralben. Controller-Testaufrufe erfolgen im Prozess mit gesetzter Testsitzung, nicht über HTTP-Authentifizierung. Binärdateien wurden über die echte Nextcloud-Files-API erzeugt, nicht per WebDAV. Prepare/Complete und Datei-Verifikation verwenden die produktiven APC-Services.

| Test | Ergebnis |
| --- | --- |
| A1 | PASS: APC erzeugt Testalbum über echten Photos-Mapper |
| A2 | PASS: Photos-Mapper erkennt Album und Eigentümer |
| A3 | PASS: erste echte Testdatei zugeordnet |
| A4 | PASS: Wiederholung meldet reused |
| A5 | PASS: zweite Datei hinzugefügt |
| A6 | PASS: gleichnamige Alben verschiedener Source-/Album-Identitäten erhalten unterschiedliche Photos-IDs |
| A7 | PASS: Asset aus Source A kann über Membership-Service nicht Album B zugeordnet werden |
| A8 | PASS: späteres Album-Inventar ohne Assets entfernt vorhandene Photos-Mitgliedschaften nicht |
| T1 | PASS: zwei selbst erzeugte PNG-Dateien per APC prepare/complete importiert |
| T2 | PASS: erste Datei im Testalbum |
| T3 | PASS: Current Target 4 festgestellt |
| T4 | PASS: ausschließlich in derselben Testausführung erzeugte Datei geprüft (Benutzer, Node-ID und Bytes), dann über Node-API gelöscht |
| T5 | PASS: Re-Inventory mit retransferMissing und neues Ziel |
| T6 | PASS: neue Datei vollständig verifiziert und bestätigt |
| T7 | PASS: Current Target wechselt von 4 auf 6 |
| T8 | PASS: nextcloud_file_id wechselt von 205293 auf 205300 |
| T9 | PASS: Target 4 bleibt unveränderte Historie |
| T10 | PASS: erneuter Membership-Serviceaufruf ordnet neue Datei zu |
| T11 | PASS im Photos-Backend: Mapper und Photos-Albummitgliedschaft zeigen Datei 205300. Browseranzeige nicht geprüft |
| T12 | PASS im ausgeführten Umfang: alle Dateimutationen auf frischen Testbenutzer beschränkt; zweite Testdatei/Zuordnung bleibt erhalten. Kein globaler Vorher-/Nachher-Dateisystemchecksum-Vergleich |

Die Retarget-Albumnachführung wurde durch expliziten erneuten Membership-Serviceaufruf getestet, nicht als vollständiger HTTP-Aufruf von /albums/sync. Photos entfernte beim regulären Löschen der alten Testdatei deren alte Albummitgliedschaft; APC führte keine direkte Photos-DB-Korrektur aus.

## Erzeugte und verbleibende Artefakte

- APC 0.8.0 ist installiert und aktiviert.
- Repository-Testnamespace (kein Nextcloud-Konto): apc-real-20260910-10a3251a; Sources ee008000-0000-4000-8000-000000000001 und ...0002; Assets 1/2; Targets 1/2; drei Import-Runs. Die Targets sind rein fachliche Testdatensätze ohne echte Dateien; der Current von Asset 1 zeigt auf Target 2.
- Neuer Nextcloud-Testbenutzer: apc-it-20260910-6a1f0b46. Zufälliges Passwort wurde nicht ausgegeben oder gespeichert. Das Konto wurde nicht entfernt; von Nextcloud erzeugte Standarddateien/-ordner können vorhanden sein.
- Sources dieses Kontos: aa008000-0000-4000-8000-000000000001 und ...0002; Assets 3/4/5; drei Import-Runs.
- Testalben: APC-IDs 1/2, Photos-IDs 4/5; beide Name „APC Integration Same Name“, Eigentümer ausschließlich Testbenutzer. Album 5 bleibt leer.
- Verbleibende eigens hochgeladene Dateien: APC-INTEGRATION/Original/two.png (fileid 205294) und APC-INTEGRATION/Retarget/one.png (fileid 205300).
- Gezielt entfernt: APC-INTEGRATION/Original/one.png (alte fileid 205293), ausschließlich T4. Nextcloud-Papierkorb-/Folgeartefakte wurden nicht bereinigt oder separat inventarisiert.
- Targets 4/5/6 bleiben erhalten; Current für Asset 3 ist 6, für Asset 4 ist 5. Asset 5 bleibt ohne Datei.
- Photos-Album 4 enthält am Ende fileids 205294 und 205300, durch lesende DB-Prüfung bestätigt.
- Host und Container: /tmp/apc-080-integration-20260910.tar.gz sowie die drei genannten PHP-Testtreiber. Zusätzlich Staging-Verzeichnis im Container und /tmp/apc-race-20260910-ready als Synchronisationsmarker.
- Lokal: gleichnamiges Paket und Testtreiber unter /tmp. Keine pauschale oder rekursive Bereinigung durchgeführt.

## Abschluss und Grenzen

SQLite-Regression einschließlich F1–F12 und R1–R18 erneut PASS; PHP-Syntax erneut PASS (45 Dateien). Keine beobachtete funktionale Abweichung SQLite/PostgreSQL in den ausgeführten Fällen. PostgreSQL verwendet echtes boolean und echte Zeilensperren; dessen vollständige Race-/Failure-Matrix ist noch nicht abgedeckt.

Keine Abweichung der geprüften Photos-7.0.0-Mapper-Signaturen oder des beobachteten Adapterverhaltens. Dies ist eine interne Photos-Schnittstelle, kein Nachweis einer stabilen öffentlichen Integrations-API.

Client verändert: NEIN. Photos-Code verändert: NEIN. Andere Apps verändert: keine Code-/Konfigurationsänderungen; normale Nextcloud-Nebenwirkungen der Testbenutzer-/Dateianlage und Photos-Testdaten wurden ausgelöst. Container-Restart: NEIN. Maintenance am Ende: false. needsDbUpgrade am Ende: false. Keine manuellen DB-Korrekturen. Kein produktiver Import.

Bereit für Mac-Agent-End-to-End-Test: JA, als kontrollierter Test mit isolierten Testdaten. HTTP-Authentifizierung, tatsächlicher Files-WebDAV-Transport, kompletter Album-Sync-Endpunkt und sichtbare Photos-Browserdarstellung sind dabei noch zu verifizieren. Keine Freigabe für produktiven Fotoimport.
