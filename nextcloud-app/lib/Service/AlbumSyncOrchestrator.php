<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\AlbumMapRepository;
use OCP\IDBConnection;

final class AlbumSyncOrchestrator {
    public function __construct(private IDBConnection $db, private AlbumMapRepository $maps, private AlbumResolutionService $albums, private AlbumMembershipService $memberships) {}

    public static function selectedAssetMatches(array $asset, array $selected): bool {
        return in_array((string)($asset['local_identifier'] ?? ''), $selected, true)
            || in_array((string)($asset['cloud_identifier'] ?? ''), $selected, true);
    }

    public static function selectedAlbumMatches(array $album, ?array $selected): bool {
        if ($selected === null) return true;
        $key=AlbumIdentity::key($album['cloud_identifier']??null,(string)$album['local_identifier']);
        return in_array($key,$selected,true);
    }

    public function sync(string $sourceId, string $userId, ?array $selectedAlbumKeys=null, ?array $selectedAssetIdentities=null): array {
        $out=['albums_seen'=>0,'albums_created'=>0,'albums_reused'=>0,'folders_skipped'=>0,'memberships_seen'=>0,'memberships_created'=>0,'memberships_reused'=>0,'memberships_skipped_not_imported'=>0,'errors'=>[]];
        $q=$this->db->getQueryBuilder(); $q->select('*')->from('apc_source_albums')->where($q->expr()->eq('source_id',$q->createNamedParameter($sourceId)), $q->expr()->eq('user_id',$q->createNamedParameter($userId)));
        $albums=$q->executeQuery()->fetchAll();
        if (!$albums) { throw new \InvalidArgumentException('Source not found or has no inventoried albums'); }
        foreach ($albums as $album) {
            if (($album['kind'] ?? null) === 'folder') { $out['folders_skipped']++; continue; }
            $albumKey=AlbumIdentity::key($album['cloud_identifier']??null,(string)$album['local_identifier']);
            if (!self::selectedAlbumMatches($album,$selectedAlbumKeys)) continue;
            if ($selectedAssetIdentities !== null && !$this->hasRelevantImportedMembership((int)$album['id'],$userId,$selectedAssetIdentities)) continue;
            $out['albums_seen']++;
            $key=$albumKey;
            $old=$this->maps->find($userId,$sourceId,$key);
            try { $this->albums->resolve((int)$album['id'],$userId); $out[$old?'albums_reused':'albums_created']++; }
            catch (\Throwable $e) { $out['errors'][]=['type'=>'album','id'=>(int)$album['id'],'message'=>$e->getMessage()]; }
        }
        $q=$this->db->getQueryBuilder(); $q->select('*')->from('apc_album_memberships')->where($q->expr()->eq('source_id',$q->createNamedParameter($sourceId)), $q->expr()->eq('user_id',$q->createNamedParameter($userId)));
        foreach ($q->executeQuery()->fetchAll() as $membership) {
            if ($selectedAlbumKeys !== null && !$this->albumIsSelected((int)$membership['album_id'],$selectedAlbumKeys,$albums)) continue;
            $out['memberships_seen']++;
            $aq=$this->db->getQueryBuilder(); $aq->select('*')->from('apc_assets')->where($aq->expr()->eq('id',$aq->createNamedParameter((int)$membership['asset_id'])), $aq->expr()->eq('user_id',$aq->createNamedParameter($userId)));
            $asset=$aq->executeQuery()->fetch();
            if (!$asset || $asset['nextcloud_file_id']===null || !$asset['nextcloud_path']) { $out['memberships_skipped_not_imported']++; continue; }
            if ($selectedAssetIdentities !== null && !self::selectedAssetMatches($asset,$selectedAssetIdentities)) continue;
            try { $r=$this->memberships->add((int)$membership['album_id'],(int)$membership['asset_id'],$userId); $out[$r['created_or_reused']==='created'?'memberships_created':'memberships_reused']++; }
            catch (\Throwable $e) { $out['errors'][]=['type'=>'membership','album_id'=>(int)$membership['album_id'],'asset_id'=>(int)$membership['asset_id'],'message'=>$e->getMessage()]; }
        }
        return $out;
    }

    private function albumIsSelected(int $albumId,array $keys,array $albums): bool {
        foreach($albums as $album) if((int)$album['id']===$albumId) return self::selectedAlbumMatches($album,$keys);
        return false;
    }

    private function hasRelevantImportedMembership(int $albumId,string $userId,array $selected): bool {
        $q=$this->db->getQueryBuilder(); $q->select('a.local_identifier','a.cloud_identifier','a.nextcloud_file_id','a.nextcloud_path')->from('apc_album_memberships','m')->innerJoin('m','apc_assets','a',$q->expr()->eq('a.id',$q->expr()->col('m.asset_id')))->where($q->expr()->eq('m.album_id',$q->createNamedParameter($albumId)),$q->expr()->eq('m.user_id',$q->createNamedParameter($userId)),$q->expr()->isNotNull('a.nextcloud_file_id'));
        foreach($q->executeQuery()->fetchAll() as $asset) if($asset['nextcloud_path'] && self::selectedAssetMatches($asset,$selected)) return true;
        return false;
    }
}
