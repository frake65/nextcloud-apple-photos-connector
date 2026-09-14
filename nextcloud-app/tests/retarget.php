<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\{AssetIdentity,InventoryService,InventoryValidator,UploadService,UploadTargetService};

final class RetargetFixture {
    public PDO $pdo;
    public InventoryRepository $repo;
    public TestFiles $files;
    public InventoryService $inventory;
    public UploadTargetService $prepare;
    public UploadService $complete;
    public string $user = 'retarget';
    public array $source = ['sourceId'=>'b50e8400-e29b-41d4-a716-446655440000','name'=>'Fresh'];
    public array $input = [['localIdentifier'=>'one','filename'=>'test.jpg','mediaType'=>'image']];
    public array $first;
    public array $old;
    public function __construct(?PDO $pdo = null) {
        $this->pdo = $pdo ?? freshDatabase();
        $this->repo = new InventoryRepository(new TestHarness\Connection($this->pdo));
        $this->files = new TestFiles();
        $this->inventory = new InventoryService($this->repo,new AssetIdentity(),new InventoryValidator(),$this->files);
        $this->prepare = new UploadTargetService($this->repo,$this->files);
        $this->complete = new UploadService($this->repo,$this->files);
        $this->first = $this->scan();
        $target = $this->reserve($this->first,'Old/2020/01');
        $this->files->files[$target['path']] = 100;
        $this->ack($this->first,$target['path']);
        $this->old = $this->current();
    }
    public function scan(): array { return $this->inventory->ingest($this->user,$this->source,$this->input); }
    public function current(): array { return $this->repo->getCurrentTarget($this->user,$this->source['sourceId'],(int)$this->first['assets'][0]['upload']['assetId']); }
    public function reserve(array $run,string $folder='New/2026/09'): array {
        return $this->prepare->prepare($this->user,$this->source['sourceId'],$run['runId'],$run['assets'][0]['upload']['uploadId'],8,hash('sha256','ORIGINAL'),$folder);
    }
    public function ack(array $run,?string $path,string $status='uploaded'): array {
        return $this->complete->acknowledge($this->user,$this->source['sourceId'],$run['runId'],$run['assets'][0]['upload']['uploadId'],$status,$path);
    }
    public function missing(): void { unset($this->files->files[$this->old['path']]); }
}
function rejects(callable $work,string $message): void {
    try { $work(); } catch (InvalidArgumentException|RuntimeException $e) { check(true,$message); return; }
    throw new LogicException($message . ': unexpectedly accepted');
}

