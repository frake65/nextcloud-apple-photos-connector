<?php
declare(strict_types=1);
final class FakeAlbumInfo { public function __construct(private int $id, private string $user='u'){} function getId(): int{return $this->id;} function getUserId(): string{return $this->user;} }
final class FakeAlbumMapper { public array $calls=[]; function create(string $u,string $n): FakeAlbumInfo{$this->calls[]=['create',$u,$n];return new FakeAlbumInfo(7,$u);} function get(int $id): ?FakeAlbumInfo{return $id===7?new FakeAlbumInfo(7):null;} function getForAlbumIdAndFileId(int $a,int $f): ?object{return in_array([$a,$f],$this->calls,true)?new stdClass:null;} function addFile(int $a,int $f,string $o):void{$this->calls[]=[$a,$f];} }
function adapterScenarios(OCA\ApplePhotosConnector\Db\AlbumMapRepository $maps): void {
    check(OCA\ApplePhotosConnector\Service\AlbumIdentity::key('c','l')==='cloud:c','cloud identity key');
    check(OCA\ApplePhotosConnector\Service\AlbumIdentity::key(null,'l')==='local:l','local identity key');
    $a=new FakeAlbumMapper(); $adapter=new OCA\ApplePhotosConnector\Service\NextcloudAlbumAdapter($maps,$a,'7.0.0');
    check($adapter->supportsVersion(),'Photos version guard');
    $row=$adapter->resolveOrCreateAlbum('u','s',1,['localIdentifier'=>'a','cloudIdentifier'=>null,'name'=>'Same','kind'=>'album']);
    check($row['nextcloud_album_id']===7,'mapping creates album through mapper');
    check($adapter->addFileMembership('u',7,9,'u')===true && count($a->calls)===2,'membership added once');
    check($adapter->addFileMembership('u',7,9,'u')===false && count($a->calls)===2,'existing membership is no-op');
    try{$adapter->addFileMembership('v',7,9,'u');check(false,'cross-user membership rejected');}catch(InvalidArgumentException){check(true,'cross-user membership rejected');}
    try{$adapter->resolveOrCreateAlbum('u','s',2,['localIdentifier'=>'f','name'=>'Folder','kind'=>'folder']);check(false,'folder rejected');}catch(InvalidArgumentException){check(true,'folder is not Photos album');}
}
