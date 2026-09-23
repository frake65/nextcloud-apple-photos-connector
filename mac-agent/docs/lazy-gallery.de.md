# Lazy-Galerie

## Quelle und Start

`GalleryLibrary` hält ein nach Medientyp gefiltertes `PHFetchResult<PHAsset>` auf
einem Hintergrund-Actor. Beim Öffnen werden diese Referenz und ihre Anzahl
abgefragt, ohne die Assets aufzuzählen, alle Cloud-Identifier aufzulösen oder
Bilder anzufordern. `LazyVGrid` verwendet ganzzahlige Indizes. Ein Zell-Task holt
einen kleinen `GalleryAsset`; dessen lokaler Identifier identifiziert den
geladenen Inhalt. Eine neue Fetch-Generation ersetzt die Grid-Identität, damit
Indizes keine Inhalte des vorherigen Fetches behalten.

Die persistierte Auswahl wird vollständig und unabhängig von Zellen gelesen.
Nach Veröffentlichung der Galerie wird nur diese Auswahl aufgelöst, um Zähler
und Mitglieder ausgewählter Alben wiederherzustellen. Eine sehr große gespeicherte
Auswahl benötigt weiterhin Zeit; Auswahlaktionen und Upload warten darauf,
während Galerie und Settings bedienbar bleiben. Bei leerer Auswahl werden keine
Alben abgefragt.

## Identität und Auswahl

Cloud-Mappings laufen auf `GalleryLibrary` in Blöcken von höchstens 128 Assets mit
`SettingsWorkGate`-Checkpoints dazwischen. Sichtbare Zellen lösen ein Asset auf;
der Metadaten-/Identitätscache hält höchstens 512 Einträge. Bei Mapping-Fehlern
bleibt der lokale Identifier der Fallback. Weder `PHAsset` noch `PHFetchResult`
überqueren die Actor-Grenze. Auswahl und Zähler sind vom begrenzten Cache unabhängig.

`PhotoSelectionRestorer.reconcile()` wird für die Galerie nicht mehr verwendet.
Fehlende oder unzugängliche persistierte Identitäten werden nicht stillschweigend
entfernt. Erfolgreich aufgelöste lokale Auswahlen können auf Cloud-Identitäten
umgestellt werden. Vor dem Upload wird die eingefrorene Auswahl erneut aufgelöst,
falls ein lokaler Fallback inzwischen eine Cloud-Identität erhalten hat. Spätere
UI-Änderungen verändern diesen Snapshot nicht. Der unveränderte Upload-Scanner prüft den vollständigen
Auswahl-Snapshot und weist ein unvollständiges Inventar zurück, statt nur den
sichtbaren Teil hochzuladen.

Einzelauswahl verwendet die bereits aufgelöste Identität und aktualisiert Zähler
ohne Galerie-Scan. „Alles auswählen“ durchläuft ausdrücklich den gesamten Fetch
in Hintergrund-Blöcken und liefert Identitätsmenge und Medienzähler zurück.
Albumauswahl löst sämtliche Mitglieder des gewählten Albums auf. Das bestehende
Verhalten beim Hinzufügen/Abwählen überlappender Alben bleibt erhalten.

## Alben

Beim Galerie-Start wird nicht mehr das vollständige Albuminventar erzeugt.
Öffnen des Album-Tabs oder Wiederherstellen einer gespeicherten Albumauswahl
fordert einen Katalog aus Namen, Identitäten, PhotoKit-Medienzählern und einem
Cover-Identifier pro Album an. Mitgliedslisten werden dabei nicht aufgezählt.
Vollständige Mitglieder werden nur für ausgewählte Alben aufgelöst. Vor dem
Katalog-Laden wird die Albumanzahl als unbekannt angezeigt. Album-Sync und
Upload-Scanner/-Protokoll bleiben unverändert.

## Bilder und Abbruch

