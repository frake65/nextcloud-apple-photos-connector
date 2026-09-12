<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;
use OCA\ApplePhotosConnector\Db\AlbumMapRepository;

final class NextcloudAlbumAdapter {
    private const PHOTOS_VERSION = '7.0.0';
    public function __construct(private AlbumMapRepository $maps, private object $albumMapper, private string $photosVersion) {}
    public function supportsVersion(): bool {
        foreach(['create','get','getForAlbumIdAndFileId','addFile'] as $method) if(!method_exists($this->albumMapper,$method)) return false;
        return $this->photosVersion === self::PHOTOS_VERSION;
    }
    private function guard(): void { if(!$this->supportsVersion()) throw new \RuntimeException('Unsupported Photos integration; expected Photos 7.0.0 with AlbumMapper'); }
    public function findAlbum(string $userId,string $sourceId,array $album): ?array {
        if(($album['kind']??'album')==='folder') return null;
        $key=AlbumIdentity::key($album['cloudIdentifier']??null,$album['localIdentifier']); return $this->maps->find($userId,$sourceId,$key);
    }
    public function resolveOrCreateAlbum(string $userId,string $sourceId,int $sourceAlbumId,array $album): array {
        if(($album['kind']??'album')==='folder') throw new \InvalidArgumentException('Folders are not Photos albums');
        $this->guard();
        $key=AlbumIdentity::key($album['cloudIdentifier']??null,$album['localIdentifier']); $existing=$this->maps->find($userId,$sourceId,$key);
        if($existing){
            if($existing['nextcloud_album_id'] === null) throw new \RuntimeException('Album mapping is pending; refusing to create a second Photos album');
            $info=$this->albumMapper->get((int)$existing['nextcloud_album_id']);
            if($info!==null && $info->getUserId()===$userId) return $existing;
            // The old Photos album is either gone or belongs to another user.
            // Create a new album for this user and repair only this user's APC row.
            $replacement=$this->albumMapper->create($userId,(string)$album['name']);
            $replacementId=(int)$replacement->getId();
            if (!$this->maps->rebindNextcloudAlbumId((int)$existing['id'],$userId,$sourceId,$key,(int)$existing['nextcloud_album_id'],$replacementId)) {
                throw new \RuntimeException('Album mapping changed while repairing it');
            }
            $existing['nextcloud_album_id']=$replacementId;
            return $existing;
        }
        // Reserve the logical identity before the external Photos write. A failed
        // mapping write can therefore never cause an indistinguishable retry.
        $mapId=$this->maps->insert(['user_id'=>$userId,'source_id'=>$sourceId,'source_album_id'=>$sourceAlbumId,'source_album_key'=>$key,'nextcloud_album_id'=>null,'display_name'=>(string)$album['name'],'created_at'=>gmdate('c'),'updated_at'=>gmdate('c')]);
        $info=$this->albumMapper->create($userId,(string)$album['name']); $id=(int)$info->getId();
        $this->maps->setNextcloudAlbumId($mapId,$id);
        return ['id'=>$mapId,'nextcloud_album_id'=>$id,'source_album_key'=>$key];
    }
    public function addFileMembership(string $userId,int $albumId,int $fileId,string $owner): bool {
        $this->guard(); if($owner!==$userId) throw new \InvalidArgumentException('Cross-user membership');
        if($this->albumMapper->getForAlbumIdAndFileId($albumId,$fileId)!==null) return false;
        $this->albumMapper->addFile($albumId,$fileId,$owner);
        return true;
    }
}
