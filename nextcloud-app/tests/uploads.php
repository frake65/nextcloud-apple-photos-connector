<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Service\UploadedFileLocator;
use OCA\ApplePhotosConnector\Service\UploadService;

class TestFiles extends UploadedFileLocator {
    public array $files = [];
    public array $contents = [];
    public bool $readFailure = false;
    public array $folders = [];
    public bool $folderFailure = false;
    public function __construct() {}
    public function ensureFolder(string $user, string $folder): void {
        if ($this->folderFailure) { throw new RuntimeException('injected folder failure'); }
        $this->folders[$folder] = true;
    }
    public function withVerifiedFile(string $user, string $path, callable $work): mixed {
        return $work($this->identity($user, $path), $this->fileId($user, $path));
    }
    public function exists(string $user, string $path): bool { return isset($this->files[$path]); }
    public function identity(string $user, string $path): array {
        $this->fileId($user, $path);
        if ($this->readFailure) { throw new RuntimeException('injected target read failure'); }
        $data = $this->contents[$path] ?? 'ORIGINAL';
        return ['bytes' => strlen($data), 'sha256' => hash('sha256', $data)];
    }
    public function fileId(string $user, string $path): int {
        if (!isset($this->files[$path])) { throw new InvalidArgumentException('File not found'); }
        return $this->files[$path];
    }
}

class FailingUploadRepository extends \OCA\ApplePhotosConnector\Db\InventoryRepository {
    public function updateOwned(string $table, string $user, string $key, string|int $id, array $values): void {
        parent::updateOwned($table, $user, $key, $id, $values);
        if ($table === 'apc_import_runs') { throw new RuntimeException('injected upload counter failure'); }
    }
}

function uploadRollbackScenario(\OCP\IDBConnection $db): void {
    $repo = new FailingUploadRepository($db);
    $user = 'upload-rollback-' . bin2hex(random_bytes(4));
    $source = ['sourceId' => '950e8400-e29b-41d4-a716-446655440000', 'name' => 'Rollback'];
    $files = new TestFiles();
    $inventory = new \OCA\ApplePhotosConnector\Service\InventoryService($repo, new \OCA\ApplePhotosConnector\Service\AssetIdentity(), new \OCA\ApplePhotosConnector\Service\InventoryValidator(), $files);
    $reply = $inventory->ingest($user, $source, [['localIdentifier' => 'one', 'filename' => 'test.jpg', 'mediaType' => 'image']]);
    $target = (new \OCA\ApplePhotosConnector\Service\UploadTargetService($repo, $files))->prepare($user, $source['sourceId'], $reply['runId'], $reply['assets'][0]['upload']['uploadId'], 8, hash('sha256', 'ORIGINAL'));
    $files->files[$target['path']] = 501;
    $service = new UploadService($repo, $files);
    try {
        $service->acknowledge($user, $source['sourceId'], $reply['runId'], $reply['assets'][0]['upload']['uploadId'], 'uploaded', 'Photos/Apple Photos Connector/test.jpg');
        throw new LogicException('Expected rollback');
    } catch (RuntimeException $error) {
        check($error->getMessage() === 'injected upload counter failure', 'upload counter failure reaches caller');
    }
    check($repo->assets($user, $source['sourceId'])[0]['nextcloud_file_id'] === null
        && $repo->uploads($user, $source['sourceId'])[0]['status'] === 'pending'
        && (int)$repo->run($user, $reply['runId'])['assets_uploaded'] === 0, 'upload mapping, ticket and counters roll back atomically');
}

