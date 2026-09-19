<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Db;

use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\IDBConnection;

/** User-scoped content identity index. It records evidence only; inventory matching does not use it. */
final class ContentIdentityRepository {
    public function __construct(private IDBConnection $db) {}

    /** Persist evidence only for an upload target acknowledged as uploaded after server-side byte verification. */
    public function recordConfirmedTarget(string $user, string $source, int $assetId, array $target, ?int $fileId, string $confirmedAt): void {
        $targetId = $target['id'] ?? null;
        if (!is_int($targetId) && !(is_string($targetId) && ctype_digit($targetId))) {
            throw new \InvalidArgumentException('Invalid confirmed content target');
        }
        $targetId = (int)$targetId;
        $persistedTarget = $this->confirmedTarget($user, $source, $assetId, $targetId);
        if ($persistedTarget === null) { throw new \InvalidArgumentException('Confirmed upload target required'); }
        $target = $persistedTarget;
        $sha256 = $target['sha256'] ?? null;
        $bytes = $target['bytes'] ?? null;
        $validBytes = is_int($bytes) || (is_string($bytes) && ctype_digit($bytes));
        if ($user === '' || $source === '' || $assetId <= 0 || ($fileId !== null && $fileId <= 0) || !$validBytes
            || (int)$bytes < 0 || !is_string($sha256) || !preg_match('/^[0-9a-f]{64}$/D', $sha256)) {
            throw new \InvalidArgumentException('Invalid confirmed content target');
        }
        $bytes = (int)$bytes;
        $identity = $this->findRow($user, $sha256, $bytes);
        if ($identity === null) {
            try {
                $this->insert('apc_content_identities', [
                    'user_id' => $user, 'sha256' => $sha256, 'bytes' => $bytes, 'created_at' => $confirmedAt,
                ]);
            } catch (\Throwable $error) {
                // A unique-key race is safe if the other transaction created the same user-scoped key.
                if ($this->findRow($user, $sha256, $bytes) === null) { throw $error; }
            }
            $identity = $this->findRow($user, $sha256, $bytes);
        }
        if ($identity === null) { throw new \RuntimeException('Content identity insert was not visible'); }
        if ($this->targetReference($targetId) !== null) { return; }
        $this->insert('apc_content_targets', [
            'content_id' => (int)$identity['id'], 'user_id' => $user, 'source_id' => $source,
            'asset_id' => $assetId, 'upload_target_id' => $targetId, 'nextcloud_file_id' => $fileId,
            'confirmed_at' => $confirmedAt,
        ]);
    }

