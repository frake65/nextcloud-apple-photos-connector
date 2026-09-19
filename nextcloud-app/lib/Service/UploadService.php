<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Db\ImportRun;

class UploadService {
    public const DIRECTORY = 'Photos/Apple Photos Connector/';
    public function __construct(private InventoryRepository $repository, private UploadedFileLocator $files, private ?UploadTicketPolicy $policy = null) {}

    public function acknowledge(string $user, mixed $sourceId, mixed $runId, mixed $uploadId, mixed $status, mixed $path): array {
        foreach ([$sourceId, $runId, $uploadId] as $id) {
            if (!is_string($id) || !preg_match('/^[0-9a-f-]{36}$/D', $id)) { throw new \InvalidArgumentException('Invalid identifier'); }
        }
        if (!in_array($status, ['uploaded', 'failed'], true)) { throw new \InvalidArgumentException('Invalid upload status'); }
        $policy = $this->policy ?? UploadTicketPolicy::live();
        $this->repository->expirePendingTicket($user, $sourceId, $runId, $uploadId, $policy);
        return $this->repository->transaction(function () use ($user, $sourceId, $runId, $uploadId, $status, $path, $policy): array {
            $this->repository->lockSource($user, $sourceId);
            [$ticket, $asset, $current] = $this->repository->uploadContext($user, $sourceId, $runId, $uploadId, $policy);
            $target = $ticket['target_id'] === null ? null
                : $this->repository->target($user, $sourceId, (int)$asset['id'], (int)$ticket['target_id']);
            if ($ticket['status'] === 'uploaded') {
                // Replay refers to its own immutable target, never to today's current cache fields.
                if ($status !== 'uploaded' || !$target || $path !== $target['path']) {
                    throw new \InvalidArgumentException('Upload already finalized');
                }
            } elseif ($status === 'uploaded') {
                if (!is_string($path) || !$target || $target['path'] !== $path) {
                    throw new \InvalidArgumentException('Reserved upload target required');
                }
                $sameBase = InventoryRepository::sameTarget($current, $ticket['base_target_id']);
                $alreadyCurrent = InventoryRepository::sameTarget($current, $ticket['target_id']);
                if (!$sameBase && !$alreadyCurrent) { throw new \InvalidArgumentException('Upload superseded'); }
                if ($sameBase && $current && (!InventoryRepository::canRetarget($ticket)
                    || $this->files->exists($user, $current['path']))) {
                    throw new \InvalidArgumentException('Retarget no longer authorized');
                }
                $this->files->withVerifiedFile($user, $path, function (array $actual, int $fileId) use ($target, $asset, $user, $sourceId, $path, $uploadId, $alreadyCurrent): void {
                    if ($actual['bytes'] !== (int)$target['bytes'] || !hash_equals($target['sha256'], $actual['sha256'])) {
                        throw new \InvalidArgumentException('Uploaded content does not match original');
                    }
                    if (!$alreadyCurrent) {
                        $this->repository->setCurrentTarget($user, $sourceId, (int)$asset['id'], (int)$target['id']);
                        $this->repository->updateOwned('apc_assets', $user, 'id', $asset['id'], [
                            'nextcloud_file_id' => $fileId, 'nextcloud_path' => $path, 'uploaded_at' => ImportRun::now(),
                        ]);
                    }
                    $this->repository->updateOwned('apc_uploads', $user, 'upload_id', $uploadId, ['status' => 'uploaded']);
                    $this->repository->contentIdentities()->recordConfirmedTarget(
                        $user, $sourceId, (int)$asset['id'], $target, $fileId, ImportRun::now()
                    );
                });
            } else {
                $this->repository->updateOwned('apc_uploads', $user, 'upload_id', $uploadId, ['status' => 'failed']);
            }
            $uploaded = $failed = 0;
            foreach ($this->repository->uploads($user, $sourceId) as $row) {
                if ($row['run_id'] === $runId) {
                    $uploaded += (int)($row['status'] === 'uploaded');
                    $failed += (int)($row['status'] === 'failed');
                }
            }
            $this->repository->updateOwned('apc_import_runs', $user, 'run_id', $runId, ['assets_uploaded' => $uploaded, 'assets_failed' => $failed]);
            return ['runId' => $runId, 'uploadId' => $uploadId, 'status' => $status, 'summary' => ['uploaded' => $uploaded, 'failed' => $failed]];
        });
    }

}
