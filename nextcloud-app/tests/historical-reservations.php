<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\{AssetIdentity,InventoryService,InventoryValidator,UploadService,UploadTargetService};

final class HistoricalReservationFixture {
    public InventoryRepository $repo;
    public TestFiles $files;
    public InventoryService $inventory;
    public UploadTargetService $prepare;
    public UploadService $complete;
    public string $user = 'historical-reservation';
    public array $source = ['sourceId'=>'dd008000-0000-4000-8000-000000000001','name'=>'Reservation regression'];
    public array $assets;

    public function __construct(int $count = 1) {
        $this->repo = new InventoryRepository(new TestHarness\Connection(freshDatabase()));
        $this->files = new TestFiles();
        $this->inventory = new InventoryService($this->repo,new AssetIdentity(),new InventoryValidator(),$this->files);
        $this->prepare = new UploadTargetService($this->repo,$this->files);
        $this->complete = new UploadService($this->repo,$this->files);
        $this->assets = array_map(fn(int $i): array => ['localIdentifier'=>"asset-$i",'cloudIdentifier'=>"cloud-$i",'filename'=>"photo-$i.jpg",'mediaType'=>'image'],range(1,$count));
    }
    public function scan(?array $assets = null): array {
        return $this->inventory->ingest($this->user,$this->source,$assets ?? $this->assets);
    }
    public function reserve(array $run,string $folder,int $index = 0): array {
        return $this->prepare->prepare($this->user,$this->source['sourceId'],$run['runId'],$run['assets'][$index]['upload']['uploadId'],8,hash('sha256','ORIGINAL'),$folder);
    }
    public function ack(array $run,?string $path,int $index = 0): array {
        return $this->complete->acknowledge($this->user,$this->source['sourceId'],$run['runId'],$run['assets'][$index]['upload']['uploadId'],$path === null ? 'failed' : 'uploaded',$path);
    }
    public function targets(): array { return $this->repo->targets($this->user,$this->source['sourceId']); }
}

