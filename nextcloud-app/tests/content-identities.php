<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\ContentIdentityRepository;
use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\{AssetIdentity,InventoryService,InventoryValidator,UploadService,UploadTargetService};

function contentIdentityScenarios(): void {
    $legacyPdo = new PDO('sqlite::memory:');
    $legacyPdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $legacySchema = new TestHarness\Schema();
    (new OCA\ApplePhotosConnector\Migration\Version008000Date20260910000000())->changeSchema(
        new class implements OCP\Migration\IOutput {}, fn () => $legacySchema, []);
    $legacySchema->apply($legacyPdo);
    $legacyPdo->exec("INSERT INTO apc_assets (user_id,source_id,local_identifier,media_type,first_seen_at,last_seen_at,current_upload_target_id,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('legacy','legacy-source','legacy-asset','image','now','now',1,701,'legacy.heic','2026-09-01T00:00:00Z')");
    $legacyPdo->exec("INSERT INTO apc_upload_targets (id,user_id,source_id,asset_id,filename,path,path_key,bytes,sha256,attempt) VALUES (1,'legacy','legacy-source',1,'legacy.heic','legacy.heic','legacy-key',12,'" . hash('sha256', 'legacy-bytes') . "',0),(2,'legacy','legacy-source',1,'pending.heic','pending.heic','pending-key',13,'" . hash('sha256', 'pending-bytes') . "',0)");
    $legacyPdo->exec("INSERT INTO apc_uploads (user_id,source_id,upload_id,run_id,asset_id,status,created_at,target_id) VALUES ('legacy','legacy-source','legacy-upload','legacy-run',1,'uploaded','2026-09-01T00:00:00Z',1),('legacy','legacy-source','pending-upload','pending-run',1,'pending','2026-09-01T00:00:00Z',2)");
    $upgradeSchema = new TestHarness\Schema();
    $upgrade = new OCA\ApplePhotosConnector\Migration\Version008600Date20260918000000(new TestHarness\Connection($legacyPdo));
    $upgrade->changeSchema(new class implements OCP\Migration\IOutput {}, fn () => $upgradeSchema, []);
    $upgradeSchema->apply($legacyPdo);
    $upgrade->postSchemaChange(new class implements OCP\Migration\IOutput {}, fn () => $upgradeSchema, []);
    $legacyContents = new ContentIdentityRepository(new TestHarness\Connection($legacyPdo));
    check($legacyContents->find('legacy', hash('sha256', 'legacy-bytes'), 12) !== null
        && count($legacyContents->confirmedTargets('legacy', hash('sha256', 'legacy-bytes'), 12)) === 1
        && $legacyContents->find('legacy', hash('sha256', 'pending-bytes'), 13) === null,
        'CI0: additive upgrade backfills existing uploaded targets and excludes pending reservations');

    // A failure after the content identity insert must roll back the whole backfill.
    $rollbackPdo = new PDO('sqlite::memory:');
    $rollbackPdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $rollbackBaseSchema = new TestHarness\Schema();
    (new OCA\ApplePhotosConnector\Migration\Version008000Date20260910000000())->changeSchema(
        new class implements OCP\Migration\IOutput {}, fn () => $rollbackBaseSchema, []);
    $rollbackBaseSchema->apply($rollbackPdo);
    $rollbackPdo->exec("INSERT INTO apc_assets (user_id,source_id,local_identifier,media_type,first_seen_at,last_seen_at,current_upload_target_id,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('rollback','rollback-source','rollback-asset','image','now','now',1,701,'rollback.heic','2026-09-01T00:00:00Z')");
    $rollbackPdo->exec("INSERT INTO apc_upload_targets (id,user_id,source_id,asset_id,filename,path,path_key,bytes,sha256,attempt) VALUES (1,'rollback','rollback-source',1,'rollback.heic','rollback.heic','rollback-key',12,'" . hash('sha256', 'rollback-bytes') . "',0)");
    $rollbackPdo->exec("INSERT INTO apc_uploads (user_id,source_id,upload_id,run_id,asset_id,status,created_at,target_id) VALUES ('rollback','rollback-source','rollback-upload','rollback-run',1,'uploaded','2026-09-01T00:00:00Z',1)");
    $rollbackSchema = new TestHarness\Schema();
    $rollbackMigration = new OCA\ApplePhotosConnector\Migration\Version008600Date20260918000000(new TestHarness\Connection($rollbackPdo));
    $rollbackMigration->changeSchema(new class implements OCP\Migration\IOutput {}, fn () => $rollbackSchema, []);
    $rollbackSchema->apply($rollbackPdo);
    $rollbackPdo->exec("CREATE TRIGGER fail_content_target BEFORE INSERT ON apc_content_targets BEGIN SELECT RAISE(ABORT, 'test backfill failure'); END");
    try {
        $rollbackMigration->postSchemaChange(new class implements OCP\Migration\IOutput {}, fn () => $rollbackSchema, []);
        throw new LogicException('Expected backfill failure');
    } catch (Throwable $error) {
        check((int)$rollbackPdo->query('SELECT COUNT(*) FROM apc_content_identities')->fetchColumn() === 0
            && (int)$rollbackPdo->query('SELECT COUNT(*) FROM apc_content_targets')->fetchColumn() === 0,
            'CI12: failed backfill rolls back content identity and target rows');
    }

    $pdo = freshDatabase();
    $db = new TestHarness\Connection($pdo);
    $repo = new InventoryRepository($db);
    $contents = new ContentIdentityRepository($db);
    $files = new TestFiles();
    $inventory = new InventoryService($repo, new AssetIdentity(), new InventoryValidator(), $files);
    $prepare = new UploadTargetService($repo, $files);
    $complete = new UploadService($repo, $files);
    $user = 'content-' . bin2hex(random_bytes(4));
    $source = ['sourceId' => 'de008600-0000-4000-8000-000000000001', 'name' => 'Content'];
    $asset = static fn(string $local, string $filename): array => ['localIdentifier' => $local, 'filename' => $filename, 'mediaType' => 'image'];
    $upload = static function (string $owner, array $source, array $asset) use ($inventory, $prepare, $complete, $files, $repo): array {
        $run = $inventory->ingest($owner, $source, [$asset]);
        $ticket = $run['assets'][0]['upload'];
        $bytes = strlen('same-content');
        $sha256 = hash('sha256', 'same-content');
        $target = $prepare->prepare($owner, $source['sourceId'], $run['runId'], $ticket['uploadId'], $bytes, $sha256);
        $targetRow = array_values(array_filter($repo->getTargetsForAsset($owner, $source['sourceId'], (int)$ticket['assetId']),
            static fn(array $row): bool => $row['path'] === $target['path']))[0];
        $files->contents[$target['path']] = 'same-content';
        $files->files[$target['path']] = random_int(1000, 9000);
        $ack = $complete->acknowledge($owner, $source['sourceId'], $run['runId'], $ticket['uploadId'], 'uploaded', $target['path']);
        return [$run, $ticket, $target, $targetRow, $ack];
    };

    // Prepare alone is only a reservation and must not become content evidence.
    $pending = $inventory->ingest($user, $source, [$asset('pending', 'pending.heic')]);
    $pendingTicket = $pending['assets'][0]['upload'];
    $pendingTarget = $prepare->prepare($user, $source['sourceId'], $pending['runId'], $pendingTicket['uploadId'], 12, hash('sha256', 'same-content'));
    check($contents->find($user, hash('sha256', 'same-content'), 12) === null, 'CI1: prepared/unconfirmed target is not content evidence');
    $pendingTargetRow = array_values(array_filter($repo->getTargetsForAsset($user, $source['sourceId'], (int)$pendingTicket['assetId']),
        static fn(array $row): bool => $row['path'] === $pendingTarget['path']))[0];
    try {
        $contents->recordConfirmedTarget($user, $source['sourceId'], (int)$pendingTicket['assetId'], $pendingTargetRow, 900, 'now');
        throw new LogicException('Unconfirmed target accepted as content evidence');
    } catch (InvalidArgumentException) {
        check($contents->find($user, hash('sha256', 'same-content'), 12) === null, 'CI1a: repository refuses evidence without uploaded confirmation');
    }
    $complete->acknowledge($user, $source['sourceId'], $pending['runId'], $pendingTicket['uploadId'], 'failed', null);
    check($contents->find($user, hash('sha256', 'same-content'), 12) === null, 'CI2: failed target is not content evidence');

    [$runA, $ticketA, $targetA, $targetRowA, $ackA] = $upload($user, $source, $asset('one', 'one.heic'));
    $sha = hash('sha256', 'same-content');
    $size = strlen('same-content');
    $identity = $contents->find($user, $sha, $size);
    $refs = $contents->confirmedTargets($user, $sha, $size);
    check($identity !== null && count($refs) === 1 && (int)$refs[0]['upload_target_id'] === (int)$targetRowA['id'], 'CI3: confirmed upload persists content identity and target proof');
    $again = $complete->acknowledge($user, $source['sourceId'], $runA['runId'], $ticketA['uploadId'], 'uploaded', $targetA['path']);
    check($again === $ackA && count($contents->confirmedTargets($user, $sha, $size)) === 1, 'CI4: completion replay is idempotent');

    $sourceB = ['sourceId' => 'de008600-0000-4000-8000-000000000004', 'name' => 'Second source'];
    unset($files->files[$targetA['path']]); // exercise the deleted-first-candidate fallback
    [$runB, , $targetB] = $upload($user, $sourceB, $asset('two', 'two.heic'));
    check($contents->find($user, $sha, $size)['id'] === $identity['id']
        && count($contents->confirmedTargets($user, $sha, $size)) === 2
        && count($repo->assets($user, $source['sourceId'])) === 2,
        'CI5: same user/hash/bytes shares content key while distinct asset rows and target proofs remain separate');
    check($repo->run($user, $runB['runId'])['status'] === 'completed' && $targetB['path'] !== $targetA['path'], 'CI6: separate asset keeps its own confirmed target');

    $otherUser = $user . '-other';
    $otherSource = ['sourceId' => 'de008600-0000-4000-8000-000000000002', 'name' => 'Other user'];
    $upload($otherUser, $otherSource, $asset('one', 'one.heic'));
    check($contents->find($otherUser, $sha, $size) !== null
        && $contents->find($otherUser, $sha, $size)['id'] !== $identity['id']
        && count($contents->confirmedTargets($user, $sha, $size)) === 2,
        'CI7: identical bytes are isolated by Nextcloud user');
    check($contents->find($user, $sha, $size + 1) === null, 'CI8: matching also requires identical byte size');

    $reconcileSource = ['sourceId' => 'de008600-0000-4000-8000-000000000003', 'name' => 'Reconcile source'];
    $reconcileRun = $inventory->ingest($user, $reconcileSource, [$asset('device-copy', 'copy.heic')]);
    $reconcileTicket = $reconcileRun['assets'][0]['upload'];
    $reconciled = $prepare->prepare($user, $reconcileSource['sourceId'], $reconcileRun['runId'], $reconcileTicket['uploadId'], $size, $sha);
    check($reconciled['state'] === 'contentAlreadyPresent' && $reconciled['path'] === $targetA['path'], 'CI8a: new asset from another source reconciles before PUT');
    $knownAgain = $inventory->ingest($user, $reconcileSource, [$asset('device-copy', 'copy.heic')]);
    check($knownAgain['assets'][0]['state'] === 'known' && count($repo->assets($user, $reconcileSource['sourceId'])) === 1, 'CI8b: reconciled asset remains separate and becomes known');

    // Simulate a pre-feature installation: remove only the new index rows, retaining confirmed APC tickets/targets.
    $pdo->exec('DELETE FROM apc_content_targets');
    $pdo->exec('DELETE FROM apc_content_identities');
    $files->readFailure = true;
    check($contents->backfillConfirmedTargets() === 3
        && count($contents->confirmedTargets($user, $sha, $size)) === 2
        && count($contents->confirmedTargets($otherUser, $sha, $size)) === 1,
        'CI9: confirmed historical APC targets backfill from stored hash/bytes without reading files');
    check($contents->backfillConfirmedTargets() === 0, 'CI10: confirmed-target backfill is idempotent');

    // An existing inventory remains source/asset-based; the content index is not consulted by inventory.
    $fresh = $inventory->ingest($user, $source, [$asset('one', 'one.heic')]);
    check($fresh['assets'][0]['state'] === 'known' && count($repo->assets($user, $source['sourceId'])) === 2,
        'CI11: existing new/known behavior and separate APC assets remain unchanged');
}
