<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Db\ImportRun;

class UploadTargetService {
    public function __construct(private InventoryRepository $repository, private UploadedFileLocator $files, private ?UploadTicketPolicy $policy = null) {}

    public static function validateFolder(mixed $folder): string {
        if (!is_string($folder) || $folder === '' || strlen($folder) > 1500 || !preg_match('//u', $folder)
            || preg_match('/[\\x00-\\x1f\\x7f\\\\]/', $folder)) {
            throw new \InvalidArgumentException('Invalid upload folder');
        }
        foreach (explode('/', $folder) as $part) {
            if ($part === '' || $part === '.' || $part === '..' || strlen($part) > 255) {
                throw new \InvalidArgumentException('Invalid upload folder');
            }
        }
        return $folder;
    }

    public function prepare(string $user, mixed $source, mixed $runId, mixed $uploadId, mixed $bytes, mixed $sha256, mixed $folder = null): array {
        $folder = self::validateFolder($folder ?? rtrim(UploadService::DIRECTORY, '/'));
        if (!is_string($source) || !is_string($runId) || !is_string($uploadId) || !is_int($bytes) || $bytes < 0
            || !is_string($sha256) || !preg_match('/^[0-9a-f]{64}$/D', $sha256)) {
            throw new \InvalidArgumentException('Source, run, upload, byte count and SHA-256 required');
        }
        $policy = $this->policy ?? UploadTicketPolicy::live();
        $this->repository->expirePendingTicket($user, $source, $runId, $uploadId, $policy);
        return $this->repository->transaction(function () use ($user, $source, $runId, $uploadId, $bytes, $sha256, $folder, $policy): array {
            $this->repository->lockSource($user, $source);
            [$ticket, $asset, $current] = $this->repository->uploadContext($user, $source, $runId, $uploadId, $policy);
            $assetId = (int)$asset['id'];
            $reconciled = $ticket['status'] === 'uploaded' || $current !== null ? null
                : $this->reconcileConfirmedContent($user, $source, $runId, $ticket, $asset, $bytes, $sha256);
            if ($reconciled !== null) { return $reconciled; }
            if ($current) { $this->checkIdentity($current, $bytes, $sha256); }
            if ($ticket['status'] === 'uploaded' || !InventoryRepository::sameTarget($current, $ticket['base_target_id'])) {
                // Another completion won, or this is a replay. Never reopen a finished generation.
                if ($ticket['target_id'] === null || !InventoryRepository::sameTarget($current, $ticket['target_id'])
                    || !$this->files->exists($user, $current['path'])) {
                    throw new \InvalidArgumentException('Upload already finalized or superseded');
                }
                $this->verifyPresent($user, $current, $bytes, $sha256);
                return $this->response($current, 'present');
            }
            if ($current && (!InventoryRepository::canRetarget($ticket) || $this->files->exists($user, $current['path']))) {
                throw new \InvalidArgumentException('Retarget no longer authorized');
            }
            // Keep live bindings and recoverable files across runs, but do not
            // let an inactive, missing reservation override a new destination.
            // Selection is read-only: create folders only for the chosen target.
            $target = null;
            foreach ($this->repository->uploads($user, $source) as $other) {
                if ((int)$other['asset_id'] !== $assetId || $other['target_id'] === null
                    || !InventoryRepository::sameTarget($current, $other['base_target_id'])) { continue; }
                $candidate = $this->repository->target($user, $source, $assetId, (int)$other['target_id']);
                $this->checkIdentity($candidate, $bytes, $sha256);
                $active = $other['status'] === 'pending' && !$policy->expired((string)$other['created_at']);
                if ($other['run_id'] !== $runId && !$active && dirname($candidate['path']) !== $folder) {
                    if (!$this->files->exists($user, $candidate['path'])) { continue; }
                    // A lost PUT/ACK may leave the original at the old path.
                    // Unknown identity must abort; proven foreign content is
                    // preserved but cannot pin this run to the old folder.
                    $actual = $this->files->identity($user, $candidate['path']);
                    if ($actual['bytes'] !== $bytes || !hash_equals($sha256, $actual['sha256'])) { continue; }
                }
                if (!$target || (int)$candidate['id'] > (int)$target['id']) { $target = $candidate; }
            }
            $filename = $ticket['filename'];
            $attempt = 0;
            if ($target) {
                $this->checkIdentity($target, $bytes, $sha256);
                $filename = $target['filename'];
                // The selected live/recoverable reservation keeps its destination.
                $folder = dirname($target['path']);
                if (!$this->files->exists($user, $target['path'])) {
                    $this->files->ensureFolder($user, $folder);
                    $this->bind($user, $ticket, (int)$target['id']);
                    return $this->response($target, 'missing');
                }
                $actual = $this->files->identity($user, $target['path']);
                if ($actual['bytes'] === $bytes && hash_equals($sha256, $actual['sha256'])) {
                    $this->bind($user, $ticket, (int)$target['id']);
                    return $this->response($target, 'present');
                }
                $attempt = (int)$target['attempt'] + 1;
            }
            for (; $attempt < 100; $attempt++) {
                $path = $folder . '/' . self::filename($filename, (string)$assetId, $attempt);
                if ($this->repository->targetPathReserved($user, $path) || $this->files->exists($user, $path)) { continue; }
                $this->files->ensureFolder($user, $folder);
                $values = ['user_id' => $user, 'source_id' => $source, 'asset_id' => $assetId, 'filename' => $filename,
                    'path' => $path, 'path_key' => hash('sha256', $path), 'attempt' => $attempt, 'bytes' => $bytes, 'sha256' => $sha256];
                $id = $this->repository->insertTarget($values);
                $this->bind($user, $ticket, $id);
                return $this->response($values, 'missing');
            }
            throw new \InvalidArgumentException('No free upload target');
        });
    }

