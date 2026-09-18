<?php
declare(strict_types=1);
use OCA\ApplePhotosConnector\Controller\AlbumController;
function albumControllerScenarios(PDO $pdo): void {
 $db=new TestHarness\Connection($pdo); $source='550e8400-e29b-41d4-a716-446655440010';
 $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','$source','S','now','now')");
 $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$source','asset1',NULL,'a.jpg','image',NULL,'now','now')");
 $req=new class($source) implements \OCP\IRequest { public array $params; function __construct($s){$this->params=['source'=>['sourceId'=>$s,'name'=>'S'],'albums'=>[['localIdentifier'=>'album1','name'=>'Album','kind'=>'album','assets'=>['asset1']]]];} function getHeader(string $n):string{return $n==='Authorization'?'Basic test':'application/json';} function getParam(string $n):mixed{return $this->params[$n]??null;} function getParams():array{return $this->params;} };
 $session=new class implements \OCP\IUserSession { function getUser():mixed{return new class{function getUID():string{return 'u1';}};} };
 $c=new AlbumController($req,$session,$db); $r=$c->inventory(); if($r->getStatus()!==200) { var_export($r->getData()); echo "\n"; } check($r->getStatus()===200,'album controller accepts valid source/asset'); $r2=$c->inventory(); check($r2->getStatus()===200 && (int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===1 && (int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn()===1,'album controller is idempotent');
 $req->params['source']['sourceId']='550e8400-e29b-41d4-a716-446655440011'; check($c->inventory()->getStatus()===400,'album controller rejects unknown source'); check((int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===1,'failed album request leaves state unchanged');
 $sourceB='550e8400-e29b-41d4-a716-446655440011'; $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','$sourceB','B','now','now')"); $pdo->exec("INSERT INTO apc_assets(user_id,source_id,local_identifier,cloud_identifier,filename,media_type,creation_date,first_seen_at,last_seen_at) VALUES ('u1','$sourceB','assetB',NULL,'b.jpg','image',NULL,'now','now')");
 $req->params['source']['sourceId']=$source; $req->params['albums'][0]['assets']=['assetB']; $before=(int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn(); check($c->inventory()->getStatus()===400 && (int)$pdo->query('SELECT COUNT(*) FROM apc_album_memberships')->fetchColumn()===$before,'cross-source membership rejected without partial state');
 $req->params['albums'][0]['assets']=['asset1']; $foreignSession=new class implements \OCP\IUserSession { function getUser():mixed{return new class{function getUID():string{return 'u2';}};} }; $foreignController=new AlbumController($req,$foreignSession,$db); check($foreignController->inventory()->getStatus()===400 && (int)$pdo->query("SELECT COUNT(*) FROM apc_source_albums WHERE user_id='u2'")->fetchColumn()===0,'cross-user membership rejected without partial state');
 $req->params['source']['sourceId']=$sourceB; $req->params['albums'][0]['assets']=['asset1']; check($c->inventory()->getStatus()===400 && (int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===1,'album/source isolation rejects foreign asset');
 $pdo->exec("INSERT INTO apc_sources(user_id,source_id,name,created_at,last_seen_at) VALUES ('u1','550e8400-e29b-41d4-a716-446655440012','C','now','now')"); $req->params['source']['sourceId']='550e8400-e29b-41d4-a716-446655440012'; $req->params['albums'][0]['assets']=[]; check($c->inventory()->getStatus()===200,'same-name album in second source accepted separately'); check((int)$pdo->query('SELECT COUNT(*) FROM apc_source_albums')->fetchColumn()===2,'same-name albums across sources remain separate');
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
