# Verbindung zurücksetzen

## Verhalten

Die Einstellungen bieten unter Verbindungstest/Kontoaktionen den sekundären Button „Verbindung zurücksetzen“. Er ist bei gespeicherter Identität, validierter Verbindung oder laufendem Anmelde-/Prüfversuch aktiv, nicht bei einem bloßen ungespeicherten Entwurf. Die Bestätigung erläutert, dass ausschließlich Server, Benutzer und Zugangsdaten dieses Clients entfernt werden und Nextcloud-Daten unverändert bleiben. Dies ersetzt die bisherige unvollständige Aktion „Verbindung trennen“.

`ConnectionSession.resetConnection` entwertet die Versuchs-ID, bricht Login- und Prüftasks ab und ruft `ValidatedConnectionPersistence.resetConnection` auf. Diese löscht ausschließlich den Keychain-Eintrag des gespeicherten Server-/Benutzerpaars, entfernt diese Einstellungen und invalidiert Verbindungs- und Zielbestätigung. Formularidentität, Passwort und Erfolgsstatus werden erst nach erfolgreicher Persistierung geleert. Bei einem Keychain-Löschfehler bleibt die gespeicherte Verbindung erhalten und eine Fehlermeldung erscheint; laufende Versuche bleiben entwertet. Reset verwendet keine Netzwerkoperation.

Andere serverspezifische Credentials bleiben erhalten. Legacy-Einträge werden vor dem Laden der Einstellungen zur gespeicherten Identität migriert und entfernt. Reset errät keine Zugehörigkeit verbliebener unspezifischer Einträge. Zielpfad, lokale Historie und andere Einstellungen bleiben erhalten; die Zielbestätigung wird invalidiert.

Die Einstellungen schließen die Ordnerauswahl und verwerfen ausstehende Zielauswahlen. Die bestehende Verbindungsbenachrichtigung veranlasst das Hauptmodell, die leere Identität zu laden und einen Uploadtask mit der bisherigen Verbindung abzubrechen. API-Clients werden pro Operation erstellt und nicht gecacht; überholte Login-Ergebnisse können keinen Prüfclient erstellen oder Credentials übernehmen. Auch UI-Veröffentlichungen nach einem Actor-Wechsel prüfen die Versuchs-ID. Programmatische Feldleerung umgeht die Bindings für Benutzereingaben und kann weder Credentials nachladen noch eine Prüfung starten.

## Verifikation

Sieben Regressionstests prüfen Leer-/Resetzustand und Button-Aktivierung, gezielte Credential-Löschung und Erhalt anderer Konten, verspätete Login-/Prüfergebnisse, Abbruch beider Tasks, Konsistenz bei Löschfehlern, verhinderten Aufbau eines authentifizierten Clients nach Reset, programmatische Leerung und ausschließlich lokale Einstellungsänderungen. Sie testen das gemeinsame Zustandsmodell; ein Live-Klicktest der SwiftUI-Oberfläche wurde nicht durchgeführt.

Gesamte macOS-Suite: 119 Tests, 117 bestanden; zwei bereits zuvor fehlgeschlagene Upload-Tests melden drei fehlgeschlagene Assertions, weil die Sandbox ihre Receipt-Schreibzugriffe unter Application Support verweigert. Alle Reset-Tests bestehen. Die lokale Debug-App wird erfolgreich gebaut. `git diff --check` besteht. Keine Versions-, Tag-, Release- oder Notarisierungsänderung.