function uploadScenarios(\OCA\ApplePhotosConnector\Db\InventoryRepository $repo): void {
    $user = 'upload-' . bin2hex(random_bytes(4));
    $source = ['sourceId' => '850e8400-e29b-41d4-a716-446655440000', 'name' => 'Uploads'];
    $asset = ['localIdentifier' => 'one', 'cloudIdentifier' => 'upload-one', 'filename' => 'test.jpg', 'mediaType' => 'image'];
    $files = new TestFiles();
    $inventory = new \OCA\ApplePhotosConnector\Service\InventoryService($repo, new \OCA\ApplePhotosConnector\Service\AssetIdentity(), new \OCA\ApplePhotosConnector\Service\InventoryValidator(), $files);
    $service = new UploadService($repo, $files);
    $first = $inventory->ingest($user, $source, [$asset]);
    $ticket = $first['assets'][0]['upload'];
    check($first['assets'][0]['state'] === 'new' && $ticket !== null, 'new asset requests upload');
    $service->acknowledge($user, $source['sourceId'], $first['runId'], $ticket['uploadId'], 'failed', null);
    check((int)$repo->run($user, $first['runId'])['assets_failed'] === 1 && $repo->assets($user, $source['sourceId'])[0]['nextcloud_file_id'] === null, 'failed upload retains unmapped asset and failure counter');
    $retry = $inventory->ingest($user, $source, [$asset]);
    check($retry['assets'][0]['state'] === 'new' && count($repo->assets($user, $source['sourceId'])) === 1, 'failed upload requested in later run without duplicating asset');
    $retryTicket = $retry['assets'][0]['upload'];
    foreach ([[$user . '-other', 'Photos/Apple Photos Connector/test.jpg'], [$user, '../test.jpg'], [$user, 'Photos/Apple Photos Connector/wrong.jpg']] as [$owner, $path]) {
        try {
            $service->acknowledge($owner, $source['sourceId'], $retry['runId'], $retryTicket['uploadId'], 'uploaded', $path);
            throw new LogicException('Invalid acknowledgement accepted');
        } catch (InvalidArgumentException) {}
    }
    check($repo->assets($user, $source['sourceId'])[0]['nextcloud_file_id'] === null, 'foreign user and invalid paths cannot map asset');
    $path = 'Photos/Apple Photos Connector/test.jpg';
    (new \OCA\ApplePhotosConnector\Service\UploadTargetService($repo, $files))->prepare($user, $source['sourceId'], $retry['runId'], $retryTicket['uploadId'], 8, hash('sha256', 'ORIGINAL'));
    $files->files[$path] = 501;
    $ack = $service->acknowledge($user, $source['sourceId'], $retry['runId'], $retryTicket['uploadId'], 'uploaded', $path);
    $again = $service->acknowledge($user, $source['sourceId'], $retry['runId'], $retryTicket['uploadId'], 'uploaded', $path);
    check($ack === $again && $ack['summary'] === ['uploaded' => 1, 'failed' => 0], 'upload confirmation is idempotent with correct counters');
    $known = $inventory->ingest($user, $source, [$asset]);
    check($known['assets'][0]['state'] === 'known' && $known['assets'][0]['upload'] === null, 'successful upload is never requested again');
    unset($files->files[$path]);
    $missing = $inventory->ingest($user, $source, [$asset], true);
    check($missing['assets'][0]['state'] === 'new' && $missing['assets'][0]['upload'] !== null,
        'retransfer flag requests a new upload when the previously mapped file is missing');
    $missingTarget = (new \OCA\ApplePhotosConnector\Service\UploadTargetService($repo, $files))->prepare(
        $user, $source['sourceId'], $missing['runId'], $missing['assets'][0]['upload']['uploadId'],
        8, hash('sha256', 'ORIGINAL'));
    check($missingTarget['state'] === 'missing' && dirname($missingTarget['path']) === dirname($path) && $missingTarget['path'] !== $path,
        'missing current reserves a new target in the same folder while preserving history');
    $stillKnown = $inventory->ingest($user, $source, [$asset]);
    check($stillKnown['assets'][0]['state'] === 'known' && $stillKnown['assets'][0]['upload'] === null,
        'retransfer flag remains opt-in and disabled behavior stays additive');
    $before = $repo->assets($user, $source['sourceId']);
    $inventory->ingest($user, $source, []);
    check($before === $repo->assets($user, $source['sourceId']) && !array_key_exists($path, $files->files), 'empty follow-up scan leaves file reference and file untouched');
    // Late failure cannot remove an existing successful mapping.
    $service->acknowledge($user, $source['sourceId'], $first['runId'], $ticket['uploadId'], 'failed', null);
    check($before === $repo->assets($user, $source['sourceId']), 'late failure never clears successful file mapping');
    $collision = $inventory->ingest($user, $source, [array_replace($asset, ['cloudIdentifier' => 'upload-two'])]);
    $collisionTicket = $collision['assets'][0]['upload'];
    $collisionPath = 'Photos/Apple Photos Connector/test--apc-' . $collisionTicket['assetId'] . '-1.jpg';
    $files->files['Photos/Apple Photos Connector/test--apc-' . $collisionTicket['assetId'] . '.jpg'] = 503;
    (new \OCA\ApplePhotosConnector\Service\UploadTargetService($repo, $files))->prepare($user, $source['sourceId'], $collision['runId'], $collisionTicket['uploadId'], 8, hash('sha256', 'ORIGINAL'));
    try {
        $service->acknowledge($user, $source['sourceId'], $collision['runId'], $collisionTicket['uploadId'], 'uploaded', $collisionPath);
        throw new LogicException('Missing file accepted');
    } catch (InvalidArgumentException) {}
    check((int)$repo->run($user, $collision['runId'])['assets_uploaded'] === 0, 'missing Nextcloud file cannot be confirmed');
    $files->files[$collisionPath] = 502;
    $service->acknowledge($user, $source['sourceId'], $collision['runId'], $collisionTicket['uploadId'], 'uploaded', $collisionPath);
    check(!array_key_exists($path, $files->files) && count($repo->assets($user, $source['sourceId'])) === 2, 'deterministic collision path accepted without changing original mapping');
}
