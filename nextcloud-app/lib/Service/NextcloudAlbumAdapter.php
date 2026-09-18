<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\AlbumMapRepository;

final class NextcloudAlbumAdapter {
    private const SUPPORTED_PHOTOS_VERSIONS = ['7.0.0', '8.0.0'];

    public function __construct(private AlbumMapRepository $maps, private object $albumMapper, private string $photosVersion) {}

    public function supportsVersion(): bool {
        foreach (['create', 'get', 'getForAlbumIdAndFileId', 'addFile'] as $method) {
            if (!method_exists($this->albumMapper, $method)) return false;
        }
        return in_array($this->photosVersion, self::SUPPORTED_PHOTOS_VERSIONS, true);
    }

    private function guard(): void {
        if (!$this->supportsVersion()) throw new \RuntimeException('Unsupported Photos integration; expected Photos 7.0.0 or 8.0.0 with AlbumMapper');
    }

    public function findAlbum(string $userId, string $sourceId, array $album): ?array {
        if (($album['kind'] ?? 'album') === 'folder') return null;
        $key = AlbumIdentity::key($album['cloudIdentifier'] ?? null, $album['localIdentifier']);
        return $this->maps->find($userId, $sourceId, $key);
    }

    public function resolveOrCreateAlbum(string $userId, string $sourceId, int $sourceAlbumId, array $album): array {
        if (($album['kind'] ?? 'album') === 'folder') throw new \InvalidArgumentException('Folders are not Photos albums');
        $this->guard();
        $key = AlbumIdentity::key($album['cloudIdentifier'] ?? null, $album['localIdentifier']);
        $context = ['source_id' => $sourceId, 'source_album_id' => $sourceAlbumId];
        $existing = $this->stage('album.sync.mapping.lookup', $context, fn () => $this->maps->find($userId, $sourceId, $key));
        $this->debug('album.sync.mapping.lookup.result source_album_id='.$sourceAlbumId.' found='.($existing ? 'yes' : 'no').' mapped_photos_album_id='.($existing['nextcloud_album_id'] ?? 'none'));

        if ($existing) {
            if ($existing['nextcloud_album_id'] === null) throw new \RuntimeException('Album mapping is pending; refusing to create a second Photos album');
            $oldId = (int)$existing['nextcloud_album_id'];
            $info = $this->stage('album.sync.photos.lookup', $context + ['apc_mapping_id' => (int)$existing['id'], 'photos_album_id' => $oldId], fn () => $this->albumMapper->get($oldId));
            $ownerMatches = $info !== null && $info->getUserId() === $userId;
            $this->debug('album.sync.photos.lookup.result source_album_id='.$sourceAlbumId.' photos_album_id='.$oldId.' result='.($info === null ? 'null' : 'found').' owner_match='.($ownerMatches ? 'yes' : 'no'));
            if ($ownerMatches) return $existing + ['photos_action' => 'reused'];

            $this->debug('album.sync.photos.create.enter source_album_id='.$sourceAlbumId.' old_photos_album_id='.$oldId);
            $replacement = $this->stage('album.sync.photos.create', $context + ['apc_mapping_id' => (int)$existing['id'], 'old_photos_album_id' => $oldId], fn () => $this->albumMapper->create($userId, (string)$album['name']));
            $replacementId = (int)$replacement->getId();
            $this->debug('album.sync.photos.create.result source_album_id='.$sourceAlbumId.' new_photos_album_id='.$replacementId);

            $this->debug('album.sync.mapping.rebind.enter source_album_id='.$sourceAlbumId.' apc_mapping_id='.(int)$existing['id'].' old_photos_album_id='.$oldId.' new_photos_album_id='.$replacementId);
            $rebound = $this->stage('album.sync.mapping.rebind', $context + ['apc_mapping_id' => (int)$existing['id'], 'old_photos_album_id' => $oldId, 'new_photos_album_id' => $replacementId], fn () => $this->maps->rebindNextcloudAlbumId((int)$existing['id'], $userId, $sourceId, $key, $oldId, $replacementId));
            if (!$rebound) throw new AlbumSyncDiagnosticException('album.sync.mapping.rebind', new \RuntimeException('Album mapping changed while repairing it'), $context + ['apc_mapping_id' => (int)$existing['id'], 'old_photos_album_id' => $oldId, 'new_photos_album_id' => $replacementId]);
            $existing['nextcloud_album_id'] = $replacementId;
            $existing['photos_action'] = 'created';
            return $existing;
        }

        $mapId = $this->stage('album.sync.mapping.reserve', $context, fn () => $this->maps->insert([
            'user_id' => $userId, 'source_id' => $sourceId, 'source_album_id' => $sourceAlbumId,
            'source_album_key' => $key, 'nextcloud_album_id' => null,
            'display_name' => (string)$album['name'], 'created_at' => gmdate('c'), 'updated_at' => gmdate('c'),
        ]));
        $this->debug('album.sync.mapping.reserved source_album_id='.$sourceAlbumId.' apc_mapping_id='.$mapId);
        $info = $this->stage('album.sync.photos.create', $context + ['apc_mapping_id' => $mapId], fn () => $this->albumMapper->create($userId, (string)$album['name']));
        $id = (int)$info->getId();
        $this->debug('album.sync.photos.create.result source_album_id='.$sourceAlbumId.' new_photos_album_id='.$id);
        $this->stage('album.sync.mapping.assign', $context + ['apc_mapping_id' => $mapId, 'new_photos_album_id' => $id], fn () => $this->maps->setNextcloudAlbumId($mapId, $id));
        return ['id' => $mapId, 'nextcloud_album_id' => $id, 'source_album_key' => $key, 'photos_action' => 'created'];
    }

    public function addFileMembership(string $userId, int $albumId, int $fileId, string $owner): bool {
        $context = ['photos_album_id' => $albumId, 'file_id' => $fileId];
        $this->guard();
        if ($owner !== $userId) throw new \InvalidArgumentException('Cross-user membership');
        $existing = $this->stage('album.sync.membership.lookup', $context, fn () => $this->albumMapper->getForAlbumIdAndFileId($albumId, $fileId)) !== null;
        $this->debug('album.sync.membership.lookup.result photos_album_id='.$albumId.' file_id='.$fileId.' found='.($existing ? 'yes' : 'no'));
        if ($existing) return false;
        $this->debug('album.sync.membership.create.enter photos_album_id='.$albumId.' file_id='.$fileId);
        $this->stage('album.sync.membership.create', $context, fn () => $this->albumMapper->addFile($albumId, $fileId, $owner));
        $this->debug('album.sync.membership.create.result photos_album_id='.$albumId.' file_id='.$fileId.' created=yes');
        return true;
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
