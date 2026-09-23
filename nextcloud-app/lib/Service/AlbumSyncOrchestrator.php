<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCP\IDBConnection;
use OCA\ApplePhotosConnector\Db\AlbumMapRepository;

final class AlbumSyncOrchestrator {
    public function __construct(private IDBConnection $db, private AlbumMapRepository $maps, private AlbumResolutionService $albums, private AlbumMembershipService $memberships) {}

    public static function selectedAssetMatches(array $asset, array $selected): bool {
        $local = (string)($asset['local_identifier'] ?? '');
        $cloud = (string)($asset['cloud_identifier'] ?? '');
        return in_array($local, $selected, true)
            || in_array($cloud, $selected, true)
            || ($local !== '' && in_array('local:'.$local, $selected, true))
            || ($cloud !== '' && in_array('cloud:'.$cloud, $selected, true));
    }

    public static function selectedAlbumMatches(array $album, ?array $selected): bool {
        if ($selected === null) return true;
        $key = AlbumIdentity::key($album['cloud_identifier'] ?? null, (string)$album['local_identifier']);
        return in_array($key, $selected, true)
            || in_array((string)$album['local_identifier'], $selected, true)
            || (($album['cloud_identifier'] ?? null) !== null && in_array((string)$album['cloud_identifier'], $selected, true));
    }

    public function sync(string $sourceId, string $userId, ?array $selectedAlbumKeys = null, ?array $selectedAssetIdentities = null): array {
        $out = ['albums_seen'=>0,'albums_created'=>0,'albums_reused'=>0,'folders_skipped'=>0,'memberships_seen'=>0,'memberships_created'=>0,'memberships_reused'=>0,'memberships_skipped_not_imported'=>0,'errors'=>[]];
        $context = ['source_id' => $sourceId];
        $albums = $this->stage('album.sync.source_albums.lookup', $context, function () use ($sourceId, $userId): array {
            $q = $this->db->getQueryBuilder();
            $q->select('*')->from('apc_source_albums')->where(
                $q->expr()->eq('source_id', $q->createNamedParameter($sourceId)),
                $q->expr()->eq('user_id', $q->createNamedParameter($userId)),
            );
            return $q->executeQuery()->fetchAll();
        });
        if (!$albums) return $out;

        // Determine and log the entire effective set before entering Photos or file operations.
        $selectedAlbums = [];
        foreach ($albums as $album) {
            if (($album['kind'] ?? null) === 'folder') {
                $out['folders_skipped']++;
                continue;
            }
            $explicitlySelected = $selectedAlbumKeys !== null && self::selectedAlbumMatches($album, $selectedAlbumKeys);
            $assetRelated = ($selectedAlbumKeys === null || $selectedAlbumKeys === [])
                && $selectedAssetIdentities !== null
                && $this->hasRelevantImportedMembership((int)$album['id'], $userId, $selectedAssetIdentities);
            $unfiltered = $selectedAlbumKeys === null && $selectedAssetIdentities === null;
            if ($explicitlySelected || $assetRelated || $unfiltered) $selectedAlbums[] = $album;
        }
        $effectiveIds = array_map(static fn (array $album): int => (int)$album['id'], $selectedAlbums);
        $prefixCounts = ['cloud' => 0, 'local' => 0, 'other' => 0];
        foreach ($selectedAssetIdentities ?? [] as $identity) {
            $kind = str_starts_with($identity, 'cloud:') ? 'cloud' : (str_starts_with($identity, 'local:') ? 'local' : 'other');
            $prefixCounts[$kind]++;
        }
        $this->debug('album.sync.selection source='.$sourceId
            .' selected_album_ids='.count($selectedAlbumKeys ?? [])
            .' selected_asset_ids='.count($selectedAssetIdentities ?? [])
            .' selected_asset_prefixes='.json_encode($prefixCounts)
            .' effective_apc_album_ids='.implode(',', $effectiveIds));

        $effectiveAlbumIds = [];
        $albumResolutionFailures = [];
        foreach ($selectedAlbums as $album) {
            $sourceAlbumId = (int)$album['id'];
            $effectiveAlbumIds[$sourceAlbumId] = true;
            $this->debug('album.sync.album.resolve.enter source_album='.$sourceAlbumId);
            $out['albums_seen']++;
            try {
                $resolved = $this->albums->resolve($sourceAlbumId, $userId);
                $out[$resolved['created_or_reused'] === 'created' ? 'albums_created' : 'albums_reused']++;
                $this->debug('album.sync.album.resolve.success source_album='.$sourceAlbumId.' photos_action='.$resolved['created_or_reused']);
            } catch (\Throwable $e) {
                $this->debug('album.sync.album.resolve.failure source_album='.$sourceAlbumId.' exception='.get_class($e));
                $out['errors'][] = ['type'=>'album','id'=>$sourceAlbumId,'message'=>$this->failureDetail($e)];
                $albumResolutionFailures[$sourceAlbumId] = true;
            }
        }

        $this->debug('album.sync.memberships.scan.enter source='.$sourceId.' effective_apc_album_ids='.implode(',', array_keys($effectiveAlbumIds)));
        $q = $this->db->getQueryBuilder();
        $q->select('*')->from('apc_album_memberships')->where(
            $q->expr()->eq('source_id', $q->createNamedParameter($sourceId)),
            $q->expr()->eq('user_id', $q->createNamedParameter($userId)),
        );
        $sourceMemberships = $this->stage('album.sync.apc_memberships.lookup', $context, fn () => $q->executeQuery()->fetchAll());
        foreach ($sourceMemberships as $membership) {
            $sourceAlbumId = (int)$membership['album_id'];
            if (!isset($effectiveAlbumIds[$sourceAlbumId])) continue;
            $assetId = (int)$membership['asset_id'];
            $out['memberships_seen']++;
            $aq = $this->db->getQueryBuilder();
            $aq->select('*')->from('apc_assets')->where(
                $aq->expr()->eq('id', $aq->createNamedParameter($assetId)),
                $aq->expr()->eq('user_id', $aq->createNamedParameter($userId)),
            );
            $asset = $this->stage('album.sync.asset.resolve', $context + ['apc_album_id' => $sourceAlbumId, 'apc_asset_id' => $assetId], fn () => $aq->executeQuery()->fetch());
            if (!$asset || $asset['nextcloud_file_id'] === null || !$asset['nextcloud_path']) {
                $out['memberships_skipped_not_imported']++;
                $this->debug('album.sync.asset.resolve.result apc_asset_id='.$assetId.' imported=no');
                continue;
            }
            $this->debug('album.sync.asset.resolve.result apc_asset_id='.$assetId.' imported=yes nextcloud_file_id='.(int)$asset['nextcloud_file_id'].' path_present=yes');
            $this->debug('album.sync.membership.create.enter apc_album_id='.$sourceAlbumId.' apc_asset_id='.$assetId);
            try {
                $r = $this->memberships->add($sourceAlbumId, $assetId, $userId);
                $out[$r['created_or_reused'] === 'created' ? 'memberships_created' : 'memberships_reused']++;
                $this->debug('album.sync.membership.create.result apc_album_id='.$sourceAlbumId.' apc_asset_id='.$assetId.' result='.$r['created_or_reused']);
                if (isset($albumResolutionFailures[$sourceAlbumId])) {
                    $albumAction = $r['album_created_or_reused'];
                    $out[$albumAction === 'created' ? 'albums_created' : 'albums_reused']++;
                    $out['errors'] = array_values(array_filter($out['errors'], static fn (array $error): bool => !($error['type'] === 'album' && $error['id'] === $sourceAlbumId)));
                    unset($albumResolutionFailures[$sourceAlbumId]);
                    $this->debug('album.sync.album.resolve.recovered source_album='.$sourceAlbumId.' photos_action='.$albumAction);
                }
            } catch (\Throwable $e) {
                $this->debug('album.sync.membership.create.failure apc_album_id='.$sourceAlbumId.' apc_asset_id='.$assetId.' exception='.get_class($e));
                $out['errors'][] = ['type'=>'membership','album_id'=>$sourceAlbumId,'asset_id'=>$assetId,'message'=>$this->failureDetail($e)];
            }
        }
        return $out;
    }

