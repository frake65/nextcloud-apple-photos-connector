<?php
declare(strict_types=1);
final class FakeAlbumInfo { public function __construct(private int $id, private string $user='u'){} function getId(): int{return $this->id;} function getUserId(): string{return $this->user;} }
final class FakeAlbumMapper { public array $calls=[]; public array $albums=[]; private int $next=7; function create(string $u,string $n): FakeAlbumInfo{$id=$this->next++;$this->albums[$id]=new FakeAlbumInfo($id,$u);$this->calls[]=['create',$u,$n,$id];return $this->albums[$id];} function get(int $id): ?FakeAlbumInfo{return $this->albums[$id]??null;} function getForAlbumIdAndFileId(int $a,int $f): ?object{return in_array([$a,$f],$this->calls,true)?new stdClass:null;} function addFile(int $a,int $f,string $o):void{$this->calls[]=[$a,$f];} }
function adapterScenarios(OCA\ApplePhotosConnector\Db\AlbumMapRepository $maps): void {
    check(OCA\ApplePhotosConnector\Service\AlbumIdentity::key('c','l')==='cloud:c','cloud identity key');
    check(OCA\ApplePhotosConnector\Service\AlbumIdentity::key(null,'l')==='local:l','local identity key');
    $nc35=new OCA\ApplePhotosConnector\Service\NextcloudAlbumAdapter($maps,new FakeAlbumMapper(),'8.0.0');
    check($nc35->supportsVersion(),'Photos 8.0.0 / Nextcloud 35 version guard');
    $a=new FakeAlbumMapper(); $adapter=new OCA\ApplePhotosConnector\Service\NextcloudAlbumAdapter($maps,$a,'7.0.0');
    check($adapter->supportsVersion(),'Photos version guard');
    $row=$adapter->resolveOrCreateAlbum('u','s',1,['localIdentifier'=>'a','cloudIdentifier'=>null,'name'=>'Same','kind'=>'album']);
    check($row['nextcloud_album_id']===7,'mapping creates album through mapper');
    check($adapter->addFileMembership('u',7,9,'u')===true && count($a->calls)===2,'membership added once');
    check($adapter->addFileMembership('u',7,9,'u')===false && count($a->calls)===2,'existing membership is no-op');
    try{$adapter->addFileMembership('v',7,9,'u');check(false,'cross-user membership rejected');}catch(InvalidArgumentException){check(true,'cross-user membership rejected');}
    try{$adapter->resolveOrCreateAlbum('u','s',2,['localIdentifier'=>'f','name'=>'Folder','kind'=>'folder']);check(false,'folder rejected');}catch(InvalidArgumentException){check(true,'folder is not Photos album');}

    $orphan=$maps->insert(['user_id'=>'u','source_id'=>'s','source_album_id'=>10,'source_album_key'=>'local:orphan','nextcloud_album_id'=>999,'display_name'=>'Orphan','created_at'=>'old','updated_at'=>'old']);
    $repaired=$adapter->resolveOrCreateAlbum('u','s',10,['localIdentifier'=>'orphan','name'=>'Orphan','kind'=>'album']);
    check($repaired['nextcloud_album_id']===8,'orphan mapping creates replacement');
    check($maps->find('u','s','local:orphan')['nextcloud_album_id']===8,'orphan mapping is rebound');
    $before=count($a->calls); $again=$adapter->resolveOrCreateAlbum('u','s',10,['localIdentifier'=>'orphan','name'=>'Orphan','kind'=>'album']);
    check($again['nextcloud_album_id']===8 && count($a->calls)===$before,'repaired mapping is idempotent');

    $foreignId=42; $a->albums[$foreignId]=new FakeAlbumInfo($foreignId,'other');
    $maps->insert(['user_id'=>'u','source_id'=>'s','source_album_id'=>11,'source_album_key'=>'local:foreign','nextcloud_album_id'=>$foreignId,'display_name'=>'Foreign','created_at'=>'old','updated_at'=>'old']);
    $foreignRepair=$adapter->resolveOrCreateAlbum('u','s',11,['localIdentifier'=>'foreign','name'=>'Foreign','kind'=>'album']);
    check($foreignRepair['nextcloud_album_id']===9,'foreign mapping creates own replacement');
    check($a->albums[$foreignId]->getUserId()==='other','foreign album owner is unchanged');
    check($maps->find('u','s','local:foreign')['nextcloud_album_id']===9,'foreign mapping is rebound safely');

    $maps->insert(['user_id'=>'u','source_id'=>'s','source_album_id'=>12,'source_album_key'=>'local:pending','nextcloud_album_id'=>null,'display_name'=>'Pending','created_at'=>'old','updated_at'=>'old']);
    try{$adapter->resolveOrCreateAlbum('u','s',12,['localIdentifier'=>'pending','name'=>'Pending','kind'=>'album']);check(false,'pending mapping remains protected');}catch(RuntimeException $e){check($e->getMessage()==='Album mapping is pending; refusing to create a second Photos album','pending mapping remains protected');}
}
