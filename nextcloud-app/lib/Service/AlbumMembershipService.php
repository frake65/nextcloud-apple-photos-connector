<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\AlbumMapRepository;
use OCP\IDBConnection;
use OCP\App\IAppManager;
use OCP\Files\IRootFolder;
use OCA\Photos\Album\AlbumMapper;

class AlbumMembershipService {
    public function __construct(private IDBConnection $db, private AlbumMapRepository $maps, private AlbumMapper $albumMapper, private IAppManager $appManager, private IRootFolder $root) {}

    public function add(int $sourceAlbumId, int $assetId, string $userId): array {
        $context = ['apc_album_id' => $sourceAlbumId, 'apc_asset_id' => $assetId];
        $album = $this->stage('album.sync.source_album.resolve', $context, function () use ($sourceAlbumId, $userId): ?array {
            $q = $this->db->getQueryBuilder();
            $q->select('*')->from('apc_source_albums')->where($q->expr()->eq('id', $q->createNamedParameter($sourceAlbumId)), $q->expr()->eq('user_id', $q->createNamedParameter($userId)));
            return $q->executeQuery()->fetch() ?: null;
        });
        if (!$album || ($album['kind'] ?? null) !== 'album') throw new \InvalidArgumentException('Source album not found, not owned by user, or is not an album');
        $sourceId = (string)$album['source_id'];

        $source = $this->stage('album.sync.source.resolve', $context, function () use ($sourceId, $userId): ?array {
            $q = $this->db->getQueryBuilder();
            $q->select('*')->from('apc_sources')->where($q->expr()->eq('source_id', $q->createNamedParameter($sourceId)), $q->expr()->eq('user_id', $q->createNamedParameter($userId)));
            return $q->executeQuery()->fetch() ?: null;
        });
        if (!$source) throw new \InvalidArgumentException('Source not found or not owned by user');

        $asset = $this->stage('album.sync.asset.mapping.lookup', $context, function () use ($assetId, $userId): ?array {
            $q = $this->db->getQueryBuilder();
            $q->select('*')->from('apc_assets')->where($q->expr()->eq('id', $q->createNamedParameter($assetId)), $q->expr()->eq('user_id', $q->createNamedParameter($userId)));
            return $q->executeQuery()->fetch() ?: null;
        });
        if (!$asset || (string)$asset['source_id'] !== $sourceId || $asset['nextcloud_file_id'] === null || !$asset['nextcloud_path']) throw new \InvalidArgumentException('Asset is not imported for this source/user');

        $adapter = new NextcloudAlbumAdapter($this->maps, $this->albumMapper, $this->appManager->getAppVersion('photos'));
        $resolved = $adapter->resolveOrCreateAlbum($userId, $sourceId, (int)$album['id'], [
            'localIdentifier' => $album['local_identifier'], 'cloudIdentifier' => $album['cloud_identifier'] ?? null,
            'name' => $album['name'], 'kind' => 'album',
        ]);
        $this->debug('album.sync.asset.resolve.enter apc_asset_id='.$assetId.' imported_file_id='.(int)$asset['nextcloud_file_id'].' path_present=yes');
        $fileId = $this->stage('album.sync.asset.resolve', $context + ['photos_album_id' => (int)$resolved['nextcloud_album_id'], 'expected_file_id' => (int)$asset['nextcloud_file_id']], fn () => (int)$this->root->getUserFolder($userId)->get((string)$asset['nextcloud_path'])->getId());
        $this->debug('album.sync.asset.resolve.result apc_asset_id='.$assetId.' resolved_file_id='.$fileId.' expected_file_id='.(int)$asset['nextcloud_file_id']);
        if ($fileId !== (int)$asset['nextcloud_file_id']) throw new \InvalidArgumentException('Imported file mapping is inconsistent');

        $photosAlbumId = (int)$resolved['nextcloud_album_id'];
        $this->debug('album.sync.membership.create.enter apc_album_id='.$sourceAlbumId.' apc_asset_id='.$assetId.' photos_album_id='.$photosAlbumId.' file_id='.$fileId);
        $created = $adapter->addFileMembership($userId, $photosAlbumId, $fileId, $userId);
        return ['album_id' => $photosAlbumId, 'file_id' => $fileId, 'created_or_reused' => $created ? 'created' : 'reused', 'album_created_or_reused' => $resolved['photos_action']];
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

    private function debug(string $message): void {
        if (defined('OC_DEBUG') && OC_DEBUG && class_exists('OC') && isset(\OC::$server)) {
            try { \OC::$server->getLogger()->debug('Apple Photos Connector: '.$message, ['app' => 'apple_photos_connector']); } catch (\Throwable) {}
        }
    }
}
