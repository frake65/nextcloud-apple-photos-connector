<?php
declare(strict_types=1);
use OCA\ApplePhotosConnector\Controller\AlbumController;
function albumControllerScenarios(PDO $pdo): void {
 $db=new TestHarness\Connection($pdo); $source='550e8400-e29b-41d4-a716-446655440010';
 $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','$source','S','now','now')");
 $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$source','asset1',NULL,'a.jpg','image',NULL,'now','now')");
 $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$source','asset-cloud','cloud-value','c.jpg','image',NULL,'now','now')");
 // Shape emitted by AlbumInventoryDocument/AlbumInventory's Swift Codable encoder.
 // Both compatibility fields must carry the same two identities.
 // Swift's default Codable representation for Date is seconds since Apple's reference date.
 $payload=json_encode(['version'=>1,'source'=>['sourceId'=>$source,'name'=>'S','createdAt'=>811800000.0],'albums'=>[['localIdentifier'=>'album1','cloudIdentifier'=>null,'name'=>'Album','kind'=>'album','parentLocalIdentifier'=>null,'assetIdentities'=>['asset1','cloud:cloud-value'],'assets'=>['asset1','cloud:cloud-value']]]],JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);
 $decoded=json_decode($payload,true,512,JSON_THROW_ON_ERROR);
 check($decoded['albums'][0]['assetIdentities']===$decoded['albums'][0]['assets'] && count($decoded['albums'][0]['assets'])===2,'Swift-shaped album inventory carries identical assetIdentities and assets arrays');
 $req=new class($decoded) implements \OCP\IRequest { public array $params; function __construct($p){$this->params=$p;} function getHeader(string $n):string{return $n==='Authorization'?'Basic test':'application/json';} function getParam(string $n):mixed{return $this->params[$n]??null;} function getParams():array{return $this->params;} };
 $session=new class implements \OCP\IUserSession { function getUser():mixed{return new class{function getUID():string{return 'u1';}};} };
 $c=new AlbumController($req,$session,$db); $r=$c->inventory(); if($r->getStatus()!==200) { var_export($r->getData()); echo "\n"; } check($r->getStatus()===200,'album controller accepts Swift-shaped inventory payload');
 $albumId=(int)$pdo->query("SELECT id FROM apc_source_albums WHERE user_id='u1' AND source_id='$source' AND local_identifier='album1'")->fetchColumn();
 $membershipRows=$pdo->query("SELECT album_id,asset_id FROM apc_album_memberships WHERE user_id='u1' AND source_id='$source' ORDER BY asset_id")->fetchAll(PDO::FETCH_ASSOC);
 $assetIds=$pdo->query("SELECT id FROM apc_assets WHERE user_id='u1' AND source_id='$source' ORDER BY id")->fetchAll(PDO::FETCH_COLUMN);
 check(count($membershipRows)===2 && array_column($membershipRows,'album_id')===[$albumId,$albumId] && array_map('intval',array_column($membershipRows,'asset_id'))===array_map('intval',$assetIds),'Swift-shaped payload persists both memberships against the internal album ID and existing assets');
 $r2=$c->inventory(); check($r2->getStatus()===200 && (int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===1 && (int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn()===2,'Swift-shaped album inventory is idempotent');
 $req->params['source']['sourceId']='550e8400-e29b-41d4-a716-446655440011'; check($c->inventory()->getStatus()===400,'album controller rejects unknown source'); check((int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===1,'failed album request leaves state unchanged');
 $req->params['source']['sourceId']=$source; $req->params['albums']=[['localIdentifier'=>'album2','name'=>'Mixed','kind'=>'album','assets'=>['asset1','local:never-seen']],['localIdentifier'=>'album3','name'=>'Unknown','kind'=>'album','assets'=>['cloud:missing']],['localIdentifier'=>'album4','name'=>'Empty','kind'=>'album','assets'=>[]]]; check($c->inventory()->getStatus()===200,'unknown album members are skipped without rollback'); check((int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===4,'albums with unknown or empty members are retained'); check((int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn()===3,'known membership persists while unknown members are skipped');
 $sourceB='550e8400-e29b-41d4-a716-446655440011'; $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','$sourceB','B','now','now')"); $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$sourceB','assetB',NULL,'b.jpg','image',NULL,'now','now')");
 $req->params['source']['sourceId']=$source; $req->params['albums'][0]['assets']=['assetB']; $before=(int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn(); check($c->inventory()->getStatus()===200 && (int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn()===$before,'cross-source membership is skipped without partial state');
 $req->params['albums'][0]['assets']=['asset1']; $foreignSession=new class implements \OCP\IUserSession { function getUser():mixed{return new class{function getUID():string{return 'u2';}};} }; $foreignController=new AlbumController($req,$foreignSession,$db); check($foreignController->inventory()->getStatus()===400 && (int)$pdo->query("SELECT COUNT(*) FROM apc_source_albums WHERE user_id='u2'")->fetchColumn()===0,'cross-user membership rejected without partial state');
 $req->params['source']['sourceId']=$sourceB; $req->params['albums'][0]['assets']=['asset1']; check($c->inventory()->getStatus()===200,'album/source isolation skips foreign asset');
 $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','550e8400-e29b-41d4-a716-446655440012','C','now','now')"); $req->params['source']['sourceId']='550e8400-e29b-41d4-a716-446655440012'; $req->params['albums'][0]['assets']=[]; check($c->inventory()->getStatus()===200,'same-name album in second source accepted separately'); check((int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()>=5,'same-name albums across sources remain separate');

 // Regression fixture matching the live collision: the same Photos asset identity
 // exists in an older source and the currently selected source. Insert the foreign
 // row first, matching the live query's observed result ordering.
 $collisionSource='35a8f618-bbbf-4994-90f3-8fd2923fba74'; $olderSources=['c2052f3b-2ac2-47d5-a04e-5e6545e58a5f','5298c0df-c0fa-499c-a332-cd67ee0ae779'];
 foreach ($olderSources as $index=>$olderSource) $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','$olderSource','Historical $index','now','now')");
 $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','$collisionSource','Current','now','now')");
 $otherUserSource='550e8400-e29b-41d4-a716-446655440015';
 $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u2','$otherUserSource','Other user','now','now')");
 $liveAssets=[
  ['357161BC-EB02-4B3F-AC38-1C4C1A53647B/L0/001','357161BC-EB02-4B3F-AC38-1C4C1A53647B:001:ATNZ7rkzTgnJhYynqNQu44QRJRlC','Passfoto.jpg'],
  ['C3C1E8AE-7163-429A-AF67-77E57BCEC44B/L0/001','C3C1E8AE-7163-429A-AF67-77E57BCEC44B:001:Ae6zTJ4e7hsNHdZiXdCbzbRhuc0c','Käfer.jpg'],
 ];
 foreach ($liveAssets as [$local,$cloud,$filename]) {
  foreach ($olderSources as $olderSource) $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$olderSource','$local','$cloud','historical-$filename','image',NULL,'now','now')");
  $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u2','$otherUserSource','$local','$cloud','other-user-$filename','image',NULL,'now','now')");
  $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$collisionSource','$local','$cloud','$filename','image',NULL,'now','now')");
 }
 $collidingIdentities=array_column($liveAssets,0);
 $req->params=['source'=>['sourceId'=>$collisionSource,'name'=>'Current'],'albums'=>[['localIdentifier'=>'collision-album','name'=>'Collision','kind'=>'album','assetIdentities'=>$collidingIdentities,'assets'=>$collidingIdentities]]];
 $firstHit=$pdo->query("SELECT id,source_id FROM apc_assets WHERE local_identifier='357161BC-EB02-4B3F-AC38-1C4C1A53647B/L0/001' OR cloud_identifier='357161BC-EB02-4B3F-AC38-1C4C1A53647B/L0/001'")->fetch(PDO::FETCH_ASSOC);
 check($firstHit!==false && $firstHit['source_id']===$olderSources[0],'live-identity fixture returns older foreign asset as first global identity hit');
 check($c->inventory()->getStatus()===200,'collision inventory request returns HTTP 200');
 $collisionMembershipCount=(int)$pdo->query("SELECT COUNT(*) FROM apc_album_memberships m JOIN apc_source_albums a ON a.id=m.album_id WHERE m.user_id='u1' AND m.source_id='$collisionSource'")->fetchColumn();
 check($collisionMembershipCount===2,'global identity lookup must persist both live-identity memberships for the current source despite historical duplicates');
}

function albumSyncDiagnosticControllerScenario(): void {
 if (!defined('OC_DEBUG')) define('OC_DEBUG', true);
 $db=new class implements \OCP\IDBConnection { function getQueryBuilder(): never { throw new RuntimeException('synthetic query failure'); } };
 $maps=new \OCA\ApplePhotosConnector\Db\AlbumMapRepository($db);
 $mapper=new FakeAlbumMapper();
 $resolver=new \OCA\ApplePhotosConnector\Service\AlbumResolutionService($db,$maps,$mapper,new FakePhotosVersion());
 $memberships=new \OCA\ApplePhotosConnector\Service\AlbumMembershipService($db,$maps,$mapper,new FakePhotosVersion(),new FakeAlbumRoot(77));
 $sync=new \OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator($db,$maps,$resolver,$memberships);
 $request=new class implements \OCP\IRequest { function getHeader(string $n):string{return $n==='Authorization'?'Basic test':'';} function getParam(string $n):mixed{return null;} function getParams():array{return ['sourceId'=>'550e8400-e29b-41d4-a716-446655440020','selectedAlbumIDs'=>[],'selectedAssetIDs'=>['cloud:asset-cloud-x']];} };
 $session=new class implements \OCP\IUserSession { function getUser():mixed{return new class{function getUID():string{return 'u1';}};} };
 $response=(new \OCA\ApplePhotosConnector\Controller\AlbumController($request,$session,$db,$sync))->sync();
 $data=$response->getData();
 check($response->getStatus()===500,'album sync unexpected failure remains HTTP 500');
 check(($data['diagnostic']['stage']??null)==='album.sync.source_albums.lookup','debug response identifies failed sync stage');
 check(($data['diagnostic']['exceptionClass']??null)===RuntimeException::class,'debug response identifies original exception class');
 check(($data['diagnostic']['request']['selected_album_count']??null)===0 && ($data['diagnostic']['request']['selected_asset_prefixes']['cloud']??null)===1,'debug response records empty album selection and prefixed cloud asset count');
 check(!array_key_exists('trace',$data['diagnostic']??[]),'debug response does not include a stack trace');
}