    /** Queryable by a later reconcile phase. Never call from current inventory new/known matching. */
    public function find(string $user, string $sha256, int $bytes): ?array {
        $identity = $this->findRow($user, $sha256, $bytes);
        if ($identity === null) { return null; }
        $qb = $this->db->getQueryBuilder();
        $qb->select('id')->from('apc_content_targets')->where(
            $qb->expr()->eq('content_id', $qb->createNamedParameter((int)$identity['id'], IQueryBuilder::PARAM_INT)),
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user))
        );
        $result = $qb->executeQuery();
        try { return $result->fetch() ? $identity : null; }
        finally { $result->closeCursor(); }
    }

    private function findRow(string $user, string $sha256, int $bytes): ?array {
        if ($user === '' || !preg_match('/^[0-9a-f]{64}$/D', $sha256) || $bytes < 0) { return null; }
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_content_identities')->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('sha256', $qb->createNamedParameter($sha256)),
            $qb->expr()->eq('bytes', $qb->createNamedParameter($bytes, IQueryBuilder::PARAM_INT))
        );
        $result = $qb->executeQuery();
        try { return $result->fetch() ?: null; }
        finally { $result->closeCursor(); }
    }

    /** All Nextcloud targets evidenced by this user's exact content key. */
    public function confirmedTargets(string $user, string $sha256, int $bytes): array {
        $identity = $this->findRow($user, $sha256, $bytes);
        if ($identity === null) { return []; }
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_content_targets')->where(
            $qb->expr()->eq('content_id', $qb->createNamedParameter((int)$identity['id'], IQueryBuilder::PARAM_INT)),
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user))
        );
        $result = $qb->executeQuery();
        try { return $result->fetchAllAssociative(); }
        finally { $result->closeCursor(); }
    }

    /** Candidate target rows, ordered deterministically for the reconcile slow path. */
    public function confirmedTargetCandidates(string $user, string $sha256, int $bytes): array {
        $identity = $this->findRow($user, $sha256, $bytes);
        if ($identity === null) { return []; }
        $qb = $this->db->getQueryBuilder();
        $qb->select('ct.upload_target_id', 'ct.source_id', 'ct.asset_id', 'ct.confirmed_at', 'ut.path', 'ut.bytes', 'ut.sha256', 'ct.nextcloud_file_id')
            ->from('apc_content_targets', 'ct')
            ->innerJoin('ct', 'apc_upload_targets', 'ut', $qb->expr()->eq('ct.upload_target_id', 'ut.id'))
            ->where(
                $qb->expr()->eq('ct.content_id', $qb->createNamedParameter((int)$identity['id'], IQueryBuilder::PARAM_INT)),
                $qb->expr()->eq('ct.user_id', $qb->createNamedParameter($user))
            )
            ->orderBy('ct.upload_target_id', 'ASC');
        $result = $qb->executeQuery();
        try { return $result->fetchAllAssociative(); }
        finally { $result->closeCursor(); }
    }

    /** Backfill only targets referenced by an uploaded ticket; no filesystem reads or hashing are performed. */
    public function backfillConfirmedTargets(): int {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_upload_targets');
        $result = $qb->executeQuery();
        try { $targets = $result->fetchAllAssociative(); }
        finally { $result->closeCursor(); }
        $count = 0;
        foreach ($targets as $target) {
            $before = $this->targetReference((int)$target['id']);
            $ticket = $this->confirmationTicket($target);
            if ($ticket === null) { continue; }
            $this->recordConfirmedTarget((string)$target['user_id'], (string)$target['source_id'], (int)$target['asset_id'], $target,
                $this->confirmedFileId((int)$target['id']), $this->confirmationTime((int)$target['id'], $ticket));
            if ($before === null) { $count++; }
        }
        return $count;
    }

    private function confirmationTicket(array $target): ?array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_uploads')->where(
            $qb->expr()->eq('user_id', $qb->createNamedParameter($target['user_id'])),
            $qb->expr()->eq('source_id', $qb->createNamedParameter($target['source_id'])),
            $qb->expr()->eq('asset_id', $qb->createNamedParameter((int)$target['asset_id'], IQueryBuilder::PARAM_INT)),
            $qb->expr()->eq('target_id', $qb->createNamedParameter((int)$target['id'], IQueryBuilder::PARAM_INT)),
            $qb->expr()->eq('status', $qb->createNamedParameter('uploaded'))
        );
        $result = $qb->executeQuery();
        try { return $result->fetch() ?: null; }
        finally { $result->closeCursor(); }
    }

    private function confirmedTarget(string $user, string $source, int $assetId, int $targetId): ?array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_upload_targets')->where(
            $qb->expr()->eq('id', $qb->createNamedParameter($targetId, IQueryBuilder::PARAM_INT)),
            $qb->expr()->eq('user_id', $qb->createNamedParameter($user)),
            $qb->expr()->eq('source_id', $qb->createNamedParameter($source)),
            $qb->expr()->eq('asset_id', $qb->createNamedParameter($assetId, IQueryBuilder::PARAM_INT))
        );
        $result = $qb->executeQuery();
        try { $target = $result->fetch() ?: null; }
        finally { $result->closeCursor(); }
        if ($target === null || $this->confirmationTicket($target) === null) { return null; }
        return $target;
    }

    private function confirmedFileId(int $targetId): ?int {
        $qb = $this->db->getQueryBuilder();
        $qb->select('nextcloud_file_id')->from('apc_assets')->where(
            $qb->expr()->eq('current_upload_target_id', $qb->createNamedParameter($targetId, IQueryBuilder::PARAM_INT))
        );
        $result = $qb->executeQuery();
        try { $row = $result->fetch(); return $row && $row['nextcloud_file_id'] !== null ? (int)$row['nextcloud_file_id'] : null; }
        finally { $result->closeCursor(); }
    }

    private function confirmationTime(int $targetId, array $ticket): string {
        $qb = $this->db->getQueryBuilder();
        $qb->select('uploaded_at')->from('apc_assets')->where(
            $qb->expr()->eq('current_upload_target_id', $qb->createNamedParameter($targetId, IQueryBuilder::PARAM_INT))
        );
        $result = $qb->executeQuery();
        try { $row = $result->fetch(); return (string)($row['uploaded_at'] ?? $ticket['created_at'] ?? gmdate('Y-m-d\TH:i:s\Z')); }
        finally { $result->closeCursor(); }
    }

    private function targetReference(int $targetId): ?array {
        $qb = $this->db->getQueryBuilder();
        $qb->select('*')->from('apc_content_targets')->where(
            $qb->expr()->eq('upload_target_id', $qb->createNamedParameter($targetId, IQueryBuilder::PARAM_INT))
        );
        $result = $qb->executeQuery();
        try { return $result->fetch() ?: null; }
        finally { $result->closeCursor(); }
    }

    private function insert(string $table, array $row): void {
        $qb = $this->db->getQueryBuilder();
        $values = [];
        foreach ($row as $key => $value) {
            $type = $value === null ? IQueryBuilder::PARAM_NULL : (is_int($value) ? IQueryBuilder::PARAM_INT : IQueryBuilder::PARAM_STR);
            $values[$key] = $qb->createNamedParameter($value, $type);
        }
        $qb->insert($table)->values($values)->executeStatement();
    }
}
