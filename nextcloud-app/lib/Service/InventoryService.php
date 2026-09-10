<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Db\ImportRun;

class InventoryService {
    public function __construct(
        private InventoryRepository $repository,
        private AssetIdentity $identity,
        private InventoryValidator $validator,
        private UploadedFileLocator $files,
    ) {}

    public function ingest(string $user, mixed $source, mixed $assets, bool $retransferMissing = false): array {
        if ($user === '') { throw new \InvalidArgumentException('Authenticated user required'); }
        $seen = is_array($assets) && array_is_list($assets) ? count($assets) : 0;
        $run = ImportRun::start($user, $this->validator->sourceId($source), $seen);
        // Commit the single running row independently so an inventory rollback cannot erase it.
        $this->repository->transaction(fn () => $this->repository->insertRun($run));
        try {
            if (!is_array($source) || !is_array($assets)) {
                throw new \InvalidArgumentException('source object and assets array required');
            }
            [$source, $assets] = $this->validator->validate($source, $assets);
            return $this->process($user, $source, $assets, $run, $retransferMissing);
        } catch (\Throwable $error) {
            $errorCode = $error instanceof \InvalidArgumentException ? 'validation_error'
                : ($error instanceof \OCP\DB\Exception ? 'database_error' : 'processing_error');
            try {
                $this->repository->transaction(fn () => $this->repository->failRun($user, $run->runId, $seen, $errorCode));
            } catch (\Throwable) {
                // DB outage/process failures can leave running behind. Keep the original cause.
                error_log('Apple Photos Connector: failed to finalize import run ' . $run->runId);
            }
            throw new ImportRunFailure($run->runId, $error);
        }
    }

    private function process(string $user, array $source, array $assets, ImportRun $run, bool $retransferMissing): array {
        return $this->repository->transaction(function () use ($user, $source, $assets, $run, $retransferMissing): array {
            $now = (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))->format('Y-m-d\TH:i:s.u\Z');
            $sourceId = $source['source_id'];
            // A write precedes the asset read: concurrent inventories serialize on this source row.
            $this->repository->touchSource($user, $sourceId, $source['name'], $now);
            if ($this->repository->source($user, $sourceId) === null) {
                $this->repository->insertSource([
                    'user_id' => $user, 'source_id' => $sourceId, 'name' => $source['name'],
                    'created_at' => $source['created_at'] ?? $now, 'last_seen_at' => $now,
                ]);
            }
            $known = [];
            foreach ($this->repository->assets($user, $sourceId) as $row) {
                foreach ($this->identity->lookupKeys($row['cloud_identifier'], $row['local_identifier']) as $key) {
                    $known[$key] ??= $row;
                }
            }
            $response = [];
            $tickets = [];
            foreach ($assets as $asset) {
                $key = $this->identity->key($asset['cloud_identifier'], $asset['local_identifier']);
                $exists = array_key_exists($key, $known);
                if ($exists) {
                    $row = $known[$key];
                    $this->repository->touchAsset($user, $sourceId, (int)$row['id'], $now);
                } else {
                    $id = $this->repository->insertAsset($asset + [
                        'user_id' => $user, 'source_id' => $sourceId,
                        'first_seen_at' => $now, 'last_seen_at' => $now,
                    ]);
                    $row = $asset + ['id' => $id, 'nextcloud_file_id' => null];
                    foreach ($this->identity->lookupKeys($asset['cloud_identifier'], $asset['local_identifier']) as $lookupKey) {
                        if (!array_key_exists($lookupKey, $known)) { $known[$lookupKey] = $row; }
                    }
                }
                $current = $this->repository->getCurrentTarget($user, $sourceId, (int)$row['id']);
                $retarget = $current !== null && $retransferMissing && !$this->files->exists($user, $current['path']);
                $uploaded = $current !== null && !$retarget;
                $upload = null;
                if (!$uploaded) {
                    $id = (int)$row['id'];
                    if (!isset($tickets[$id])) {
                        $uploadId = ImportRun::start($user, $sourceId, 0)->runId;
                        $this->repository->insertUpload([
                            'upload_id' => $uploadId, 'run_id' => $run->runId, 'source_id' => $sourceId,
                            'user_id' => $user, 'asset_id' => $id, 'filename' => $asset['filename'], 'status' => 'pending',
                            'created_at' => $now,
                            'retarget_allowed' => $retarget, 'base_target_id' => $current['id'] ?? null,
                        ]);
                        $tickets[$id] = ['uploadId' => $uploadId, 'assetId' => (string)$id];
                    }
                    $upload = $tickets[$id];
                }
                $response[] = ['cloudIdentifier' => $asset['cloud_identifier'], 'state' => $uploaded ? 'known' : 'new', 'upload' => $upload];
            }
            $counts = array_count_values(array_column($response, 'state'));
            $summary = ['seen' => count($response), 'new' => $counts['new'] ?? 0, 'known' => $counts['known'] ?? 0];
            // Completion and all source/asset writes belong to exactly the same transaction.
            $this->repository->completeRun($user, $run->runId, $summary['seen'], $summary['new'], $summary['known']);
            return ['runId' => $run->runId, 'summary' => $summary, 'assets' => $response];
        });
    }
}
