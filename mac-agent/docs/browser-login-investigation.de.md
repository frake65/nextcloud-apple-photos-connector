# Untersuchung der Browser-Anmeldung

## Ursache und Reproduktion

Login Flow v2 startet gegen den in den Einstellungen eingegebenen Server und fragt den von ihm gelieferten Polling-Endpunkt ab. Aus `server`, `loginName` und `appPassword` wird bereits eine neue Verbindung aufgebaut, geprüft und anschließend gespeichert. Ein gecachter authentifizierter API-Client ist nicht beteiligt: `NetworkTransport` erstellt pro Anfrage eine kurzlebige URLSession.

Der Hauptfehler lag zwischen Transport und Polling-Service: Der echte Transport wirft `UploadError.http(404)`, während der Service nur eine zurückgegebene Antwort mit Status 404 behandelte. Die erste ausstehende Antwort beendete deshalb die Anmeldung im Client als `network`, obwohl der Browser offen blieb und die Anmeldung abschließen konnte. Der bisherige Mock gab 404 zurück, ohne einen Fehler zu werfen, und verdeckte das Problem. Auch die Erstanmeldung ist betroffen; ein Serverwechsel ist nicht erforderlich.

`testRealTransportStyle404ContinuesPolling` reproduziert dies ohne Browser. Mit dem ursprünglichen Service scheiterte der Test mit `network`; mit dem korrigierten Service besteht er.

Weitere Zustandsfehler: Passwörter waren ausschließlich nach Benutzername gespeichert; Server-/Benutzereingaben schrieben sofort in UserDefaults, während das alte Passwort erhalten blieb; der synchrone Schalter `applyingLoginFlow` schützte nicht vor späteren SwiftUI-Callbacks, die den Erfolg invalidieren konnten; abgebrochene oder überholte Anfragen konnten weiterhin Ergebnisse übernehmen.

## Korrektur

Polling behandelt auch einen geworfenen HTTP-404-Fehler als ausstehend. Formularfelder sind lokale Entwürfe. Nur vom Benutzer ausgelöste Binding-Schreibvorgänge invalidieren den Entwurf, leeren bei Server-/Benutzerwechsel das Passwort und brechen laufende Anmeldeversuche ab. Programmatisch übernommene Ergebnisse lösen diese Invalidierung nicht aus. Jeder Versuch erhält eine vor dem Speichern geprüfte Identität; nach der Validierung wird zusätzlich auf Abbruch geprüft. Die gespeicherte Verbindung bleibt bis zur erfolgreichen Validierung und Keychain-Speicherung erhalten.

Manuelle und Browser-Anmeldung verwenden dieselbe Übernahme auf dem Main Actor ohne Unterbrechung zwischen Credential- und Settings-Schreibvorgängen. Die bestätigten Werte ersetzen die aktiven Einstellungen, invalidieren die Zielbestätigung, setzen die Verbindung auf validiert und benachrichtigen die Hauptansicht zum Neuladen. Dies ist eine Transaktion innerhalb des Prozesses, keine gegen Prozessabstürze atomare Transaktion über Keychain und UserDefaults.

Keychain-Konten enthalten Server-URL einschließlich Installationspfad und Benutzername. Alte Einträge migrieren vor der Bearbeitung ausschließlich zur gespeicherten Installation und werden anschließend entfernt. Alte serverspezifische Einträge werden nie für andere Server geladen. Die CLI verwendet dieselbe Ablage. Passwort, App-Passwort, Token und Authorization-Header werden nicht protokolliert.

## Verifikation

Sechs neue Tests decken geworfene Pending-Antworten, Start gegen B und vorgegebenen Polling-Endpunkt, zurückgegebene Server-/Credential-Werte und neuen Client/Transport, erstmalige und ersetzende Übernahme einschließlich Validierungszustand, Servertrennung bei gleichem Benutzernamen, Erhalt bei Keychain-Fehlern und Migration ab. Bestehende Passworttests prüfen weiterhin manuelle Credentials. Die SwiftUI-Interaktion wurde nicht gegen zwei echte Nextcloud-Instanzen ausgeführt.

Finale macOS-Testsuite: 112 Tests; 110 bestanden, zwei vorhandene Upload-Tests mit drei Assertions fehlgeschlagen, weil die Sandbox das Schreiben der upload-receipts-Datei unter Application Support verweigert. Login- und Credential-Tests bestehen. Der lokale Debug-App-Build ist erfolgreich. `git diff --check` besteht. Keine Versionsänderung, kein Release, Tag, Notarisierung oder Deployment.

## Manuelle Abnahme

Mit A verbinden und Upload-Bereitschaft prüfen. In den Einstellungen Server durch B ersetzen und Credentials leer lassen. Browser-Anmeldung starten, mehrere ausstehende Polls abwarten und in B bestätigen. Zurückgegebenes Konto und Server, grünen Verbindungsstatus und notwendige Zielbestätigung prüfen. Einstellungen erneut öffnen und Wiederherstellung von B prüfen. Mit gleichem Benutzernamen auf beiden Servern, Abbruch während Polling, Serverwechsel während des Wartens und fehlgeschlagener Validierung gegen B wiederholen: Kein fehlgeschlagener oder überholter Versuch darf die gespeicherte Verbindung A ersetzen. Explizite manuelle Credentials müssen weiterhin geprüft und gespeichert werden.
