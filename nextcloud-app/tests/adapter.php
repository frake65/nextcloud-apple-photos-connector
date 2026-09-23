<?php
declare(strict_types=1);
final class FakeAlbumInfo extends \OCA\Photos\Album\AlbumInfo { public function __construct(int $id, string $user='u'){parent::__construct($id,$user);} }
final class FakeAlbumMapper implements \OCA\Photos\Album\AlbumMapper { public array $calls=[]; public array $albums=[]; public array $memberships=[]; public int $next=7; public int $createFailures=0; public int $membershipAddFailures=0; function create(string $u,string $n,string $location='',?string $filters=null): \OCA\Photos\Album\AlbumInfo{if($this->createFailures>0){$this->createFailures--;throw new RuntimeException('transient Photos create failure');}$id=$this->next++;$this->albums[$id]=new FakeAlbumInfo($id,$u);$this->calls[]=['create',$u,$n,$id];return $this->albums[$id];} function get(int $id): ?\OCA\Photos\Album\AlbumInfo{return $this->albums[$id]??null;} function getForAlbumIdAndFileId(int $a,int $f): ?\OCA\Photos\Album\AlbumFile{return isset($this->memberships["$a:$f"])?new \OCA\Photos\Album\AlbumFile:null;} function addFile(int $a,int $f,string $o):void{if($this->membershipAddFailures>0){$this->membershipAddFailures--;throw new RuntimeException('synthetic membership add failure');}$this->memberships["$a:$f"]=true;$this->calls[]=['add',$a,$f,$o];} }
final class FakeAlbumRoot implements \OCP\Files\IRootFolder { public function __construct(private int|array $ids){} function getUserFolder(string $u): object{return new class($this->ids){function __construct(private int|array $ids){} function get(string $p):object{$id=is_array($this->ids)?($this->ids[$p]??0):$this->ids;return new class($id){function __construct(private int $id){} function getId():int{return $this->id;}};}};} }
final class FakePhotosVersion implements \OCP\App\IAppManager { function getAppVersion(string $app):string{return '7.0.0';} }
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
    // Reproduce an out-of-band album deletion while APC retains both its mapping and membership history.
    unset($a->albums[7]); $a->memberships['7:9']=true;
    $restored=$adapter->resolveOrCreateAlbum('u','s',1,['localIdentifier'=>'a','cloudIdentifier'=>null,'name'=>'Same','kind'=>'album']);
    check($restored['nextcloud_album_id']===8 && $maps->find('u','s','local:a')['nextcloud_album_id']===8,'deleted Photos album is recreated and APC mapping rebound');
    check($restored['nextcloud_album_id']!==7 && $a->albums[8]->getUserId()==='u','replacement album gets a new ID and remains user-owned');
    unset($a->memberships['7:9']);
    check($adapter->addFileMembership('u',8,9,'u')===true,'membership is restored against recreated album');
    check($adapter->addFileMembership('u',8,9,'u')===false,'repeated sync does not duplicate restored membership');
    try{$adapter->addFileMembership('v',7,9,'u');check(false,'cross-user membership rejected');}catch(InvalidArgumentException){check(true,'cross-user membership rejected');}
    try{$adapter->resolveOrCreateAlbum('u','s',2,['localIdentifier'=>'f','name'=>'Folder','kind'=>'folder']);check(false,'folder rejected');}catch(InvalidArgumentException){check(true,'folder is not Photos album');}

    $orphan=$maps->insert(['user_id'=>'u','source_id'=>'s','source_album_id'=>10,'source_album_key'=>'local:orphan','nextcloud_album_id'=>999,'display_name'=>'Orphan','created_at'=>'old','updated_at'=>'old']);
    $repaired=$adapter->resolveOrCreateAlbum('u','s',10,['localIdentifier'=>'orphan','name'=>'Orphan','kind'=>'album']);
    check($repaired['nextcloud_album_id']===9,'orphan mapping creates replacement');
    check($maps->find('u','s','local:orphan')['nextcloud_album_id']===9,'orphan mapping is rebound');
    $before=count($a->calls); $again=$adapter->resolveOrCreateAlbum('u','s',10,['localIdentifier'=>'orphan','name'=>'Orphan','kind'=>'album']);
    check($again['nextcloud_album_id']===9 && count($a->calls)===$before,'repaired mapping is idempotent');

    $foreignId=42; $a->albums[$foreignId]=new FakeAlbumInfo($foreignId,'other');
    $maps->insert(['user_id'=>'u','source_id'=>'s','source_album_id'=>11,'source_album_key'=>'local:foreign','nextcloud_album_id'=>$foreignId,'display_name'=>'Foreign','created_at'=>'old','updated_at'=>'old']);
    $foreignRepair=$adapter->resolveOrCreateAlbum('u','s',11,['localIdentifier'=>'foreign','name'=>'Foreign','kind'=>'album']);
    check($foreignRepair['nextcloud_album_id']===10,'foreign mapping creates own replacement');
    check($a->albums[$foreignId]->getUserId()==='other','foreign album owner is unchanged');
    check($a->albums[10]->getUserId()==='u','replacement for foreign mapping belongs to expected user');
    check($maps->find('u','s','local:foreign')['nextcloud_album_id']===10,'foreign mapping is rebound safely');

    $maps->insert(['user_id'=>'u','source_id'=>'s','source_album_id'=>12,'source_album_key'=>'local:pending','nextcloud_album_id'=>null,'display_name'=>'Pending','created_at'=>'old','updated_at'=>'old']);
    try{$adapter->resolveOrCreateAlbum('u','s',12,['localIdentifier'=>'pending','name'=>'Pending','kind'=>'album']);check(false,'pending mapping remains protected');}catch(RuntimeException $e){check($e->getMessage()==='Album mapping is pending; refusing to create a second Photos album','pending mapping remains protected');}
}

