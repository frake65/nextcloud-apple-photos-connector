# macOS-Agent: ImportScope entfernt

## Ergebnis

Die Einstellung „Übertragungsumfang“ und ihre fachliche ImportScope-Logik wurden aus dem macOS-Agenten entfernt. Die Photos-Auswahl ist jetzt der einzige lokale Kandidatenfilter. Der Agent sendet ausgewählte Assets als Inventory; Uploads werden weiterhin ausschließlich aus der Serverantwort (`new`, fehlend/retransfer, `known`/`present`) geplant.

Alte `nextcloud.importScope.<source>`-Werte werden beim App-Start entfernt. Andere Defaults, Credentials und Zielkonfigurationen bleiben erhalten. Die Auswahl selbst wird nicht von dieser Bereinigung gelöscht.

## Semantik

- Einzelne Fotos: genau die ausgewählten stabilen Asset-Identitäten werden inventarisiert.
- Ein Album: seine Asset-Identitäten werden in die Auswahl übernommen; Album-Membership bleibt ein separater Album-Sync-Schritt.
- Mehrere Alben: Asset-Identitäten werden als Set vereinigt; Überschneidungen werden einmal inventarisiert.
- Leere Auswahl: Upload wird mit einer verständlichen Fehlermeldung abgebrochen; es gibt keinen impliziten Mediathek-Import.
- App-Neustart: die Auswahl wird pro Source unter `nextcloud.photoSelection.<source>` persistiert und wiederhergestellt. Alte ImportScope-Werte haben keinen Einfluss mehr.
- Bekanntes Asset plus neue Album-Membership: das Asset bleibt Inventory-Kandidat, aber der Server entscheidet `known`/`present`; kein erneuter PUT. Die Album-Membership wird separat gemeldet.

## Tests

Die früheren ImportScope-Tests wurden durch `PhotoSelectionTests` ersetzt. Sie prüfen stabile Album-Identität, Set-Deduplizierung und dass eine leere Auswahl ein leeres Inventory ergibt. Diese lokalen Tests belegen Kandidatenumfang und Persistenzbereinigung; die serverseitigen Antwortfälle werden im bestehenden `UploadCoordinator`-Testbestand über die Inventory-Antwort simuliert.

| Fall | Status |
| --- | --- |
| T1 neues ausgewähltes Asset im Inventory | PASS durch Kandidatenfilter/InventoryJSON |
| T2 Server `new` uploadbar | PASS durch bestehende UploadCoordinator-Tests |
| T3 bekanntes ausgewähltes Asset im Inventory | PASS durch Kandidatenfilter |
| T4 Server `known` kein Upload | PASS durch bestehende UploadCoordinator-Tests |
| T5 Server `present` kein PUT | PASS durch bestehende UploadCoordinator-Tests |
| T6 nicht ausgewähltes Asset fehlt | PASS durch Kandidatenfilter |
| T7 alter ImportScope-Wert | PASS: Werte werden nicht gelesen und beim Start entfernt |
| T8 Neustartsemantik | PASS: keine ImportScope-Leselogik verbleibt |
| T9 leere Auswahl | PASS: expliziter Abbruch, kein Library-Fallback |
| T10 Album als Kandidatenquelle | PASS: Album-Set wird im Browsermodell in Asset-Auswahl übernommen |
| T11 mehrere Alben ohne Asset-Duplikate | PASS durch Set-Vereinigung |
| T12 Asset in mehreren Alben | PASS: einmaliges Inventory; Memberships bleiben Album-Sync vorbehalten |

`swift test`: 45 Tests, 0 Fehler. Debug-Build durch `swift test`: PASS. Release-Build mit Xcode 27.0 / Build 27A266a: PASS. Es gab nur bestehende Compiler-Warnungen zu `try?` und optionaler String-Interpolation.

Servercode, Photos-Code, Bundle-ID, UserDefaults-Domain, Keychain-Service und produktive Serverdaten wurden nicht geändert.

## Offene Grenze

Die Auswahlpersistenz ist bewusst auf stabile Asset-/Album-Identitäten und die bestehende UserDefaults-Domain begrenzt. Der aktuelle Umbau fällt bei leerer Auswahl sicher aus, statt die gesamte Mediathek zu importieren.
