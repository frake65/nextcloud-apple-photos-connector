# Mac-Agent-E2E gegen nextcloud.example.com

## Ergebnis

Der isolierte E2E-Test wurde vor Dateiübertragungen abgebrochen. Die App stellte sechs persistierte Auswahl-Identitäten wieder her, während die sichtbare PhotoKit-Auswahl leer war. Damit war die Voraussetzung „genau ein eigens erzeugtes Testasset“ nicht erfüllt.

Die App wurde über das aktuelle lokale Build gestartet. Ziel war `https://nextcloud.example.com`, Zielordner laut UI `Photos/zweiter`. Beim Klick auf „Hochladen“ meldete der Agent `assets=6`; der Inventory-Request erhielt HTTP 200. Der Vorgang wurde unmittelbar im Upload-Fortschrittsfenster abgebrochen, bevor ein WebDAV-PUT abgeschlossen wurde. Die sichtbaren Logs enthielten keine Passwörter, App-Passwörter, Authorization-Header oder Tokens.

Serverseitig blieb deshalb nur ein Inventory-Lauf für Benutzer `Frank`:

- Status `completed`
- 6 Assets gesehen / 6 `new` / 0 `known`
- 0 hochgeladen / 0 fehlgeschlagen
- 6 Upload-Tickets `pending`
- kein WebDAV-PUT und keine Testdatei durch diesen Lauf

Der Lauf ist als unbeabsichtigter Vorab-Inventory-Lauf dokumentiert und wurde nicht manuell verändert oder gelöscht.

## Teststatus

E1–E12, S1–S8, A1–A10, R1–R16, M1–M6 und H1–H6: **nicht als isolierter PhotoKit-E2E-Test ausgeführt**. Die vorhandene PhotoKit-Auswahl war nicht als eigens erzeugte Testauswahl verifizierbar. Der Test wurde deshalb nicht durch synthetische oder fremde Assets fortgesetzt.

Die lokalen Voraussetzungen bleiben bestätigt: Swift-Suite 45/45, Debug- und Release-Build PASS. Serverseitige PostgreSQL-/Photos-/Retarget-Integration war zuvor PASS.

## Nächster notwendiger Schritt

Vor einem neuen Lauf muss eine eindeutig isolierte Testmediathek oder ein eindeutig erzeugtes Testasset in PhotoKit bereitgestellt werden. Danach müssen die persistierten Auswahl-Identitäten geprüft und die Auswahl im Browser sichtbar bestätigt werden. Erst dann darf ein einzelnes Asset inventarisiert und übertragen werden.

Bereit für den Mac-Agent-E2E-Test: **NEIN**.
Bereit für 0.8.0 Release Candidate: **NEIN**, bis der isolierte PhotoKit-/WebDAV-Lauf erfolgreich abgeschlossen ist.