function albumRecoveryOrchestratorScenario(\OCP\IDBConnection $db, PDO $pdo): void {
    $source='550e8400-e29b-41d4-a716-446655440099'; $user='recover-user';
    $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('$user','$source','S','now','now')");
    $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('$user','$source','asset-x','asset-cloud-x','x.jpg','image',NULL,'now','now',77,'Photos/x.jpg','now')");
    $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('$user','$source','asset-y',NULL,'y.jpg','image',NULL,'now','now',88,'Photos/y.jpg','now')");
    $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('$user','$source','asset-z',NULL,'z.jpg','image',NULL,'now','now',NULL,NULL,NULL)");
    $albumIds=[];
    foreach ([['Album A','album-a'],['Unrelated','album-b'],['Album C','album-c'],['Album D','album-d']] as [$name,$local]) {
        $pdo->exec("INSERT INTO apc_source_albums(user_id,source_id,name,created_at,last_seen_at,local_identifier,cloud_identifier,parent_local_identifier,kind) VALUES ('$user','$source','$name','now','now','$local',NULL,NULL,'album')");
        $albumIds[$local]=(int)$pdo->lastInsertId();
    }
    $assetIds=[];
    foreach (['asset-x','asset-y','asset-z'] as $local) $assetIds[$local]=(int)$pdo->query("SELECT id FROM apc_assets WHERE user_id='$user' AND source_id='$source' AND local_identifier='$local'")->fetchColumn();
    $sourceMemberships=[
        ['album-a','asset-x'], ['album-a','asset-y'], ['album-a','asset-z'],
        ['album-b','asset-y'], ['album-c','asset-x'], ['album-d','asset-x'],
    ];
    foreach ($sourceMemberships as [$album,$asset]) $pdo->exec("INSERT INTO apc_album_memberships(user_id,source_id,album_id,asset_id,first_seen_at,last_seen_at) VALUES ('$user','$source',{$albumIds[$album]},{$assetIds[$asset]},'now','now')");

    $maps=new \OCA\ApplePhotosConnector\Db\AlbumMapRepository($db);
    $mapper=new FakeAlbumMapper(); $mapper->albums[77]=new FakeAlbumInfo(77,$user); $mapper->albums[78]=new FakeAlbumInfo(78,$user); $mapper->albums[79]=new FakeAlbumInfo(79,$user); $mapper->next=80;
    foreach ([['album-a',77],['album-c',78],['album-d',79]] as [$key,$photoId]) $maps->insert(['user_id'=>$user,'source_id'=>$source,'source_album_id'=>$albumIds[$key],'source_album_key'=>'local:'.$key,'nextcloud_album_id'=>$photoId,'display_name'=>$key,'created_at'=>'now','updated_at'=>'now']);
    $resolver=new \OCA\ApplePhotosConnector\Service\AlbumResolutionService($db,$maps,$mapper,new FakePhotosVersion());
    $memberships=new \OCA\ApplePhotosConnector\Service\AlbumMembershipService($db,$maps,$mapper,new FakePhotosVersion(),new FakeAlbumRoot(['Photos/x.jpg'=>77,'Photos/y.jpg'=>88]));
    $sync=new \OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator($db,$maps,$resolver,$memberships);

    // Photos hard-deleted three albums; APC still has the original album and asset mappings.
    unset($mapper->albums[77],$mapper->albums[78],$mapper->albums[79]);
    $beforeCreates=count(array_filter($mapper->calls,static fn($c)=>($c[0]??null)==='create'));
    $second=$sync->sync($source,$user,[],['cloud:asset-cloud-x']);
    check(isset($mapper->memberships['80:77']) && isset($mapper->memberships['81:77']) && isset($mapper->memberships['82:77']),'one selected asset restores all three affected Photos albums and X memberships');
    check(isset($mapper->memberships['80:88']),'recovery restores membership for non-selected imported asset Y in affected album A');
    check($second['albums_seen']===3 && $second['memberships_created']===4 && $second['memberships_skipped_not_imported']===1,'empty selectedAlbumIDs recovers all imported members of three affected albums and skips Z');
    check($pdo->query("SELECT nextcloud_file_id FROM apc_assets WHERE user_id='$user' AND source_id='$source' AND local_identifier='asset-y'")->fetchColumn()===88,'non-selected asset Y reuses its existing APC file mapping without upload');
    check($pdo->query("SELECT nextcloud_file_id FROM apc_assets WHERE user_id='$user' AND source_id='$source' AND local_identifier='asset-z'")->fetchColumn()===null && !isset($mapper->memberships['80:0']),'unimported asset Z is not uploaded or added to Photos album');
    check((int)$pdo->query("SELECT COUNT(*) FROM apc_album_memberships WHERE user_id='$user' AND source_id='$source'")->fetchColumn()===6,'APC membership inventory remains stable during recovery');
    foreach ([['album-a',80],['album-c',81],['album-d',82]] as [$key,$photoId]) check((int)$maps->find($user,$source,'local:'.$key)['nextcloud_album_id']===$photoId,'APC mapping for '.$key.' is rebound to recreated Photos album');
    check($maps->find($user,$source,'local:album-b')===null,'album B containing non-selected Y is not transitively synchronized');
    check(count(array_filter($mapper->calls,static fn($c)=>($c[0]??null)==='create'))===$beforeCreates+3,'only the three affected Photos albums are recreated');
    check($second['albums_created']===3 && $second['albums_reused']===0,'summary counts Photos albums created during recovery as created');
    check($pdo->query("SELECT nextcloud_file_id FROM apc_assets WHERE user_id='$user' AND source_id='$source' AND local_identifier='asset-x'")->fetchColumn()===77 && $pdo->query("SELECT nextcloud_file_id FROM apc_assets WHERE user_id='$user' AND source_id='$source' AND local_identifier='asset-y'")->fetchColumn()===88,'recovery leaves existing X/Y file mappings unchanged');
    $afterRecoveryCreates=count(array_filter($mapper->calls,static fn($c)=>($c[0]??null)==='create'));
    $third=$sync->sync($source,$user,[],['cloud:asset-cloud-x']);
    check($third['albums_seen']===3 && $third['albums_reused']===3 && $third['albums_created']===0,'idempotent follow-up reuses the three recreated albums');
    check($third['memberships_reused']===4 && $third['memberships_created']===0 && $third['memberships_skipped_not_imported']===1,'idempotent follow-up reuses all imported memberships and skips Z');
    check(count(array_filter($mapper->calls,static fn($c)=>($c[0]??null)==='create'))===$afterRecoveryCreates,'idempotent follow-up creates no additional Photos albums');

    // The first album-resolution attempt can fail transiently; the membership pass resolves it again.
    unset($mapper->albums[80],$mapper->albums[81],$mapper->memberships['80:77'],$mapper->memberships['80:88'],$mapper->memberships['81:77']);
    $mapper->createFailures=2;
    $compensated=$sync->sync($source,$user,[],['cloud:asset-cloud-x']);
    check($compensated['errors']===[],'transient album-resolution failures are cleared after membership recovery succeeds');
    check($compensated['albums_created']===2 && $compensated['albums_reused']===1,'album counters include albums created by successful membership recovery retries');
    check($compensated['memberships_created']===3 && $compensated['memberships_reused']===1,'membership recovery remains complete after transient album-resolution failures');
    check(isset($mapper->memberships['83:77'],$mapper->memberships['83:88'],$mapper->memberships['84:77'],$mapper->memberships['82:77']),'compensated recovery leaves all imported Photos memberships present');

    unset($mapper->memberships['83:77']);
    $mapper->membershipAddFailures=1;
    $failedMembership=$sync->sync($source,$user,[],['cloud:asset-cloud-x']);
    check(count($failedMembership['errors'])===1 && $failedMembership['errors'][0]['type']==='membership','uncompensated membership operation failure remains in the summary');
    check(!isset($mapper->memberships['83:77']),'failed membership operation is reflected in the Photos end state');
    $recoveredMembership=$sync->sync($source,$user,[],['cloud:asset-cloud-x']);
    check($recoveredMembership['errors']===[] && isset($mapper->memberships['83:77']),'later idempotent sync restores a genuinely failed membership');

    $emptySource='550e8400-e29b-41d4-a716-446655440098';
    $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('$user','$emptySource','Empty','now','now')");
    check($sync->sync($emptySource,$user,[],['cloud:x'])['albums_seen']===0,'no-album inventory makes album sync a no-op');
}

