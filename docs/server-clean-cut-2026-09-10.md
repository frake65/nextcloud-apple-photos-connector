# APC-Serverbereinigung vom 10. September 2026

## nextcloud.example.com

Server: 192.0.2.10, SSH root, Hostname OpiZero3-sabine.
Nextcloud-Version: 34.0.4 RC1 (34.0.4.0), Nextcloud AIO.
APC-Version vorher: 0.7.4.
APC-Status vorher: enabled.
DBMS: PostgreSQL. Tabellenpräfix aus Nextcloud-Konfiguration: `oc_`.

### Gefundene und entfernte Tabellen

Jede Tabelle wurde anhand der installierten APC-Migrationen und des vorhandenen PostgreSQL-Schemas identifiziert. Keine Foreign Keys zu anderen Tabellen; keine APC-Jobs oder aktiven APC-Datenbankaktionen gefunden. Alle Drops erfolgten einzeln mit RESTRICT, ohne CASCADE, in einer erfolgreich abgeschlossenen Transaktion.

| Tabelle | Zeilen vorher | Nachher |
| --- | ---: | --- |
| oc_apc_album_memberships | 6 | entfernt |
| oc_apc_assets | 7 | entfernt |
| oc_apc_import_runs | 52 | entfernt |
| oc_apc_nextcloud_album_map | 3 | entfernt |
| oc_apc_source_albums | 4 | entfernt |
| oc_apc_sources | 3 | entfernt |
| oc_apc_upload_targets | 7 | entfernt |
| oc_apc_uploads | 42 | entfernt |

Die zugehörigen PostgreSQL-Indizes, Sequenzen und internen abhängigen Objekte wurden mit ihren Tabellen entfernt. Die abschließende Inventur fand keine APC-Relationen oder Abhängigkeiten mehr. Außer den acht genannten Tabellen wurde keine Tabelle entfernt oder angelegt.

### Appconfig, Jobs und Metadaten

APC-appconfig vorher, ausschließlich `appid = apple_photos_connector`:

- installed_version = 0.7.4
- enabled = yes (nach Deaktivierung: no)
- types = leer

APC-appconfig nachher: keine Einträge. Die drei Schlüssel wurden mit `occ config:app:delete` entfernt.

APC-Jobs vorher/nachher: keine. Es wurden keine Job-Einträge gelöscht.

APC-Migrationsstände vorher: `0001Date20260907000000`, `0002Date20260908000000`, `0003Date20260908000000`, `0004Date20260908000000`, `0005Date20260908000000`, `0006Date20260908000000`, `0007Date20260908000000`. Nachher: keine. Es wurden ausschließlich die sieben Zeilen mit `app = apple_photos_connector` aus `oc_migrations` entfernt.

Weitere Prüfung: Sämtliche gefundenen öffentlichen Tabellen mit Spalten `app`, `appid` oder `app_id` wurden auf den exakten APC-App-Identifier geprüft. Nachher keine Treffer; vorher außerhalb Appconfig und Migrationsständen ebenfalls keine. Keine APC-Präferenzen oder registrierten APC-Hintergrundjobs. Im installierten APC-Code keine AppData-/Job-Registrierung gefunden.

### App-Verzeichnis und Archive

APC-App-Verzeichnis vorher: `/var/www/html/custom_apps/apple_photos_connector`.
APC-App-Verzeichnis nachher: nicht vorhanden.

Vor der Entfernung wurden realpath, Elternverzeichnis, App-ID, Version und fehlende Symlinks geprüft. Der installierte Code von `occ app:remove`, Installer und AppManager wurde gelesen. APC hatte keine Uninstall-Schritte. `occ app:disable apple_photos_connector` und anschließend `occ app:remove apple_photos_connector` waren erfolgreich. Die App-Entfernung ließ Datenbankreste zurück; diese wurden anschließend separat inventarisiert und gezielt entfernt.

Zusätzlich entfernt: folgende sieben Archive ausschließlich alter APC-Appdateien im selben `custom_apps`-Verzeichnis. Vor jedem Entfernen wurden Dateipfad, fehlender Symlink und Archivinhalt unter dem einzigen Wurzelverzeichnis `apple_photos_connector` geprüft:

- apple_photos_connector-0.7.0-pre-0.7.1-20260908-233326.tar.gz
- apple_photos_connector-0.7.1-pre-0.7.2-20260909-104957.tar.gz
- apple_photos_connector-0.7.2-pre-0.7.3-20260909-110134.tar.gz
- apple_photos_connector-0.7.3-pre-corrected-20260909-122741.tar.gz
- apple_photos_connector-0.7.3-pre-recovery-fix-20260909-133932.tar.gz
- apple_photos_connector-0.7.3-pre-reinventory-20260909-132949.tar.gz
- apple_photos_connector-0.7.3-pre-upload-complete-20260909-133618.tar.gz

Allgemeine Nextcloud-Backups wurden nicht verändert.

### Abschlussprüfung und Sicherheitsgrenze

APC deaktiviert: JA.
APC entfernt: JA; nicht mehr in `occ app:list` enthalten.
Verbleibende APC-Artefakte in den geprüften App-/DB-Bereichen: keine.
Nextcloud über HTTPS `/status.php` erreichbar: JA.
Maintenance Mode am Ende: false; needsDbUpgrade: false.
Container-Restart: NEIN; Startzeitpunkte und Restart-Zähler aller elf Container unverändert.
Andere Apps: Versionen und Aktivierungszustände unverändert.
Allgemeine Nextcloud-Konfigurationsdateien: SHA-256 unverändert.

Benutzerdateien/Fotos: Keine Befehle zur Änderung oder Löschung von Dateien im Datadir ausgeführt. Keine aus APC-Tabellen referenzierten Dateipfade bearbeitet. Kein vollständiger Vorher-/Nachher-Hashvergleich sämtlicher Benutzerdateien durchgeführt.

Photos/Memories: Prüfsummen und Zeilenzahlen sämtlicher geprüfter Photos-/Memories-Tabellen unverändert, einschließlich 3 Photos-Alben und 6 Album-Dateizuordnungen.

Weitere geschützte Tabellen: `oc_files_metadata`, `oc_storages`, `oc_share` und `oc_users` mit unveränderten Prüfsummen und Zeilenzahlen.

**Abweichung:** `oc_filecache` hat vorher und nachher 150591 Zeilen, aber unterschiedliche Inhaltsprüfsummen. Auch die Gesamtprüfsumme der Appconfig außerhalb APC hat sich geändert. Die ausgeführten gezielten SQL-Schreiboperationen betrafen nur die acht APC-Tabellen und APC-Migrationszeilen; die Konfigurationslöschungen ausschließlich APC-Schlüssel. Nextcloud lief währenddessen weiter. Die Ursache der beobachteten Abweichungen ist mit den vorhandenen Gesamtprüfsummen nicht eindeutig zuzuordnen; eine Erklärung durch parallelen Betrieb ist nicht bewiesen. Deshalb wird für diese beiden Bereiche keine unveränderte Datenlage behauptet. Nach Feststellung der Abweichung wurden keine weiteren Serveränderungen vorgenommen.

Clean Cut vollständig: **NEIN im Sinne einer uneingeschränkt bestätigten Gesamtprüfung**. Der inventarisierte APC-Appzustand ist entfernt; die Zusicherung unveränderter fremder Daten ist wegen der zwei Prüfsummenabweichungen offen.

## cloud.dorenburg.eu

Server: laut Nutzer derzeit nicht zugreifbar; Bereinigung ausdrücklich auf später verschoben.
Nextcloud-Version, APC-Version/-Status, DBMS, Tabellenpräfix: nicht ermittelt.
Gefundene/entfernte APC-Tabellen: nicht inventarisiert / keine entfernt.
APC-appconfig vorher/nachher: nicht ermittelt.
APC-Jobs vorher/nachher: nicht ermittelt.
APC-App-Verzeichnis vorher/nachher: nicht ermittelt.
APC deaktiviert/entfernt: NEIN, nicht ausgeführt.
Benutzerdateien, Fotos, Photos/Memories, andere Apps/Tabellen: keine Zugriffe oder Änderungen ausgeführt.
Container-Restart: keiner durch diese Arbeit.
Maintenance Mode: nicht geprüft.
Verbleibende APC-Artefakte: unbekannt.
Clean Cut vollständig: NEIN, ausstehend bis Zugriff wieder möglich ist.
