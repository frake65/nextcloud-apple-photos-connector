<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\ImportRun;
use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\AssetIdentity;
use OCA\ApplePhotosConnector\Service\ImportRunFailure;
use OCA\ApplePhotosConnector\Service\InventoryService;
use OCA\ApplePhotosConnector\Service\InventoryValidator;

function runScenarios(InventoryRepository $repository): void {
    $service = new InventoryService($repository, new AssetIdentity(), new InventoryValidator(), testUploadedFileLocator());
    $user = 'run-test-' . bin2hex(random_bytes(6));
    $source = ['sourceId' => '650e8400-e29b-41d4-a716-446655440000', 'name' => 'Run tests'];
    $sourceId = $source['sourceId'];
    $asset = ['localIdentifier' => 'one', 'cloudIdentifier' => 'cloud-one', 'filename' => 'test.jpg', 'mediaType' => 'image'];
    $first = $service->ingest($user, $source, [$asset]);
    $row = $repository->run($user, $first['runId']);
    check((bool)preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/D', $first['runId']), 'runId is a server-generated UUID v4');
    check($first['summary'] === ['seen' => 1, 'new' => 1, 'known' => 0] && $row['status'] === 'completed'
        && (int)$row['assets_seen'] === 1 && (int)$row['assets_new'] === 1 && (int)$row['assets_known'] === 0, 'new inventory persists completed run and matching counters');
    check($row['user_id'] === $user && $row['source_id'] === $sourceId && $row['completed_at'] >= $row['started_at']
        && $row['error_code'] === null, 'completed run has ownership, source and both timestamps');
    $assetRow = $repository->assets($user, $sourceId)[0];
    testMarkImported($repository, $user, strtolower($source['sourceId']), $assetRow);
    $second = $service->ingest($user, $source, [$asset]);
    $secondRow = $repository->run($user, $second['runId']);
    check($second['summary'] === ['seen' => 1, 'new' => 0, 'known' => 1] && (int)$secondRow['assets_known'] === 1, 'second run records known asset');
    check($first['runId'] !== $second['runId'] && count($repository->runs($user, $sourceId)) === 2, 'same source creates exactly one distinct run per request');
    check($repository->run($user, $first['runId']) === $row, 'later scan does not alter previous run');
    $beforeEmpty = $repository->assets($user, $sourceId);
    $empty = $service->ingest($user, $source, []);
    check($empty['summary'] === ['seen' => 0, 'new' => 0, 'known' => 0] && $empty['assets'] === []
        && $repository->run($user, $empty['runId'])['status'] === 'completed', 'empty inventory creates completed zero-count run');
    check($repository->assets($user, $sourceId) === $beforeEmpty, 'empty run leaves all stored asset fields untouched');
    $other = $service->ingest($user . '-other', $source, [$asset]);
    check($repository->run($user, $other['runId']) === null && $repository->run($user . '-other', $first['runId']) === null, 'run lookup cannot cross user boundaries');
    check(count($repository->runs($user, $sourceId)) === 3 && count($repository->runs($user . '-other', $sourceId)) === 1, 'source run lists are isolated by user');
    $repository->failRun($user . '-other', $first['runId'], 99, 'processing_error');
    check($repository->run($user, $first['runId']) === $row, 'run updates cannot cross user boundaries');
    $beforeInvalidSource = $repository->source($user, $sourceId);
    try {
        $service->ingest($user, $source, [array_replace($asset, ['mediaType' => 'invalid'])]);
        throw new RuntimeException('validation unexpectedly succeeded');
    } catch (ImportRunFailure $failure) {
        $failed = $repository->run($user, $failure->runId);
        check($failure->getPrevious() instanceof InvalidArgumentException && $failed['status'] === 'failed'
            && $failed['completed_at'] !== null && $failed['error_code'] === 'validation_error', 'validation failure remains persisted and correlated to error');
        check((int)$failed['assets_seen'] === 1 && (int)$failed['assets_new'] === 0 && (int)$failed['assets_known'] === 0, 'failed run counts submitted assets without committed classifications');
    }
    check(count($repository->runs($user, $sourceId)) === 4 && $repository->assets($user, $sourceId) === $beforeEmpty
        && $repository->source($user, $sourceId) === $beforeInvalidSource, 'failed request adds exactly one run without changing inventory');
    $duplicate = $service->ingest($user, $source, [array_replace($asset, ['cloudIdentifier' => 'cloud-two']), array_replace($asset, ['cloudIdentifier' => 'cloud-two'])]);
    check($duplicate['summary'] === ['seen' => 2, 'new' => 2, 'known' => 0]
        && $duplicate['assets'][0]['upload'] === $duplicate['assets'][1]['upload'], 'duplicate new entries share one upload ticket');

    $pending = ImportRun::start($user, $sourceId, 0);
    $repository->transaction(fn () => $repository->insertRun($pending));
    $repository->failRun($user . '-other', $pending->runId, 99, 'processing_error');
    check($repository->run($user, $pending->runId)['status'] === 'running', 'another user cannot fail a running run');
    try {
        $repository->completeRun($user . '-other', $pending->runId, 0, 0, 0);
        throw new LogicException('cross-user completion unexpectedly succeeded');
    } catch (RuntimeException) {
        check($repository->run($user, $pending->runId)['status'] === 'running', 'another user cannot complete a running run');
    }
    $repository->failRun($user, $pending->runId, 0, 'processing_error');
    check($repository->run($user, $pending->runId)['status'] === 'failed', 'owner can finalize the same running run');
}

/** Real repository/transactions; faults are injected only at explicit persistence boundaries. */
class FaultingRunRepository extends InventoryRepository {
    public ?array $observedRunning = null;
    public ?string $createdRunId = null;
    private int $transactions = 0;
    public function __construct(\OCP\IDBConnection $db, private string $stage) { parent::__construct($db); }

    public function insertRun(ImportRun $run): void {
        $this->createdRunId = $run->runId;
        if ($this->stage === 'creation') { throw new RuntimeException('injected creation failure'); }
        parent::insertRun($run);
    }

    public function completeRun(string $user, string $runId, int $seen, int $new, int $known): void {
        $this->observedRunning = $this->run($user, $runId);
        parent::completeRun($user, $runId, $seen, $new, $known);
        if (in_array($this->stage, ['completion', 'audit'], true)) { throw new RuntimeException('injected completion failure'); }
    }

    public function failRun(string $user, string $runId, int $seen, string $errorCode): void {
        if ($this->stage === 'audit') { throw new RuntimeException('injected audit failure'); }
        parent::failRun($user, $runId, $seen, $errorCode);
    }

    public function transaction(callable $work): mixed {
        $number = ++$this->transactions;
        $result = parent::transaction($work);
        if ($this->stage === 'acknowledgement' && $number === 2) { throw new RuntimeException('injected lost commit acknowledgement'); }
        return $result;
    }
}

function runFailureScenarios(\OCP\IDBConnection $db): void {
    $source = ['sourceId' => '750e8400-e29b-41d4-a716-446655440000', 'name' => 'Rollback tests'];
    $asset = ['localIdentifier' => 'one', 'cloudIdentifier' => 'cloud-one', 'mediaType' => 'image'];
    foreach (['completion', 'audit', 'acknowledgement', 'creation'] as $stage) {
        $user = 'fault-' . $stage . '-' . bin2hex(random_bytes(4));
        $repository = new FaultingRunRepository($db, $stage);
        $service = new InventoryService($repository, new AssetIdentity(), new InventoryValidator(), testUploadedFileLocator());
        try {
            $service->ingest($user, $source, [$asset]);
            throw new LogicException('fault injection did not run');
        } catch (ImportRunFailure $failure) {
            check($failure->getPrevious()->getMessage() === ($stage === 'acknowledgement' ? 'injected lost commit acknowledgement' : 'injected completion failure'), "$stage: original error preserved");
            $run = $repository->run($user, $failure->runId);
            check(count($repository->runs($user, $source['sourceId'])) === 1, "$stage: exactly one persistent run");
            check($repository->observedRunning['status'] === 'running' && $repository->observedRunning['completed_at'] === null, "$stage: running exists before atomic completion");
            if ($stage === 'acknowledgement') {
                check($run['status'] === 'completed' && (int)$run['assets_new'] === 1 && count($repository->assets($user, $source['sourceId'])) === 1, 'lost acknowledgement never relabels committed inventory as failed');
            } else {
                check($repository->source($user, $source['sourceId']) === null && $repository->assets($user, $source['sourceId']) === [], "$stage: new source and assets rolled back together");
                check($run['status'] === ($stage === 'audit' ? 'running' : 'failed') && (int)$run['assets_new'] === 0 && (int)$run['assets_known'] === 0, "$stage: audit status reflects only committed state");
            }
        } catch (RuntimeException $error) {
            check($stage === 'creation' && $error->getMessage() === 'injected creation failure', 'initial run creation failure is reported');
            check($repository->runs($user, $source['sourceId']) === [] && $repository->source($user, $source['sourceId']) === null, 'unavailable run storage prevents inventory processing');
        }
    }

    // Rollback must also undo updates to previously existing records, not just new inserts.
    $user = 'existing-rollback-' . bin2hex(random_bytes(4));
    $normal = new InventoryRepository($db);
    (new InventoryService($normal, new AssetIdentity(), new InventoryValidator(), testUploadedFileLocator()))->ingest($user, $source, [$asset]);
    $beforeAssets = $normal->assets($user, $source['sourceId']);
    $beforeSource = $normal->source($user, $source['sourceId']);
    $fault = new FaultingRunRepository($db, 'completion');
    try {
        (new InventoryService($fault, new AssetIdentity(), new InventoryValidator(), testUploadedFileLocator()))->ingest($user, array_replace($source, ['name' => 'Must roll back']), [$asset, array_replace($asset, ['cloudIdentifier' => 'two'])]);
        throw new LogicException('fault injection did not run');
    } catch (ImportRunFailure $failure) {
        check($normal->assets($user, $source['sourceId']) === $beforeAssets && $normal->source($user, $source['sourceId']) === $beforeSource, 'completion failure restores existing source/asset values and removes uncommitted inserts');
        check($normal->run($user, $failure->runId)['status'] === 'failed', 'rollback of existing inventory still retains failed run');
    }
}
