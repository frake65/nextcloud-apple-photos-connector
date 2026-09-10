<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\{AssetIdentity,InventoryService,InventoryValidator,UploadTargetService,UploadService,UploadTicketPolicy};

function ticketLifecycleScenarios(): void {
    $pdo = freshDatabase(); $repo = new InventoryRepository(new TestHarness\Connection($pdo)); $files = new TestFiles();
    $user='ticket'; $source=['sourceId'=>'cc008000-0000-4000-8000-000000000001','name'=>'Ticket']; $assets=[['localIdentifier'=>'one','filename'=>'one.jpg','mediaType'=>'image']];
    $inventory = new InventoryService($repo,new AssetIdentity(),new InventoryValidator(),$files); $reply=$inventory->ingest($user,$source,$assets); $ticket=$reply['assets'][0]['upload'];
    $now = new DateTimeImmutable('2026-01-02T00:00:00Z'); $fresh = new UploadTicketPolicy($now);
    $repo->updateOwned('apc_uploads',$user,'upload_id',$ticket['uploadId'],['created_at'=>'2026-01-01T00:00:01Z']);
    (new UploadTargetService($repo,$files,$fresh))->prepare($user,$source['sourceId'],$reply['runId'],$ticket['uploadId'],8,hash('sha256','ORIGINAL'));
    check($repo->uploads($user,$source['sourceId'])[0]['status']==='pending','X1: fresh pending ticket valid');
    $repo->updateOwned('apc_uploads',$user,'upload_id',$ticket['uploadId'],['created_at'=>'2026-01-01T00:00:00Z']);
    $inside = new UploadTicketPolicy(new DateTimeImmutable('2026-01-01T23:59:59Z'));
    (new UploadTargetService($repo,$files,$inside))->prepare($user,$source['sourceId'],$reply['runId'],$ticket['uploadId'],8,hash('sha256','ORIGINAL'));
    check(true,'X2: ticket just inside TTL valid');
    $expired = new UploadTicketPolicy(new DateTimeImmutable('2026-01-02T00:00:00Z'));
    try { (new UploadTargetService($repo,$files,$expired))->prepare($user,$source['sourceId'],$reply['runId'],$ticket['uploadId'],8,hash('sha256','ORIGINAL')); throw new LogicException('expired ticket accepted'); } catch (InvalidArgumentException) { check($repo->uploads($user,$source['sourceId'])[0]['status']==='expired','X3/X4: expired ticket atomically marked and rejected'); }
    try { (new UploadService($repo,$files,$expired))->acknowledge($user,$source['sourceId'],$reply['runId'],$ticket['uploadId'],'uploaded','Photos/test.jpg'); throw new LogicException('expired complete accepted'); } catch (InvalidArgumentException) { check(true,'X6/X7: expired ticket cannot complete or recover'); }
    $retry=$inventory->ingest($user,$source,$assets); check($retry['assets'][0]['state']==='new','L2/L3/X12: new inventory creates a new ticket despite old expired ticket');
    $newTicket=$retry['assets'][0]['upload']; $repo->updateOwned('apc_uploads',$user,'upload_id',$newTicket['uploadId'],['created_at'=>'2026-01-01T00:00:00Z']);
    $validLater=new UploadTicketPolicy(new DateTimeImmutable('2026-01-01T12:00:00Z')); (new UploadTargetService($repo,$files,$validLater))->prepare($user,$source['sourceId'],$retry['runId'],$newTicket['uploadId'],8,hash('sha256','ORIGINAL')); check(true,'L4/L5/L6: independent valid ticket unaffected by old ticket');
    check(UploadTicketPolicy::TTL_SECONDS===86400,'L1/L7: central 24 hour policy');
}
