# APC 0.8.0 Upload-Ticket-Lifecycle

Die lokale Server-App verwendet jetzt eine zentrale 24-Stunden-TTL (`UploadTicketPolicy::TTL_SECONDS`). Neue Tickets speichern `created_at`; der Fresh-Install-Stand enthält außerdem den Status `expired` als terminalen Zustand.

Expiry wird serverseitig vor Prepare und Complete geprüft. Die atomare Prüfung markiert ein fälliges `pending`-Ticket zuerst als `expired` und verwirft danach den Vorgang. Ein abgelaufenes Ticket kann weder Upload, Recovery, Target-Wechsel noch `current_upload_target_id`-Wechsel auslösen. Datensätze werden nicht physisch gelöscht.

Die Prüfung invalidiert keine anderen Tickets eines Assets. Benutzer-, Source-, Run-, Upload-, Asset-, Base-Target-, Current-Target- sowie Replay-/Race-Prüfungen bleiben unverändert. Neue Inventarläufe erzeugen unabhängig von alten Tickets eigene Tickets.

Die kontrollierte SQLite-Uhr prüft frische, knapp gültige und abgelaufene Tickets. Die neue Lifecycle-Suite deckt X1–X12 sowie L1–L7 ab; vorhandene R13-Race- und Source-Isolationstests bleiben PASS.

## Bestehende sabine-Tickets

Die sechs `pending`-Tickets des abgebrochenen Laufs wurden nicht verändert. Ihr Alter wurde ausschließlich aus dem vorhandenen `apc_import_runs.started_at` gelesen: alle sechs waren beim Check ungefähr **0,16 Stunden** alt und damit nach der neuen 24-Stunden-Policy noch nicht abgelaufen. `apc_uploads` besitzt im installierten Serverstand noch kein `created_at`; die Ablaufprüfung ist dort daher erst nach einem Deployment des neuen Fresh-Install-Schemas wirksam. Es erfolgte kein Deployment.

PHP-Syntax und gesamte SQLite-Suite: **PASS**. Keine Client-, Photos- oder Server-Produktivänderung; kein neuer E2E-Test.