function explicitAlbumSelectionOrchestratorScenario(\OCP\IDBConnection $db, PDO $pdo): void {
    $user='explicit-selection-user'; $source='550e8400-e29b-41d4-a716-'.bin2hex(random_bytes(6));
    $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('$user','$source','Explicit selection','now','now')");
    $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('$user','$source','asset-x','asset-cloud-x','x.jpg','image',NULL,'now','now',77,'Photos/x.jpg','now')");
    $assetId=(int)$pdo->query("SELECT id FROM apc_assets WHERE user_id='$user' AND source_id='$source' AND local_identifier='asset-x'")->fetchColumn();
    $albumIds=[];
    foreach ([['Album A','album-a'],['Album B','album-b']] as [$name,$local]) {
        $pdo->exec("INSERT INTO apc_source_albums(user_id,source_id,name,created_at,last_seen_at,local_identifier,cloud_identifier,parent_local_identifier,kind) VALUES ('$user','$source','$name','now','now','$local',NULL,NULL,'album')");
        $albumIds[$local]=(int)$pdo->lastInsertId();
        $pdo->exec("INSERT INTO apc_album_memberships(user_id,source_id,album_id,asset_id,first_seen_at,last_seen_at) VALUES ('$user','$source',{$albumIds[$local]},$assetId,'now','now')");
    }

    $maps=new \OCA\ApplePhotosConnector\Db\AlbumMapRepository($db);
    $mapper=new FakeAlbumMapper(); $mapper->albums[177]=new FakeAlbumInfo(177,$user); $mapper->albums[178]=new FakeAlbumInfo(178,$user); $mapper->next=179;
    foreach ([['album-a',177],['album-b',178]] as [$key,$photoId]) $maps->insert(['user_id'=>$user,'source_id'=>$source,'source_album_id'=>$albumIds[$key],'source_album_key'=>'local:'.$key,'nextcloud_album_id'=>$photoId,'display_name'=>$key,'created_at'=>'now','updated_at'=>'now']);
    $resolver=new \OCA\ApplePhotosConnector\Service\AlbumResolutionService($db,$maps,$mapper,new FakePhotosVersion());
    $memberships=new \OCA\ApplePhotosConnector\Service\AlbumMembershipService($db,$maps,$mapper,new FakePhotosVersion(),new FakeAlbumRoot(77));
    $sync=new \OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator($db,$maps,$resolver,$memberships);

    $explicit=$sync->sync($source,$user,['local:album-a'],['cloud:asset-cloud-x']);
    check($explicit['albums_seen']===1 && $explicit['memberships_seen']===1,'explicit album selection does not expand to another album containing a selected asset');

    $assetsOnlySource='550e8400-e29b-41d4-a716-'.bin2hex(random_bytes(6));
    $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('$user','$assetsOnlySource','Asset-only selection','now','now')");
    $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at,nextcloud_file_id,nextcloud_path,uploaded_at) VALUES ('$user','$assetsOnlySource','asset-x','asset-cloud-x','x.jpg','image',NULL,'now','now',77,'Photos/x.jpg','now')");
    $assetOnlyId=(int)$pdo->query("SELECT id FROM apc_assets WHERE user_id='$user' AND source_id='$assetsOnlySource' AND local_identifier='asset-x'")->fetchColumn();
    $assetOnlyAlbums=[];
    foreach ([['Album A','album-a'],['Album B','album-b']] as [$name,$local]) {
        $pdo->exec("INSERT INTO apc_source_albums(user_id,source_id,name,created_at,last_seen_at,local_identifier,cloud_identifier,parent_local_identifier,kind) VALUES ('$user','$assetsOnlySource','$name','now','now','$local',NULL,NULL,'album')");
        $assetOnlyAlbums[$local]=(int)$pdo->lastInsertId();
        $pdo->exec("INSERT INTO apc_album_memberships(user_id,source_id,album_id,asset_id,first_seen_at,last_seen_at) VALUES ('$user','$assetsOnlySource',{$assetOnlyAlbums[$local]},$assetOnlyId,'now','now')");
    }
    $assetOnlyMaps=new \OCA\ApplePhotosConnector\Db\AlbumMapRepository($db);
    $assetOnlyMapper=new FakeAlbumMapper(); $assetOnlyMapper->albums[187]=new FakeAlbumInfo(187,$user); $assetOnlyMapper->albums[188]=new FakeAlbumInfo(188,$user); $assetOnlyMapper->next=189;
    foreach ([['album-a',187],['album-b',188]] as [$key,$photoId]) $assetOnlyMaps->insert(['user_id'=>$user,'source_id'=>$assetsOnlySource,'source_album_id'=>$assetOnlyAlbums[$key],'source_album_key'=>'local:'.$key,'nextcloud_album_id'=>$photoId,'display_name'=>$key,'created_at'=>'now','updated_at'=>'now']);
    $assetOnlyResolver=new \OCA\ApplePhotosConnector\Service\AlbumResolutionService($db,$assetOnlyMaps,$assetOnlyMapper,new FakePhotosVersion());
    $assetOnlyMemberships=new \OCA\ApplePhotosConnector\Service\AlbumMembershipService($db,$assetOnlyMaps,$assetOnlyMapper,new FakePhotosVersion(),new FakeAlbumRoot(77));
    $assetOnlySync=new \OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator($db,$assetOnlyMaps,$assetOnlyResolver,$assetOnlyMemberships);
    $assetOnly=$assetOnlySync->sync($assetsOnlySource,$user,[],['cloud:asset-cloud-x']);
    check($assetOnly['albums_seen']===2 && $assetOnly['memberships_seen']===2,'asset-only selection continues to include every album containing the selected imported asset');

    $unfiltered=$assetOnlySync->sync($assetsOnlySource,$user,null,null);
    check($unfiltered['albums_seen']===2 && $unfiltered['memberships_seen']===2,'omitted selection filters retain the existing unfiltered album-sync behavior');
}