    private function hasRelevantImportedMembership(int $albumId, string $userId, array $selected): bool {
        $context = ['apc_album_id' => $albumId];
        $assets = $this->stage('album.sync.selection.memberships.lookup', $context, function () use ($albumId, $userId): array {
            $q = $this->db->getQueryBuilder();
            $q->select('a.local_identifier', 'a.cloud_identifier', 'a.nextcloud_file_id', 'a.nextcloud_path')
                ->from('apc_album_memberships', 'm')
                // Nextcloud's IExpressionBuilder has no col(); eq accepts a column expression on both sides.
                ->innerJoin('m', 'apc_assets', 'a', $q->expr()->eq('a.id', 'm.asset_id'))
                ->where(
                    $q->expr()->eq('m.album_id', $q->createNamedParameter($albumId)),
                    $q->expr()->eq('m.user_id', $q->createNamedParameter($userId)),
                    $q->expr()->isNotNull('a.nextcloud_file_id'),
                );
            return $q->executeQuery()->fetchAll();
        });
        foreach ($assets as $asset) {
            if ($asset['nextcloud_path'] && self::selectedAssetMatches($asset, $selected)) return true;
        }
        return false;
    }

    private function stage(string $stage, array $context, callable $operation): mixed {
        $this->debug($stage.'.start '.json_encode($context, JSON_UNESCAPED_SLASHES));
        try {
            $result = $operation();
            $this->debug($stage.'.success');
            return $result;
        } catch (\Throwable $e) {
            $this->debug($stage.'.failure exception='.get_class($e));
            throw AlbumSyncDiagnosticException::wrap($stage, $e, $context);
        }
    }

    private function failureDetail(\Throwable $error): string {
        $diagnostic = $error instanceof AlbumSyncDiagnosticException ? $error : null;
        $cause = $diagnostic?->getPrevious() ?? $error;
        $stage = $diagnostic?->stage ?? 'album.sync.unclassified';
        if (!defined('OC_DEBUG') || !OC_DEBUG) return $cause->getMessage();
        return $stage.' ['.get_class($cause).']: '.$cause->getMessage();
    }

    private function debug(string $message): void {
        if (defined('OC_DEBUG') && OC_DEBUG && class_exists('OC') && isset(\OC::$server)) {
            try { \OC::$server->getLogger()->debug('Apple Photos Connector: '.$message, ['app' => 'apple_photos_connector']); } catch (\Throwable) {}
        }
    }
}