Die bisherigen PhotoKit-Einstellungen bleiben bestehen: 180 × 180, Fast Format,
Aspect Fill und ausschließlich lokal verfügbare Bilder. `GalleryThumbnailLoader`
lässt höchstens acht Worker zu. Verschwindende wartende Zellen werden entfernt,
aktive Zellen brechen ihren PhotoKit-Request ab. Die Callback-Brücke speichert
die Request-ID und setzt ihre Continuation genau einmal fort, auch bei Abbruch
vor Rückgabe der ID sowie doppelten oder verspäteten Callbacks. Zell-Tasks prüfen
vor Veröffentlichung den Abbruch und geben ihren Bildzustand beim Verschwinden frei.

`PHCachingImageManager` wird weiterverwendet. Ein `NSCache` verwendet bis zu 128
Bilder mit einem geschätzten Kostenlimit von 16 MiB wieder. Das sind Cache-
Verdrängungsziele, keine harte Grenze für den Prozessspeicher. PhotoKit verwaltet
seinen internen Speicher selbst. Kein Scroll-Preheating oder eigenes Paging.
Fetch-Reloads invalidieren den Bildcache.

## Settings und MainActor

Initiale PhotoKit-Fetches, Identitätsauflösung, Albumabfragen und Thumbnail-
Requests laufen außerhalb des MainActors und prüfen das gemeinsame Gate.
Bereits zugelassene begrenzte Arbeit darf fertiglaufen. Das Öffnen der Settings
bricht selbst keinen Request ab; das Verschwinden einer Zelle dagegen schon.
Höchstens acht Thumbnail-Worker warten auf Freigabe. Abgebrochene wartende Zellen
starten nach Settings-Close nicht erneut. Galerie-Reloads und Albumkatalog-
Anfragen werden zusammengefasst.

Der MainActor veröffentlicht UI-State, verwaltet Auswahlmengen, persistiert
Auswahl und verwaltet Thumbnail-Queue/-Cache. Auswahlpersistenz und große
Mengenänderungen kosten weiterhin proportional zur Auswahlgröße Zeit.
Vollständige PhotoKit-Aufzählung und Cloud-Mapping pro Asset blockieren den
UI-Actor nicht mehr.

## Prüfung und manueller Build

`GalleryLoadingTests` prüfen produktives Modell und Request-Loader mit einer
simulierten Quelle mit 100.000 Assets, unsichtbare/persistierte Auswahl,
„Alles auswählen“, Albumauswahl, begrenzte Requests, Wiederverwendung, verspätete
Ergebnisse, direkte Callback-Rennen sowie Settings-Freigabe/-Zusammenfassung.
Sie messen keine echte PhotoKit-Latenz oder den exakten Sichtbarkeits-/Vorladebereich
von SwiftUI. Bestehende Settings- und Upload-Tests gehören weiterhin zu `swift test`.

Prüfung am 12.09.2026: Alle 82 Swift-Tests bestanden, einschließlich 13 neuer
Galerietests und aller 69 bestehenden Tests. Der Lauf verwendete freigegebenen
Zugriff auf die normalen Compiler-Caches und Application-Support-Pfade; die
früheren Sandbox-bedingten Cache-/Receipt-Fehler traten nicht auf. Testpfade und
Receipt-Ablage wurden nicht geändert.

Mit `CONFIGURATION=debug bash build-app.sh` in `mac-agent` bauen. Das Skript
signiert .build/Photos Connector.app ad hoc und startet die App nicht. Galerie-
Ereignisse werden nur bei aktiviertem Debug nach
`~/Library/Logs/Apple Photos Connector/debug.log` geschrieben:
`gallery.fetch.count`, `gallery.initial.ready`, Identifier-Blockgrößen und
Thumbnail-Aktivitäts-/Abbruchereignisse. Keine Asset-Identifier oder Dateinamen.

Manuell Start/CPU/RAM mit großer Mediathek, schnelles Weg-/Zurückscrollen,
Auswahl weit auseinanderliegender Fotos samt Upload sowie Settings während
Scrollen und „Alles auswählen“ prüfen. Echte iCloud-Verfügbarkeit und Photos-
Berechtigungen sind nicht durch die Simulation abgedeckt. Es gibt keinen neuen
Observer für laufende Mediatheksänderungen; ein bestehender ausdrücklicher Reload
ersetzt den Fetch-Snapshot.
