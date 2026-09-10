<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\UploadTargetService;
use OCA\ApplePhotosConnector\Service\UploadService;

function recoveryScenarios(InventoryRepository $repo): void {
    $user = 'recovery-' . bin2hex(random_bytes(4));
    $source = ['sourceId' => 'a50e8400-e29b-41d4-a716-446655440000', 'name' => 'Recovery'];
    $asset = ['localIdentifier' => 'one', 'cloudIdentifier' => 'recovery-one', 'filename' => 'test.jpg', 'mediaType' => 'image'];
    $inventory = new \OCA\ApplePhotosConnector\Service\InventoryService($repo, new \OCA\ApplePhotosConnector\Service\AssetIdentity(), new \OCA\ApplePhotosConnector\Service\InventoryValidator(), testUploadedFileLocator());
    $files = new TestFiles();
    $first = $inventory->ingest($user, $source, [$asset]);
    $hash = hash('sha256', 'ORIGINAL');
    $prepare = fn ($reply) => (new UploadTargetService($repo, $files))->prepare($user, $source['sourceId'], $reply['runId'], $reply['assets'][0]['upload']['uploadId'], 8, $hash);
    $target = $prepare($first);
    check($target['state'] === 'missing' && $target['path'] === 'Photos/Apple Photos Connector/test.jpg', 'target reserved before first PUT');
    $files->files[$target['path']] = 601; // PUT succeeded, but no success response or acknowledgement arrived.
    $later = $inventory->ingest($user, $source, [$asset]);
    $recovered = $prepare($later); // A fresh service instance, new run, same persistent asset reservation.
    check($recovered['state'] === 'present' && $recovered['path'] === $target['path']
        && count($repo->targets($user, $source['sourceId'])) === 1 && count($files->files) === 1,
        'new run recovers successful PUT with lost response by size and SHA-256 without another file');
    $files->readFailure = true;
    try { $prepare($later); throw new LogicException('Read failure ignored'); }
    catch (RuntimeException $error) { check($error->getMessage() === 'injected target read failure', 'unclear target read aborts recovery'); }
    check($repo->targets($user, $source['sourceId'])[0]['path'] === $target['path'], 'unknown verification outcome never advances collision target');
    $files->readFailure = false;
    $files->contents[$target['path']] = 'FOREIGN!'; // Same length, different contents.
    try {
        (new UploadService($repo, $files))->acknowledge($user, $source['sourceId'], $later['runId'], $later['assets'][0]['upload']['uploadId'], 'uploaded', $target['path']);
        throw new LogicException('Wrong content confirmed');
    } catch (InvalidArgumentException) {}
    check($repo->assets($user, $source['sourceId'])[0]['nextcloud_file_id'] === null, 'same-size wrong hash cannot be linked');
    $collision = $prepare($later);
    check($collision['state'] === 'missing' && $collision['path'] !== $target['path'] && $files->contents[$target['path']] === 'FOREIGN!', 'confirmed foreign content selects deterministic suffix without overwrite');
    $again = $prepare($later);
    check($again === $collision, 'truly failed PUT reuses reserved missing path');
    $files->files[$collision['path']] = 602;
    $ack = (new UploadService($repo, $files))->acknowledge($user, $source['sourceId'], $later['runId'], $later['assets'][0]['upload']['uploadId'], 'uploaded', $collision['path']);
    check($ack['summary']['uploaded'] === 1, 'verified recovered content can be linked and counted');

    // Another source with identical bytes must not adopt another asset's file/reservation.
    $other = array_replace($source, ['sourceId' => 'a50e8400-e29b-41d4-a716-446655440001']);
    $otherRun = $inventory->ingest($user, $other, [$asset]);
    $otherTarget = (new UploadTargetService($repo, $files))->prepare($user, $other['sourceId'], $otherRun['runId'], $otherRun['assets'][0]['upload']['uploadId'], 8, $hash);
    check($otherTarget['state'] === 'missing' && $otherTarget['path'] !== $collision['path'], 'identical contents in different sources remain separate');
    foreach ([[$user . '-other', 8, $hash], [$user, 9, $hash], [$user, 8, str_repeat('0', 64)]] as [$owner, $bytes, $digest]) {
        try {
            (new UploadTargetService($repo, $files))->prepare($owner, $source['sourceId'], $later['runId'], $later['assets'][0]['upload']['uploadId'], $bytes, $digest);
            throw new LogicException('Changed identity or foreign user accepted');
        } catch (InvalidArgumentException) {}
    }
    check(count($repo->targets($user, $source['sourceId'])) === 2, 'foreign user and changed original identity cannot replace reservation');
}