    /** Atomically binds a new APC asset to a currently existing, confirmed file. */
    private function reconcileConfirmedContent(string $user, string $source, string $runId, array $ticket, array $asset, int $bytes, string $sha256): ?array {
        // Reconcile is for a genuinely new APC asset. Existing target history
        // continues through the established recovery state machine.
        if ($this->repository->getTargetsForAsset($user, $source, (int)$asset['id']) !== []) { return null; }
        foreach ($this->repository->contentIdentities()->confirmedTargetCandidates($user, $sha256, $bytes) as $candidate) {
            // Do not let a target confirmed moments ago by another asset in
            // this same run cascade through the run; older confirmed content
            // remains eligible for a genuinely new same-source asset.
            $runStarted = (string)($this->repository->run($user, $runId)['started_at'] ?? '');
            if ((string)$candidate['source_id'] === $source && (string)$candidate['confirmed_at'] >= $runStarted) { continue; }
            try {
                $verified = $this->files->withVerifiedFile($user, (string)$candidate['path'], function (array $actual, int $fileId) use ($bytes, $sha256): array {
                    if ($actual['bytes'] !== $bytes || !hash_equals($sha256, $actual['sha256'])) { throw new \InvalidArgumentException('Content candidate changed'); }
                    return ['fileId' => $fileId];
                });
            } catch (\Throwable) { continue; }
            $targetId = (int)$candidate['upload_target_id'];
            $this->repository->updateOwned('apc_assets', $user, 'id', $asset['id'], [
                'current_upload_target_id' => $targetId, 'nextcloud_file_id' => $verified['fileId'],
                'nextcloud_path' => $candidate['path'], 'uploaded_at' => ImportRun::now(),
            ]);
            $this->repository->updateOwned('apc_uploads', $user, 'upload_id', $ticket['upload_id'], [
                'target_id' => $targetId, 'status' => 'uploaded',
            ]);
            $uploaded = $failed = 0;
            foreach ($this->repository->uploads($user, $source) as $row) {
                if ($row['run_id'] === $runId) { $uploaded += (int)($row['status'] === 'uploaded'); $failed += (int)($row['status'] === 'failed'); }
            }
            $this->repository->updateOwned('apc_import_runs', $user, 'run_id', $runId, ['assets_uploaded' => $uploaded, 'assets_failed' => $failed]);
            return ['assetId' => (string)$asset['id'], 'path' => $candidate['path'], 'bytes' => $bytes, 'sha256' => $sha256, 'state' => 'contentAlreadyPresent'];
        }
        return null;
    }

    private function bind(string $user, array $ticket, int $targetId): void {
        $values = ['target_id' => $targetId];
        if ($ticket['status'] === 'failed') {
            // A successful prepare restarts this attempt. Protect the binding
            // from competing runs while the client performs PUT/confirmation.
            $values += ['status' => 'pending', 'created_at' => ImportRun::now()];
        }
        $this->repository->updateOwned('apc_uploads', $user, 'upload_id', $ticket['upload_id'], $values);
    }

    private function checkIdentity(array $target, int $bytes, string $sha256): void {
        if ((int)$target['bytes'] !== $bytes || !hash_equals($target['sha256'], $sha256)) {
            throw new \InvalidArgumentException('Original content changed; version handling is not supported');
        }
    }

    private function verifyPresent(string $user, array $target, int $bytes, string $sha256): void {
        $actual = $this->files->identity($user, $target['path']);
        if ($actual['bytes'] !== $bytes || !hash_equals($sha256, $actual['sha256'])) {
            throw new \InvalidArgumentException('Mapped file content changed');
        }
    }

    private function response(array $target, string $state): array {
        return ['assetId' => (string)$target['asset_id'], 'path' => $target['path'], 'bytes' => (int)$target['bytes'], 'sha256' => $target['sha256'], 'state' => $state];
    }

    public static function filename(?string $filename, string $assetId, int $attempt): string {
        if (!$filename || in_array($filename, ['.', '..'], true) || preg_match('/[\x00-\x1f\/\\\\]/', $filename)) {
            throw new \InvalidArgumentException('Invalid original filename');
        }
        if ($attempt === 0) { return $filename; }
        $dot = strrpos($filename, '.');
        $stem = $dot !== false && $dot > 0 ? substr($filename, 0, $dot) : $filename;
        $extension = $dot !== false && $dot > 0 ? substr($filename, $dot) : '';
        return $stem . '--apc-' . $assetId . ($attempt > 1 ? '-' . ($attempt - 1) : '') . $extension;
    }
}
