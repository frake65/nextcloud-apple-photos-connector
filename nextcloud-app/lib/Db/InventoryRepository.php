<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Db;

use OCP\IDBConnection;
use OCP\DB\QueryBuilder\IQueryBuilder;
use OCA\ApplePhotosConnector\Service\UploadTicketPolicy;

/** All reads/writes are scoped to the authenticated user and logical source. */
class InventoryRepository {
    public function __construct(private IDBConnection $db) {}

    public function contentIdentities(): ContentIdentityRepository { return new ContentIdentityRepository($this->db); }

    public function transaction(callable $work): mixed {
        $this->db->beginTransaction();
        try {
            $result = $work();
            $this->db->commit();
            return $result;
        } catch (\Throwable $error) {
            try { $this->db->rollBack(); }
            catch (\Throwable) { error_log('Apple Photos Connector: inventory transaction rollback could not be confirmed'); }
            throw $error;
        }
    }

    public function source(string $user, string $source): ?array {
        return $this->rows('apc_sources', $user, $source)[0] ?? null;
    }

    public function assets(string $user, string $source): array {
        return $this->rows('apc_assets', $user, $source);
    }

    public function runs(string $user, string $source): array {
        return $this->rows('apc_import_runs', $user, $source);
    }

    public function run(string $user, string $runId): ?array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_import_runs')->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('run_id', $qb->createNamedParameter($runId))
        );
        $result = $qb->executeQuery();
        try { return $result->fetchAllAssociative()[0] ?? null; }
        finally { $result->closeCursor(); }
    }

    public function insertRun(ImportRun $run): void { $this->insert('apc_import_runs', $run->toRow()); }

    public function completeRun(string $user, string $runId, int $seen, int $new, int $known): void {
        if ($this->finishRun($user, $runId, ImportRun::COMPLETED, $seen, $new, $known, null) !== 1) {
            throw new \RuntimeException('Running import run not found');
        }
    }

    public function failRun(string $user, string $runId, int $seen, string $errorCode): void {
        // Never overwrite a completed run after an ambiguous/lost commit acknowledgement.
        $this->finishRun($user, $runId, ImportRun::FAILED, $seen, 0, 0, $errorCode);
    }

    private function finishRun(string $user, string $runId, string $status, int $seen, int $new, int $known, ?string $errorCode): int {
        $qb = $this->db->getQueryBuilder();
        $qb->update('apc_import_runs')
            ->set('status', $qb->createNamedParameter($status))
            ->set('completed_at', $qb->createNamedParameter(ImportRun::now()))
            ->set('assets_seen', $qb->createNamedParameter($seen, IQueryBuilder::PARAM_INT))
            ->set('assets_new', $qb->createNamedParameter($new, IQueryBuilder::PARAM_INT))
            ->set('assets_known', $qb->createNamedParameter($known, IQueryBuilder::PARAM_INT))
            ->set('error_code', $qb->createNamedParameter($errorCode, $errorCode === null ? IQueryBuilder::PARAM_NULL : IQueryBuilder::PARAM_STR))
            ->where(
                $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
                $qb->expr()->eq('run_id', $qb->createNamedParameter($runId)),
                $qb->expr()->eq('status', $qb->createNamedParameter(ImportRun::RUNNING))
            );
        return $qb->executeStatement();
    }

    private function rows(string $table, string $user, string $source): array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from($table)->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('source_id', $qb->createNamedParameter($source))
        );
        $result = $qb->executeQuery();
        try { return $result->fetchAllAssociative(); }
        finally { $result->closeCursor(); }
    }

    public function insertSource(array $row): void { $this->insert('apc_sources', $row); }
    public function insertAsset(array $row): int {
        $this->insert('apc_assets', $row);
        return (int)$this->db->lastInsertId('apc_assets');
    }

    public function uploads(string $user, string $source): array { return $this->rows('apc_uploads', $user, $source); }
    public function insertUpload(array $row): void { $this->insert('apc_uploads', $row); }
    public function targets(string $user, string $source): array { return $this->rows('apc_upload_targets', $user, $source); }
    public function getTargetsForAsset(string $user, string $source, int $assetId): array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_upload_targets')->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('source_id', $qb->createNamedParameter($source)),
            $qb->expr()->eq('asset_id', $qb->createNamedParameter($assetId, IQueryBuilder::PARAM_INT))
        );
        $result = $qb->executeQuery();
        try { return $result->fetchAllAssociative(); } finally { $result->closeCursor(); }
    }
    public function getCurrentTarget(string $user, string $source, int $assetId): ?array {
        $asset = $this->asset($user, $source, $assetId);
        if (!$asset || $asset['current_upload_target_id'] === null) { return null; }
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_upload_targets')->where(
            $qb->expr()->eq('id', $qb->createNamedParameter((int)$asset['current_upload_target_id'], IQueryBuilder::PARAM_INT)),
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user))
        );
        $result = $qb->executeQuery();
        try { $target = $result->fetch(); if ($target !== false) { return $target; } }
        finally { $result->closeCursor(); }
        throw new \RuntimeException('Invalid current target ownership');
    }
    public function setCurrentTarget(string $user, string $source, int $assetId, int $targetId): void {
        $asset = $this->asset($user, $source, $assetId);
        $valid = $asset && array_reduce($this->getTargetsForAsset($user, $source, $assetId), fn(bool $ok, array $target): bool => $ok || (int)$target['id'] === $targetId, false);
        if (!$valid) { throw new \InvalidArgumentException('Target does not belong to asset'); }
        $qb = $this->db->getQueryBuilder();
        $qb->update('apc_assets')->set('current_upload_target_id', $qb->createNamedParameter($targetId, IQueryBuilder::PARAM_INT))
            ->where($qb->expr()->eq('user_id', $qb->createNamedParameter($user)), $qb->expr()->eq('source_id', $qb->createNamedParameter($source)), $qb->expr()->eq('id', $qb->createNamedParameter($assetId, IQueryBuilder::PARAM_INT)))->executeStatement();
    }
    public function insertTarget(array $row): int {
        $this->insert('apc_upload_targets', $row);
        return (int)$this->db->lastInsertId('apc_upload_targets');
    }
    public function asset(string $user, string $source, int $assetId): ?array {
        foreach ($this->assets($user, $source) as $asset) { if ((int)$asset['id'] === $assetId) { return $asset; } }
        return null;
    }

    public function target(string $user, string $source, int $assetId, int $targetId): array {
        foreach ($this->getTargetsForAsset($user, $source, $assetId) as $target) {
            if ((int)$target['id'] === $targetId) { return $target; }
        }
        throw new \InvalidArgumentException('Target does not belong to asset');
    }

    /** Must be called inside the source-locked transaction. */
    public function uploadContext(string $user, string $source, string $runId, string $uploadId, ?UploadTicketPolicy $policy = null): array {
        $run = $this->run($user, $runId);
        if (!$run || $run['source_id'] !== $source || $run['status'] !== 'completed') {
            throw new \InvalidArgumentException('Completed inventory required');
        }
        foreach ($this->uploads($user, $source) as $ticket) {
            if ($ticket['upload_id'] === $uploadId && $ticket['run_id'] === $runId) {
                $asset = $this->asset($user, $source, (int)$ticket['asset_id']);
                if (!$asset) { throw new \InvalidArgumentException('Asset unavailable'); }
                if ($ticket['status'] === UploadTicketPolicy::EXPIRED) { throw new \InvalidArgumentException('Upload ticket expired'); }
                return [$ticket, $asset, $this->getCurrentTarget($user, $source, (int)$asset['id'])];
            }
        }
        throw new \InvalidArgumentException('Upload was not requested');
    }

    public function expirePendingTicket(string $user, string $source, string $runId, string $uploadId, UploadTicketPolicy $policy): bool {
        return (bool)$this->transaction(function () use ($user, $source, $runId, $uploadId, $policy): int {
            foreach ($this->uploads($user, $source) as $ticket) {
                if ($ticket['upload_id'] !== $uploadId || $ticket['run_id'] !== $runId) { continue; }
                if ($ticket['status'] !== 'pending' || !$policy->expired((string)$ticket['created_at'])) { return 0; }
                $this->updateOwned('apc_uploads', $user, 'upload_id', $uploadId, ['status' => UploadTicketPolicy::EXPIRED]);
                return 1;
            }
            return 0;
        });
    }

    public static function sameTarget(?array $current, mixed $id): bool {
        return $current === null ? $id === null : ($id !== null && (int)$current['id'] === (int)$id);
    }

    public static function canRetarget(array $ticket): bool {
        return in_array($ticket['retarget_allowed'], [true, 1, '1'], true);
    }

    public function targetPathReserved(string $user, string $path): bool {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_upload_targets')->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('path_key', $qb->createNamedParameter(hash('sha256', $path)))
        );
        $result = $qb->executeQuery();
        try { return $result->fetchAllAssociative() !== []; }
        finally { $result->closeCursor(); }
    }

    /** Serialize upload acknowledgements with inventories using the same source row. */
    public function lockSource(string $user, string $source): void {
        $qb = $this->db->getQueryBuilder();
        $qb->update('apc_sources')->set('source_id', $qb->createNamedParameter($source))->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('source_id', $qb->createNamedParameter($source))
        )->executeStatement();
    }

    public function updateOwned(string $table, string $user, string $key, string|int $id, array $values): void {
        if (!in_array($table, ['apc_assets', 'apc_uploads', 'apc_import_runs', 'apc_upload_targets'], true)) { throw new \LogicException('Invalid table'); }
        $qb = $this->db->getQueryBuilder();
        $qb->update($table);
        foreach ($values as $column => $value) {
            $qb->set($column, $qb->createNamedParameter($value, $value === null ? IQueryBuilder::PARAM_NULL : (is_bool($value) ? IQueryBuilder::PARAM_BOOL : IQueryBuilder::PARAM_STR)));
        }
        $qb->where($qb->expr()->eq('user_id', $qb->createNamedParameter($user)), $qb->expr()->eq($key, $qb->createNamedParameter($id)))->executeStatement();
    }

    private function insert(string $table, array $row): void {
        $qb = $this->db->getQueryBuilder();
        $values = [];
        foreach ($row as $key => $value) {
            $values[$key] = $qb->createNamedParameter($value, $value === null ? IQueryBuilder::PARAM_NULL : (is_bool($value) ? IQueryBuilder::PARAM_BOOL : IQueryBuilder::PARAM_STR));
        }
        $qb->insert($table)->values($values)->executeStatement();
    }

    /** Updating the source row also serializes inventories for this source until commit. */
    public function touchSource(string $user, string $source, string $name, string $now): void {
        $qb = $this->db->getQueryBuilder();
        $qb->update('apc_sources')->set('name', $qb->createNamedParameter($name))
            ->set('last_seen_at', $qb->createNamedParameter($now))->where(
                $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
                $qb->expr()->eq('source_id', $qb->createNamedParameter($source))
            )->executeStatement();
    }

    public function touchAsset(string $user, string $source, int $id, string $now): void {
        $qb = $this->db->getQueryBuilder();
        $qb->update('apc_assets')->set('last_seen_at', $qb->createNamedParameter($now))->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('source_id', $qb->createNamedParameter($source)),
            $qb->expr()->eq('id', $qb->createNamedParameter($id, IQueryBuilder::PARAM_INT))
        )->executeStatement();
    }
}