function historicalReservationScenarios(): void {
    $f = new HistoricalReservationFixture();
    $oldRun = $f->scan(); $old = $f->reserve($oldRun,'Old/2026/09'); $f->ack($oldRun,null);
    $history = $f->targets()[0];
    $f->files->folders = [];
    $newRun = $f->scan(); $new = $f->reserve($newRun,'New/2026/09');
    check($new['path']==='New/2026/09/photo-1.jpg' && $new['state']==='missing','HR1: failed historical reservation does not override a new run destination');
    check(array_keys($f->files->folders)===['New/2026/09'],'HR2: discarded historical folder is not recreated');
    check(count($f->targets())===2 && $f->targets()[0]===$history,'HR3: historical target retained unchanged');
    $f->files->files[$new['path']]=701;
    $ack = $f->ack($newRun,$new['path']);
    check($ack['summary']===['uploaded'=>1,'failed'=>0],'HR4: new destination can be verified and completed');
    $again = $f->scan();
    check($again['assets'][0]['state']==='known' && $again['assets'][0]['upload']===null,'HR5: subsequent inventory converges to known');
    check($f->reserve($newRun,'Third/2026/09')['state']==='present' && $f->ack($newRun,$new['path'])===$ack
        && count($f->targets())===2 && count($f->files->files)===1,'HR6: lost ACK reply can be replayed without another target or file');

    // Confirmed existing targets are authoritative, even after a setting change.
    $f = new HistoricalReservationFixture(); $run=$f->scan(); $old=$f->reserve($run,'Old/2026/09');
    $f->files->files[$old['path']]=702; $f->ack($run,$old['path']); $f->files->folders=[];
    check($f->scan()['assets'][0]['state']==='known' && $f->reserve($run,'New/2026/09')['path']===$old['path']
        && count($f->targets())===1 && $f->files->folders===[],'HR7: confirmed present old target is neither moved nor duplicated');

    // An ambiguous transfer is recoverable whenever the reserved file is present,
    // even if its original ticket has expired or was marked failed by the client.
    foreach (['pending','failed','expired'] as $status) {
        $f=new HistoricalReservationFixture(); $run=$f->scan(); $old=$f->reserve($run,'Old/2026/09');
        $f->repo->updateOwned('apc_uploads',$f->user,'upload_id',$run['assets'][0]['upload']['uploadId'],['status'=>$status]);
        $f->files->files[$old['path']]=703; $f->files->folders=[];
        $retry=$f->scan(); $recovered=$f->reserve($retry,'New/2026/09');
        check($recovered['state']==='present' && $recovered['path']===$old['path'] && count($f->targets())===1
            && $f->files->folders===[],"HR8: lost PUT/ACK recovery preserves present reservation ($status)");
        check($f->ack($retry,$old['path'])['summary']['uploaded']===1,"HR9: recovered original can be acknowledged ($status)");
    }

    // A live bound ticket protects a running transfer across competing runs.
    $f=new HistoricalReservationFixture(); $run=$f->scan(); $old=$f->reserve($run,'Old/2026/09');
    check($f->reserve($run,'New/2026/09')===$old,'HR10: same active ticket keeps its existing binding');
    $other=$f->scan();
    check($f->reserve($other,'New/2026/09')===$old && count($f->targets())===1,'HR11: a competing run cannot fork a live reservation');

    // Lazy expiration must be evaluated for other tickets, not only the caller.
    foreach (['pending','expired'] as $status) {
        $f=new HistoricalReservationFixture(); $run=$f->scan(); $f->reserve($run,'Old/2026/09');
        $f->repo->updateOwned('apc_uploads',$f->user,'upload_id',$run['assets'][0]['upload']['uploadId'],
            ['status'=>$status,'created_at'=>'2000-01-01T00:00:00Z']);
        $f->files->folders=[]; $retry=$f->scan();
        check($f->reserve($retry,'New/2026/09')['path']==='New/2026/09/photo-1.jpg'
            && !isset($f->files->folders['Old/2026/09']),"HR12: missing expired historical reservation does not pin destination ($status)");
    }

    // Reusing a failed ticket for another attempt makes its binding active again.
    $f=new HistoricalReservationFixture(); $run=$f->scan(); $old=$f->reserve($run,'Old/2026/09'); $f->ack($run,null);
    $f->reserve($run,'Old/2026/09'); $other=$f->scan();
    check($f->reserve($other,'New/2026/09')===$old && count($f->targets())===1,'HR13: restarted failed ticket protects its now-active transfer');

    // Same-destination recovery still reuses the missing path; foreign bytes at
    // an inactive historical destination are not recoverable original content.
    $f=new HistoricalReservationFixture(); $run=$f->scan(); $old=$f->reserve($run,'Old/2026/09'); $f->ack($run,null);
    $retry=$f->scan();
    check($f->reserve($retry,'Old/2026/09')===$old,'HR14: retry at unchanged destination retains its reserved filename');
    $f->ack($retry,null); $f->files->files[$old['path']]=704; $f->files->contents[$old['path']]='FOREIGN!'; $f->files->folders=[];
    $next=$f->scan();
    check($f->reserve($next,'New/2026/09')['path']==='New/2026/09/photo-1.jpg'
        && $f->files->contents[$old['path']]==='FOREIGN!' && !isset($f->files->folders['Old/2026/09']),
        'HR15: foreign content at inactive old destination is preserved without pinning a new run');

    $f=new HistoricalReservationFixture(); $run=$f->scan(); $old=$f->reserve($run,'Old/2026/09'); $f->ack($run,null);
    $f->files->files[$old['path']]=705; $f->files->readFailure=true; $f->files->folders=[]; $retry=$f->scan();
    rejects(fn()=>$f->reserve($retry,'New/2026/09'),'HR16: uncertain historical file identity aborts instead of creating a duplicate');
    check(count($f->targets())===1 && $f->files->folders===[],'HR17: verification failure creates neither target nor folders');
    $f->files->files=[]; $f->files->readFailure=false;
    rejects(fn()=>$f->prepare->prepare($f->user,$f->source['sourceId'],$retry['runId'],$retry['assets'][0]['upload']['uploadId'],9,hash('sha256','DIFFERENT'),'New/2026/09'),
        'HR18: target change cannot bypass original-content identity validation');

    $f=new HistoricalReservationFixture(7); $oldRun=$f->scan(array_slice($f->assets,0,3));
    for($i=0;$i<3;$i++){ $f->reserve($oldRun,'Old/2026/09',$i); $f->ack($oldRun,null,$i); }
    $history=$f->targets(); $f->files->folders=[]; $run=$f->scan();
    check($run['summary']===['seen'=>7,'new'=>7,'known'=>0],'HR19: seven selected assets including three historical failures get tickets');
    for($i=0;$i<7;$i++) {
        $target=$f->reserve($run,'New/2026/09',$i);
        check(str_starts_with($target['path'],'New/2026/09/') && $target['state']==='missing',"HR20: asset $i stays inside current target root before PUT");
        $f->files->files[$target['path']]=800+$i; $ack=$f->ack($run,$target['path'],$i);
    }
    check($ack['summary']===['uploaded'=>7,'failed'=>0] && count($f->files->files)===7,'HR21: all seven assets complete at current destination');
    check(!isset($f->files->folders['Old/2026/09']),'HR22a: no empty old folder');
    $currentPaths = array_column($f->targets(), 'path');
    check(count(array_intersect($currentPaths, array_column($history, 'path'))) === 3,'HR22b: historical targets retained unchanged');
    check($f->scan()['summary']===['seen'=>7,'new'=>0,'known'=>7] && count($f->targets())===10,'HR23: repeated inventory adds no duplicates');
    // Reproduce the user's deliberate deletion between runs in the fake FS only.
    $f->files->files=[]; $f->files->folders=[]; $retry=$f->scan();
    check($retry['summary']===['seen'=>7,'new'=>7,'known'=>0],'HR24: manual deletion legitimately makes all seven new again');
    for($i=0;$i<7;$i++) {
        $target=$f->reserve($retry,'New/2026/09',$i);
        check(str_starts_with($target['path'],'New/2026/09/'),"HR25: deleted asset $i does not fall back to historical root");
        $f->files->files[$target['path']]=900+$i; $ack=$f->ack($retry,$target['path'],$i);
    }
    check($ack['summary']===['uploaded'=>7,'failed'=>0] && !isset($f->files->folders['Old/2026/09']),
        'HR26: seven-asset retransfer converges without reviving old folder');
}
