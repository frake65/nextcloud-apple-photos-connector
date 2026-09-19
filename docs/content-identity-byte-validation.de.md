# Byte-Prüfung der Content Identity

Diese manuelle, nur in DEBUG verfügbare Diagnose vergleicht die von PhotoKit gewählte Originalressource des Mac-Agenten und der iOS-App. Sie exportiert in ein eigenes temporäres Verzeichnis, berechnet SHA-256 und Byteanzahl mit `InventoryCore.ContentIdentity` und löscht danach das temporäre Verzeichnis. Sie kontaktiert Nextcloud nicht und führt weder eine Inventarprüfung noch einen Upload aus. Die Aktion ist ausschließlich in DEBUG-Builds enthalten.

## Test 1: normales Foto

1. Verwende einen Mac und ein iPhone mit derselben iCloud-Fotomediathek. Starte auf beiden Geräten die DEBUG-App.
2. Wähle auf jedem Gerät exakt dasselbe normale Foto aus (RAW- und Live-Photo-Sonderfälle sind in dieser Phase nicht enthalten).
3. Aktiviere am Mac den bestehenden Debug-Modus und wähle **Original-Hash berechnen**. Öffne am iPhone die Ansicht der Auswahl und wähle dort **DEBUG: Original-Hash berechnen**. Tippe nicht auf **Auswahl prüfen**; das ist eine separate Server-Inventaraktion.
4. Warte, bis Export beziehungsweise iCloud-Download und Hash-Berechnung abgeschlossen sind. Vergleiche Ressourcentyp, Dateiname, Bytes und SHA-256. Notiere lokale ID und Cloud-ID separat.

Erwartung: Ressourcentyp, Byteanzahl und SHA-256 stimmen überein. Lokale IDs dürfen verschieden sein. Notiere, ob Cloud-IDs vorhanden sind und ob sie übereinstimmen.

## Test 2: normales Video (optional)

Wiederhole den Test mit demselben normalen Video auf beiden Geräten. Es gelten dieselben Vergleiche.

## Spätere Fälle (nicht implementiert oder automatisiert)

- Live Photo
- bearbeitetes Foto
- RAW/JPEG-Paar
- ausschließlich in iCloud verfügbares Asset

## Zu berichtende Werte

- Ressourcentyp: Mac / iPhone
- Originaldateiname: Mac / iPhone
- Byteanzahl: Mac / iPhone
- SHA-256: Mac / iPhone
- Cloud-ID: auf jedem Gerät vorhanden und gleich oder verschieden

Die lokale ID kann bei Bedarf ebenfalls genannt werden, ist aber kein Inhaltsvergleichswert.
