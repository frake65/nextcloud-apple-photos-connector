Photos Connector – verständlichere Beschreibung und Upload-Zusammenfassung

Bitte zwei kleine UI-Anpassungen vornehmen.

## 1. Upload-Abschluss um Ergebnis ergänzen

Foto-/Video-Upload und Album-Abgleich bleiben bewusst getrennte Vorgänge.

Nach einem erfolgreichen Foto-/Video-Upload beispielsweise:

`Upload abgeschlossen · 124 Fotos · 17 Videos übertragen`

Nullwerte ausblenden:

`Upload abgeschlossen · 124 Fotos übertragen`

`Upload abgeschlossen · 17 Videos übertragen`

Singular/Plural korrekt lokalisieren.

Gezählt werden ausschließlich die in diesem Vorgang tatsächlich neu übertragenen Dateien. Bereits bekannte, übersprungene oder fehlgeschlagene Elemente dürfen nicht als übertragen gezählt werden.

Nach dem separaten Album-Abgleich beispielsweise:

`Album-Abgleich abgeschlossen · 8 Alben abgeglichen`

Auch hier Singular/Plural korrekt behandeln und die tatsächlich abgeglichenen Alben ausweisen.

Die Anzeigen vollständig für `en`, `de`, `fr`, `pt`, `nl`, `es` lokalisieren und die vorhandene Pluralisierungsfunktion verwenden.

## 2. Technische Programmbeschreibung ersetzen

Den bisherigen technischen Text beginnend mit

`Liest lokale und Cloud Identifier...`

vollständig durch folgende deutsche Fassung ersetzen:

`Überträgt deine Fotos, Videos und Alben aus Apple Fotos sicher in deine Nextcloud. Zusätzlich zu dieser App wird die zugehörige App auf dem Nextcloud-Server benötigt.`

Diesen Text natürlich und sinngemäß für alle unterstützten Sprachen lokalisieren:

`en`, `de`, `fr`, `pt`, `nl`, `es`

Englisch bleibt Fallback.

Keine technischen Begriffe wie Local Identifier, Cloud Identifier, PHAsset, Inventory oder Asset Identity in der Benutzerbeschreibung.

## 3. Bestehende Semantik beibehalten

Keine Änderungen an Upload-, Receipt-, Re-Inventory-, DAV-, Collision-, Album-Sync- oder Serverlogik.

Anschließend Swift-Tests und Localization-Audit ausführen.