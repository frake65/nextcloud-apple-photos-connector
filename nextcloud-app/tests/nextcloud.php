<?php
declare(strict_types=1);
// Run ONLY in a disposable, installed Nextcloud instance with this app enabled.
$root = getenv('NEXTCLOUD_ROOT');
if (!$root || getenv('APC_TEST_DATABASE') !== 'disposable') {
    fwrite(STDERR, "Set NEXTCLOUD_ROOT and APC_TEST_DATABASE=disposable for an isolated Nextcloud test instance.\n");
    exit(1);
}
require $root . '/lib/base.php';
require __DIR__ . '/bootstrap.php';
require __DIR__ . '/scenarios.php';
require __DIR__ . '/import-runs.php';
require __DIR__ . '/uploads.php';
require __DIR__ . '/recovery.php';
$db = \OCP\Server::get(\OCP\IDBConnection::class);
scenarios(new OCA\ApplePhotosConnector\Db\InventoryRepository($db));
runScenarios(new OCA\ApplePhotosConnector\Db\InventoryRepository($db));
runFailureScenarios($db);
uploadScenarios(new OCA\ApplePhotosConnector\Db\InventoryRepository($db));
uploadRollbackScenario($db);
recoveryScenarios(new OCA\ApplePhotosConnector\Db\InventoryRepository($db));
echo "Nextcloud repository integration scenarios passed. Test rows remain in the disposable database.\n";
