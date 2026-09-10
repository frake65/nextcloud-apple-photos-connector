<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCA\ApplePhotosConnector\Db\AlbumMapRepository;
use OCP\IDBConnection;

final class AlbumSyncOrchestrator {
    public function __construct(private IDBConnection $db, private AlbumMapRepository $maps, private AlbumResolutionService $albums, private AlbumMembershipService $memberships) {}

    public function sync(string $sourceId, string $userId): array {
        $out=['albums_seen'=>0,'albums_created'=>0,'albums_reused'=>0,'folders_skipped'=>0,'memberships_seen'=>0,'memberships_created'=>0,'memberships_reused'=>0,'memberships_skipped_not_imported'=>0,'errors'=>[]];
        $q=$this->db->getQueryBuilder(); $q->select('*')->from('apc_source_albums')->where($q->expr()->eq('source_id',$q->createNamedParameter($sourceId)), $q->expr()->eq('user_id',$q->createNamedParameter($userId)));
        $albums=$q->executeQuery()->fetchAll();
        if (!$albums) { throw new \InvalidArgumentException('Source not found or has no inventoried albums'); }
        foreach ($albums as $album) {
            if (($album['kind'] ?? null) === 'folder') { $out['folders_skipped']++; continue; }
            $out['albums_seen']++;
            $key=AlbumIdentity::key($album['cloud_identifier']??null,(string)$album['local_identifier']);
            $old=$this->maps->find($userId,$sourceId,$key);
            try { $this->albums->resolve((int)$album['id'],$userId); $out[$old?'albums_reused':'albums_created']++; }
            catch (\Throwable $e) { $out['errors'][]=['type'=>'album','id'=>(int)$album['id'],'message'=>$e->getMessage()]; }
        }
        $q=$this->db->getQueryBuilder(); $q->select('*')->from('apc_album_memberships')->where($q->expr()->eq('source_id',$q->createNamedParameter($sourceId)), $q->expr()->eq('user_id',$q->createNamedParameter($userId)));
        foreach ($q->executeQuery()->fetchAll() as $membership) {
            $out['memberships_seen']++;
            $aq=$this->db->getQueryBuilder(); $aq->select('*')->from('apc_assets')->where($aq->expr()->eq('id',$aq->createNamedParameter((int)$membership['asset_id'])), $aq->expr()->eq('user_id',$aq->createNamedParameter($userId)));
            $asset=$aq->executeQuery()->fetch();
            if (!$asset || $asset['nextcloud_file_id']===null || !$asset['nextcloud_path']) { $out['memberships_skipped_not_imported']++; continue; }
            try { $r=$this->memberships->add((int)$membership['album_id'],(int)$membership['asset_id'],$userId); $out[$r['created_or_reused']==='created'?'memberships_created':'memberships_reused']++; }
            catch (\Throwable $e) { $out['errors'][]=['type'=>'membership','album_id'=>(int)$membership['album_id'],'asset_id'=>(int)$membership['asset_id'],'message'=>$e->getMessage()]; }
        }
        return $out;
    }
}