function retargetScenarios(): void {
    $f = new RetargetFixture();
    $before = $f->files->files;
    check($f->scan()['assets'][0]['state']==='known' && $f->reserve($f->first,'New')['path']===$f->old['path'] && $f->files->files===$before, 'R1: existing current ignores changed client folder; no move/copy');
    // Cache fields must never drive identity or target selection.
    $f->repo->updateOwned('apc_assets',$f->user,'id',$f->old['asset_id'],['nextcloud_path'=>'bogus','nextcloud_file_id'=>null]);
    check($f->scan()['assets'][0]['state']==='known','current pointer wins over stale compatibility fields');
    $f->missing();
    check($f->scan()['assets'][0]['state']==='new' && $f->scan()['assets'][0]['upload']!==null,'R2: missing current is recoverable during normal inventory');
    $run = $f->scan(); $same = $f->reserve($run,'Old/2020/01');
    check($same['state']==='missing' && dirname($same['path'])==='Old/2020/01' && $same['path']!==$f->old['path'],'R3: missing current reserves new target in same folder');

    $f = new RetargetFixture(); $f->missing(); $run=$f->scan(); $new=$f->reserve($run);
    check($new['state']==='missing' && $new['path']==='New/2026/09/test.jpg','R4: authorized retarget uses current client destination');
    $f->files->files[$new['path']]=200;
    $f->ack($run,$new['path']);
    $current=$f->current();$asset=$f->repo->asset($f->user,$f->source['sourceId'],(int)$current['asset_id']);
    check($current['path']===$new['path'] && (int)$current['id']!==(int)$f->old['id'] && (int)$asset['nextcloud_file_id']===200 && $asset['nextcloud_path']===$new['path'] && $current['sha256']===hash('sha256','ORIGINAL') && (int)$current['bytes']===8,'R5: verified completion switches current and compatibility fields');
    check($f->repo->target($f->user,$f->source['sourceId'],(int)$current['asset_id'],(int)$f->old['id'])===$f->old,'R6: historical target row retained unchanged');
    check($f->scan()['assets'][0]['state']==='known','R16: subsequent inventory uses new current');
    // Memberships remain keyed by source and external asset. Album sync can
    // resolve the asset's current file after a successful retarget.
    $assetId = (int)$current['asset_id'];
    $pdo = $f->pdo;
    $pdo->exec("INSERT INTO apc_source_albums (user_id,source_id,name,created_at,last_seen_at,local_identifier,kind) VALUES ('retarget','b50e8400-e29b-41d4-a716-446655440000','Album','now','now','album-1','album')");
    $albumId = (int)$pdo->lastInsertId();
    $pdo->exec("INSERT INTO apc_album_memberships (user_id,source_id,album_id,asset_id,first_seen_at,last_seen_at) VALUES ('retarget','b50e8400-e29b-41d4-a716-446655440000',$albumId,$assetId,'now','now')");
    $membership = $pdo->query("SELECT * FROM apc_album_memberships WHERE album_id=$albumId AND asset_id=$assetId")->fetch(PDO::FETCH_ASSOC);
    check((int)$membership['asset_id']===$assetId && $f->current()['path']===$new['path'],'R17: album membership survives retarget and follows current asset target');
    $otherSource='b50e8400-e29b-41d4-a716-446655440001';
    $pdo->exec("INSERT INTO apc_sources (user_id,source_id,name,created_at,last_seen_at) VALUES ('retarget','$otherSource','Other','now','now')");
    $pdo->exec("INSERT INTO apc_assets (user_id,source_id,local_identifier,media_type,first_seen_at,last_seen_at) VALUES ('retarget','$otherSource','one','image','now','now')");
    $otherAsset=(int)$pdo->lastInsertId();
    $foreignTarget=$f->repo->insertTarget(['user_id'=>'retarget','source_id'=>$otherSource,'asset_id'=>$otherAsset,'filename'=>'other.jpg','path'=>'Other/other.jpg','path_key'=>hash('sha256','Other/other.jpg'),'bytes'=>8,'sha256'=>hash('sha256','ORIGINAL'),'attempt'=>0]);
    rejects(fn()=>$f->repo->setCurrentTarget('retarget',$f->source['sourceId'],$assetId,$foreignTarget),'R18: source A cannot alter source B target mapping');
    $ack=$f->ack($run,$new['path']);$f->ack($f->first,$f->old['path']);
    check($f->current()===$current && $ack['summary']['uploaded']===1,'R12: replay, including older successful ticket, cannot switch current again');
    rejects(fn()=>$f->reserve($f->first,'Third'),'finished old ticket cannot reopen missing historical target');

    $f = new RetargetFixture();$f->missing();$run=$f->scan();$f->files->folderFailure=true;
    rejects(fn()=>$f->reserve($run),'R7: prepare folder error rejected');
    check($f->current()===$f->old && count($f->repo->targets($f->user,$f->source['sourceId']))===1,'R7: prepare error rolls reservation back and preserves current');
    $f->files->folderFailure=false;$new=$f->reserve($run);$f->ack($run,null,'failed');
    check($f->current()===$f->old,'R8: PUT failure preserves old current');
    foreach (['FOREIGN!','short'] as $bad) {
        $f->files->files[$new['path']]=201;$f->files->contents[$new['path']]=$bad;
        rejects(fn()=>$f->ack($run,$new['path']),'R9: byte/hash mismatch rejected');
        check($f->current()===$f->old,'R9: mismatch leaves old current unchanged');
    }
    $f->files->contents[$new['path']]='ORIGINAL';
    $badRepo=new FailingUploadRepository(new TestHarness\Connection($f->pdo));
    rejects(fn()=>(new UploadService($badRepo,$f->files))->acknowledge($f->user,$f->source['sourceId'],$run['runId'],$run['assets'][0]['upload']['uploadId'],'uploaded',$new['path']),'completion counter failure rolls back');
    check($f->current()===$f->old && $f->repo->uploads($f->user,$f->source['sourceId'])[1]['status']==='failed','current, ticket and counters roll back together');
    $f->files->files[$f->old['path']]=100;
    rejects(fn()=>$f->ack($run,$new['path']),'reappeared old file prevents current switch');
    rejects(fn()=>$f->reserve($run),'reappeared old file revokes prepare authorization');
    $f->missing();$f->ack($run,$new['path']);
    check($f->current()['path']===$new['path'],'failed ticket can recover after verified upload');

    // Manipulate the HTTP input rather than changing a server-owned DB flag.
    // Keep the mapped file present here: R10 tests forged retarget
    // authorization, not recovery of a deleted file.
    $f = new RetargetFixture();
    $request=new class($f) implements OCP\IRequest {
        public array $params;
        public function __construct(RetargetFixture $f){$this->params=['source'=>$f->source,'assets'=>$f->input,'retarget_allowed'=>true,'base_target_id'=>null,'folder'=>'Attacker','retransferMissing'=>false];}
        public function getHeader(string $n): string {return $n==='Authorization'?'Basic test':'application/json';}
        public function getParam(string $n): mixed {return $this->params[$n]??null;}
        public function getParams(): array{return $this->params;}
    };
    $session=new class implements OCP\IUserSession {public function getUser(): mixed {return new class {public function getUID(): string{return 'retarget';}};}};
    $controller=new OCA\ApplePhotosConnector\Controller\InventoryController($request,$f->inventory,$session);
    check($controller->create()->getData()['assets'][0]['state']==='known','R10: client retarget_allowed cannot authorize missing current upload');
    // Older clients may still send the retired field; it must not affect recovery.
    foreach ([false, true] as $legacyValue) {
        $request->params['retransferMissing'] = $legacyValue;
        $reply = $controller->create();
        check($reply->getStatus() === 200 && $reply->getData()['assets'][0]['state'] === 'known'
            && $reply->getData()['assets'][0]['upload'] === null,
            'legacy retransferMissing is tolerated for an existing file');
    }
    $f->missing();
    foreach ([false, true] as $legacyValue) {
        $request->params['retransferMissing'] = $legacyValue;
        $reply = $controller->create();
        check($reply->getStatus() === 200 && $reply->getData()['assets'][0]['state'] === 'new'
            && $reply->getData()['assets'][0]['upload'] !== null,
            'legacy retransferMissing cannot suppress recovery of a missing file');
    }
    $run=$f->scan();$request->params=['sourceId'=>$f->source['sourceId'],'runId'=>$run['runId'],'uploadId'=>$run['assets'][0]['upload']['uploadId'],'bytes'=>8,'sha256'=>hash('sha256','ORIGINAL'),'folder'=>'Attacker','retarget_allowed'=>true,'target_id'=>null];
    $prepareController=new OCA\ApplePhotosConnector\Controller\UploadController($request,$f->complete,$session,$f->prepare);
    check($prepareController->prepare()->getStatus()===200,'R10: missing current is recoverable only from server-issued ticket state');
    foreach ([['other',$f->source['sourceId'],$run['runId']],[$f->user,'b50e8400-e29b-41d4-a716-446655440099',$run['runId']],[$f->user,$f->source['sourceId'],$f->first['runId']]] as [$user,$source,$rid]) {
        rejects(fn()=>$f->prepare->prepare($user,$source,$rid,$run['assets'][0]['upload']['uploadId'],8,hash('sha256','ORIGINAL'),'New'),'R11: foreign user/source/run ticket rejected');
    }
    $other=$f->inventory->ingest($f->user,$f->source,[['localIdentifier'=>'two','filename'=>'other.jpg','mediaType'=>'image']]);
    $new=$f->reserve($run);$f->files->files[$new['path']]=202;
    rejects(fn()=>$f->complete->acknowledge($f->user,$f->source['sourceId'],$other['runId'],$other['assets'][0]['upload']['uploadId'],'uploaded',$new['path']),'R11: different asset ticket cannot claim target');

    $f = new RetargetFixture();$f->missing();$run=$f->scan();
    $f->files->files['New/2026/09/test.jpg']=999;$f->files->contents['New/2026/09/test.jpg']='FOREIGN!';
    $new=$f->reserve($run);
    check($new['path']!=='New/2026/09/test.jpg' && $f->files->contents['New/2026/09/test.jpg']==='FOREIGN!','R14: foreign destination gets suffix without overwrite');
    foreach (['../outside','/absolute','a//b','a/../b',"a\0b",'a\\b'] as $folder) {
        rejects(fn()=>$f->reserve($run,$folder),'unsafe parent path rejected');
    }
    parentFolderScenario();
}

