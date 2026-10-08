# Upload cancellation lifecycle

The macOS agent does not resume an interrupted client run. Every user-initiated import creates an independent server inventory run. The inventory remains authoritative and marks content already confirmed by an earlier run as known, so it is not uploaded again.

Cancelling an import propagates structured cancellation to queued jobs, active PhotoKit resource requests, and active URLSession upload tasks. No new jobs are scheduled after cancellation. Late progress and completion callbacks are scoped to a client-run identifier and cannot mutate the next run's UI state.

Legacy `upload-receipts.json` files are removed and their run IDs or upload tickets are never replayed. A PUT that reached the server immediately before cancellation is reconciled by the next inventory/content-identity check. Album synchronization only starts after the current run's file-transfer phase completes successfully.
