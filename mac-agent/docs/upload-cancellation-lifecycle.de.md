# Lebenszyklus beim Upload-Abbruch

Der macOS-Agent nimmt einen unterbrochenen Client-Lauf nicht wieder auf. Jeder vom Benutzer gestartete Import erzeugt einen unabhängigen serverseitigen Inventarlauf. Das Serverinventar bleibt maßgeblich und kennzeichnet Inhalte, die in einem früheren Lauf bereits bestätigt wurden, als bekannt, sodass sie nicht erneut übertragen werden.

Beim Abbruch wird das strukturierte Abbruchsignal an wartende Jobs, aktive PhotoKit-Ressourcenanforderungen und aktive URLSession-Upload-Tasks weitergegeben. Nach dem Abbruch werden keine neuen Jobs eingeplant. Verspätete Fortschritts- und Abschluss-Callbacks sind an eine Client-Laufkennung gebunden und können den UI-Zustand eines folgenden Laufs nicht verändern.

Alte `upload-receipts.json`-Dateien werden entfernt; ihre Run-IDs oder Upload-Tickets werden nie erneut abgespielt. Ein PUT, der den Server unmittelbar vor dem Abbruch erreicht hat, wird durch den nächsten Inventar- und Inhaltsidentitätsabgleich erkannt. Die Albumsynchronisierung startet erst, nachdem die Dateiübertragungsphase des aktuellen Laufs erfolgreich abgeschlossen ist.
