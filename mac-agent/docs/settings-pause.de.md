# Settings-Pause

## Lifecycle und ausstehende Arbeit

`SettingsWorkGate.shared` ist die zentrale Start-Sperre im Arbeitsspeicher für
Mediatheksarbeit. `SettingsWindowLifecycle` bindet sie an das einzelne
SwiftUI-Einstellungsfenster: Öffnen pausiert; `NSWindow.willCloseNotification`
gibt Arbeit frei. `didBecomeKeyNotification` erfasst auch das erneute Öffnen eines
beibehaltenen Fensters. Fokusverlust, Sheets, Minimieren oder Ausblenden der App
heben die Pause nicht auf. Bei unvollständiger Konfiguration wird die Pause vor
dem angeforderten Öffnen aktiviert. Das bisher aufgeschobene initiale Laden der
Galerie bleibt damit erhalten.

`CoalescingWorkRequest` verwaltet den Galerie-Task und genau ein Pending-Flag.
Anfragen während der Pause werden zu einem Reload zusammengefasst. Anfragen
während eines aktiven Reloads erzeugen höchstens einen Folge-Reload. Schließen
ohne ausstehende Arbeit erzeugt keinen Reload. Wartende Tasks prüfen nach dem
Aufwecken erneut den aktuellen Zustand; Schließen/Öffnen erteilt keine veraltete
Freigabe. Die bestehenden UI-Sperren für Scans und Albumläufe bleiben erhalten.
`UploadCoordinator` weist zusätzlich parallele `run`-Aufrufe zurück, auch wenn
der erste Aufruf noch auf das Schließen der Einstellungen wartet.

Verbindungsprüfung, Login-Flow und Verzeichnisauswahl bleiben verfügbar.
Im aktuellen Agenten gibt es keinen periodischen Import-Timer.

## Operationsgrenzen und Queue

Checkpoints schützen Galerie-Laden, Foto- und Albuminventarisierung,
Albuminventar-Übermittlung/Sync, Upload-Laufstart, Inventar-Requests, neue Exporte
und neue WebDAV-Upload-Schritte. Weil die Foto-Freigabe asynchron warten kann,
prüfen Scans danach erneut. Auch Thumbnail-Requests warten. Identitätsmappings
werden pro Inventar zwischengespeichert, damit Darstellung und Auswahl keine
neuen PhotoKit-Abfragen auslösen.

Eine zugelassene Operation darf enden; das Öffnen bricht sie niemals ab.
Ein synchroner Inventarisierungsabschnitt darf fertiglaufen. Ein laufender
Export darf enden, sein anschließender WebDAV-Upload wartet jedoch. Ein bereits
zugelassener WebDAV-Upload-Schritt einschließlich Verzeichnisvorbereitung und
PUT sowie seine Abschlussbestätigung dürfen enden. Receipts und fertige
Ergebnisse werden auch während der Pause verarbeitet. Die Queue startet keine
Ersatzjobs, behält ihren nächsten Index und füllt nach Freigabe auf höchstens
drei aktive Jobs auf. Maßgeblich ist die Startfreigabe: Die Pause entzieht einem
auf einem anderen Actor bereits zugelassenen Schritt nicht nachträglich die
Freigabe. Wartende Tasks können ohne Schließen der Einstellungen abgebrochen werden.

Ausstehende Arbeit gilt nur innerhalb des Prozesses; dies ist kein persistenter
Job-Scheduler.

## Konfigurations-Snapshot

Die UI erfasst Verbindung, Zielwurzel und `retransferMissing` nach der Freigabe
und vor dem Scan. Der Snapshot der Fotoauswahl bleibt bis zur Inventarfilterung
erhalten. Alle Upload-Jobs erhalten dieselbe Zielwurzel und Verbindung. Werden
Ziel/Retry vom Aufrufer nicht übergeben, liest der Koordinator die Standardwerte
nur einmal. Spätere Einstellungsänderungen gelten erst für einen späteren Lauf.
Zugangsdaten werden weder zusätzlich gespeichert noch zusätzlich protokolliert.

## MainActor-Einschränkung

Galerie-Aufzählung und initiale Cloud-Identitätsmappings laufen weiterhin auf dem
MainActor. Der Cache vermeidet wiederholte PhotoKit-Mappings beim Darstellen,
verschiebt die initiale Inventarisierung aber nicht vom UI-Actor. Ein vor dem
Öffnen begonnener synchroner Abschnitt kann die Fensterdarstellung daher bis zu
seinem Ende verzögern. Sobald der Fenster-Lifecycle die Pause aktiviert, wird
kein neuer geschützter Schritt zugelassen. Die Verlagerung auf einen
Hintergrund-Actor mit klar übertragbarem Ergebnis bleibt eine separate
Concurrency-Aufgabe; diese Änderung führt keine ungeprüften Transfers von
PhotoKit-Objekten ein.

## Tests und manuelle Prüfung

`SettingsWorkGateTests` prüfen Startfreigabe, pausierte/zusammengefasste Trigger,
sofortiges Schließen/Öffnen, einen Folgelauf nach aktiver Arbeit und Abbruch.
`SettingsUploadPauseTests` prüfen den produktiven Koordinator mit Fake-Exporter
und Fake-Transport: Pause/Abarbeitung/Resume, die Grenze von drei Jobs,
Ablehnung paralleler Läufe, Abbruch und konstante Konfiguration über Queue-Jobs
sowie spätere Läufe. Die Tests benötigen weder Foto-Freigabe noch echten Server.

`swift test --disable-sandbox` in `mac-agent` ausführen; bei entsprechenden
Sandbox-Einschränkungen einen beschreibbaren Scratch-Pfad und
`CLANG_MODULE_CACHE_PATH` verwenden. Die bisherige Baseline hatte 60 Tests und
drei Assertion-Fehler in H4/H6h; der Receipt-Pfad unter Application Support war
in der Sandbox nicht beschreibbar. Diese Tests und die Receipt-Ablage bleiben
unverändert.

Prüfung am 12.09.2026: 69 Tests, 67 bestanden, zwei fehlgeschlagene Testfälle
(H4/H6h) mit denselben drei Assertions wie in der Baseline. Alle neun neuen Tests
bestanden.

Die Unit-Tests prüfen keine AppKit-/SwiftUI-Fensterdarstellung. Manuell sollten
Erststart, Öffnen per Menü/Tastenkürzel, wiederholtes Schließen/Öffnen des
beibehaltenen Fensters, Fokuswechsel und Schließen während eines Uploads geprüft werden.