function parentFolderScenario(): void {
    $folder=new class {
        public array $children=[];
        public function getOrCreateFolder(string $part): self {
            if(isset($this->children[$part])&&!$this->children[$part] instanceof self)throw new RuntimeException('Existing file blocks folder');
            return $this->children[$part]??=$this->newChild();
        }
        private function newChild(): self{return new self();}
    };
    $root=new class($folder) implements OCP\Files\IRootFolder {
        public array $users=[];
        public function __construct(private object $folder){}
        public function getUserFolder(string $user): object{$this->users[]=$user;return $this->folder;}
    };
    $locator=new OCA\ApplePhotosConnector\Service\UploadedFileLocator($root);
    $locator->ensureFolder('u','New/2026/09');$locator->ensureFolder('u','New/2026/09');
    check(isset($folder->children['New']->children['2026']->children['09']) && $root->users===['u','u'],'R15: missing parents created idempotently under authenticated user root');
    $folder->children['blocked']=new stdClass();
    rejects(fn()=>$locator->ensureFolder('u','blocked/child'),'R15: existing file is never replaced by a folder');
}

/** Run two workers simultaneously, with independent SQLite connections and a start barrier. */
function parallelRetargetWorkers(string $database, array $runs, TestFiles $files, string $operation, ?string $path = null): array {
    if (!function_exists('pcntl_fork')) { throw new RuntimeException('R13 requires PHP pcntl; do not silently skip concurrency checks'); }
    $workers=[];
    foreach ($runs as $run) {
        $sockets=stream_socket_pair(STREAM_PF_UNIX,STREAM_SOCK_STREAM,0);
        $pid=pcntl_fork();
        if($pid===-1)throw new RuntimeException('Cannot fork concurrency test');
        if($pid===0){
            fclose($sockets[0]);fread($sockets[1],1);
            try {
                $pdo=new PDO('sqlite:'.$database);$pdo->exec('PRAGMA busy_timeout=5000');
                $repo=new InventoryRepository(new TestHarness\Connection($pdo));
                $args=['retarget','b50e8400-e29b-41d4-a716-446655440000',$run['runId'],$run['assets'][0]['upload']['uploadId']];
                $result=$operation==='prepare'
                    ? (new UploadTargetService($repo,$files))->prepare(...[...$args,8,hash('sha256','ORIGINAL'),'Concurrent/2026/09'])
                    : (new UploadService($repo,$files))->acknowledge(...[...$args,'uploaded',$path]);
                fwrite($sockets[1],json_encode(['ok'=>$result]));fclose($sockets[1]);exit(0);
            } catch(Throwable $error){fwrite($sockets[1],json_encode(['error'=>$error->getMessage()]));fclose($sockets[1]);exit(1);}
        }
        fclose($sockets[1]);$workers[]=[$pid,$sockets[0]];
    }
    foreach($workers as [$pid,$socket])fwrite($socket,'!');
    $results=[];
    foreach($workers as [$pid,$socket]){
        $result=json_decode(stream_get_contents($socket),true);fclose($socket);pcntl_waitpid($pid,$status);
        if(!pcntl_wifexited($status)||pcntl_wexitstatus($status)!==0||!isset($result['ok']))throw new RuntimeException('Concurrent worker failed: '.json_encode($result));
        $results[]=$result['ok'];
    }
    return $results;
}
function retargetRaceScenario(): void {
    $database=tempnam(sys_get_temp_dir(),'apc-race-');
    try {
        $pdo=new PDO('sqlite:'.$database);$pdo->exec('PRAGMA busy_timeout=5000');
        $schema=new TestHarness\Schema();
        (new OCA\ApplePhotosConnector\Migration\Version008000Date20260910000000())->changeSchema(new class implements OCP\Migration\IOutput {},fn()=>$schema,[]);
        $schema->apply($pdo);
        $f=new RetargetFixture($pdo);$f->missing();$runs=[$f->scan(),$f->scan()];
        $pdo->exec('CREATE TABLE test_current_switches (asset_id INTEGER)');
        $pdo->exec('CREATE TRIGGER test_current_switch AFTER UPDATE OF current_upload_target_id ON apc_assets WHEN NEW.current_upload_target_id IS NOT OLD.current_upload_target_id BEGIN INSERT INTO test_current_switches VALUES (NEW.id); END');
        $prepared=parallelRetargetWorkers($database,$runs,$f->files,'prepare');
        check($prepared[0]===$prepared[1] && count($f->repo->targets($f->user,$f->source['sourceId']))===2,'R13: simultaneous prepare shares one new reservation across runs');
        $f->files->files[$prepared[0]['path']]=300;
        parallelRetargetWorkers($database,$runs,$f->files,'complete',$prepared[0]['path']);
        check((int)$pdo->query('SELECT COUNT(*) FROM test_current_switches')->fetchColumn()===1 && $f->current()['path']===$prepared[0]['path'],'R13: simultaneous complete performs exactly one current switch');
        check($f->repo->target($f->user,$f->source['sourceId'],(int)$f->old['asset_id'],(int)$f->old['id'])===$f->old,'R13: parallel operations preserve old target');
        // An unused ticket issued for the previous generation cannot start a later retarget.
        unset($f->files->files[$prepared[0]['path']]);
        rejects(fn()=>$f->reserve($runs[0],'Another'),'R13: finished generation cannot reopen after current file disappears');
    } finally { if(is_file($database))unlink($database); }
}
