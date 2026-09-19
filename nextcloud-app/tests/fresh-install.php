<?php
declare(strict_types=1);

function freshDatabase(): PDO {
    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $schema = new TestHarness\Schema();
    (new OCA\ApplePhotosConnector\Migration\Version008000Date20260910000000())->changeSchema(
        new class implements OCP\Migration\IOutput {}, fn () => $schema, []);
    $db = new TestHarness\Connection($pdo);
    $contentMigration = new OCA\ApplePhotosConnector\Migration\Version008600Date20260918000000($db);
    $contentMigration->changeSchema(new class implements OCP\Migration\IOutput {}, fn () => $schema, []);
    $schema->apply($pdo);
    $contentMigration->postSchemaChange(new class implements OCP\Migration\IOutput {}, fn () => $schema, []);
    return $pdo;
}

function freshInstallScenarios(): void {
    $pdo = freshDatabase();
    check(count(glob(__DIR__ . '/../lib/Migration/*.php')) === 2, 'F1: fresh-install base schema plus one additive content-identity migration');
    $tables = $pdo->query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'apc_%' ORDER BY name")->fetchAll(PDO::FETCH_COLUMN);
    check($tables === ['apc_album_memberships','apc_assets','apc_content_identities','apc_content_targets','apc_import_runs','apc_nextcloud_album_map','apc_source_albums','apc_sources','apc_upload_targets','apc_uploads'], 'F2: ten tables created from empty schema including additive content identity');
    $columns = array_column($pdo->query('PRAGMA table_info(apc_assets)')->fetchAll(PDO::FETCH_ASSOC), null, 'name');
    check(isset($columns['current_upload_target_id']) && $columns['current_upload_target_id']['notnull'] === 0, 'F3: current_upload_target_id nullable');
    $pdo->exec("INSERT INTO apc_assets (user_id,source_id,local_identifier,media_type,first_seen_at,last_seen_at) VALUES ('u','s','a','image','now','now'),('v','s','b','image','now','now'),('u','t','c','image','now','now'),('u','s','d','image','now','now')");
    $insert = $pdo->prepare('INSERT INTO apc_upload_targets (user_id,source_id,asset_id,filename,path,path_key,bytes,sha256,attempt) VALUES (?,?,?,?,?,?,?,?,0)');
    $target = function(string $u, string $s, int $asset, string $path) use ($insert, $pdo): int {
        $insert->execute([$u,$s,$asset,'test.jpg',$path,hash('sha256',$path),8,hash('sha256','ORIGINAL')]);
        return (int)$pdo->lastInsertId();
    };
    $one = $target('u','s',1,'one'); $two = $target('u','s',1,'two');
    check($one !== $two, 'F4: multiple targets per asset allowed');
    try { $target('u','s',4,'one'); throw new LogicException('Duplicate path allowed'); } catch (PDOException) {}
    check(true, 'F5: UNIQUE(user_id,path_key) enforced across assets');
    $indices = $pdo->query('PRAGMA index_list(apc_upload_targets)')->fetchAll(PDO::FETCH_ASSOC);
    $assetIndices = array_values(array_filter($indices, fn(array $i): bool => array_column($pdo->query('PRAGMA index_info('.$i['name'].')')->fetchAll(PDO::FETCH_ASSOC),'name') === ['asset_id']));
    check(count($assetIndices) === 1 && (int)$assetIndices[0]['unique'] === 0, 'F6: asset_id has a normal index, no unique index');
    $columns = array_column($pdo->query('PRAGMA table_info(apc_uploads)')->fetchAll(PDO::FETCH_ASSOC), null, 'name');
    $pdo->exec("INSERT INTO apc_uploads (user_id,source_id,upload_id,run_id,asset_id,status,created_at) VALUES ('u','s','ticket','run',1,'pending','2026-01-01T00:00:00Z')");
    check($columns['retarget_allowed']['notnull'] === 1 && (string)$columns['retarget_allowed']['dflt_value'] === '0' && (int)$pdo->query('SELECT retarget_allowed FROM apc_uploads')->fetchColumn() === 0, 'F7: retarget_allowed NOT NULL DEFAULT false');
    try { $pdo->exec('UPDATE apc_uploads SET retarget_allowed=NULL'); throw new LogicException('NULL allowed'); } catch (PDOException) {}
    $repo = new OCA\ApplePhotosConnector\Db\InventoryRepository(new TestHarness\Connection($pdo));
    check($repo->getCurrentTarget('u','s',1) === null, 'F8: no implicit current from existing targets');
    $repo->setCurrentTarget('u','s',1,$two);
    check((int)$repo->getCurrentTarget('u','s',1)['id'] === $two, 'F9: explicit current returns exactly the selected target');
    $target('u','s',1,'historical');
    check((int)$repo->getCurrentTarget('u','s',1)['id'] === $two, 'F10: additional historical target does not alter current');
    foreach ([['v','s',2],['u','t',3],['u','s',4]] as [$u,$s,$a]) {
        $foreign = $target($u,$s,$a,'foreign-'.$a);
        try { $repo->setCurrentTarget('u','s',1,$foreign); throw new LogicException('Foreign target accepted'); } catch (InvalidArgumentException) {}
    }
    check((int)$repo->getCurrentTarget('u','s',1)['id'] === $two, 'F11: foreign user/source/asset targets rejected');
}
