<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\AssetIdentity;
use OCA\ApplePhotosConnector\Service\InventoryService;
use OCA\ApplePhotosConnector\Service\InventoryValidator;
use OCA\ApplePhotosConnector\Service\ImportRunFailure;

function check(bool $condition, string $message): void {
    if (!$condition) { throw new RuntimeException($message); }
    echo "PASS: $message\n";
}

function scenarios(InventoryRepository $repository): void {
    $service = new InventoryService($repository, new AssetIdentity(), new InventoryValidator(), testUploadedFileLocator());
    $user = 'test-' . bin2hex(random_bytes(6));
    $source = ['sourceId' => '550E8400-E29B-41D4-A716-446655440000', 'name' => 'Test Photos', 'createdAt' => '2020-01-01T00:00:00Z'];
    $id = strtolower($source['sourceId']);
    $asset = ['localIdentifier' => 'local/one', 'cloudIdentifier' => 'opaque:cloud-one', 'filename' => 'Midsommar.jpg', 'mediaType' => 'image', 'creationDate' => null];
    // Identity regressions use already-uploaded fixtures between inventories.
    // Real acknowledgement and retry behavior is exercised separately in uploads.php.
    $run = function (array $assets, ?array $s = null, ?string $u = null) use ($service, $repository, $user, $source): array {
        $owner = $u ?? $user;
        $sourceValue = $s ?? $source;
        $response = $service->ingest($owner, $sourceValue, $assets)['assets'];
        foreach ($repository->assets($owner, strtolower($sourceValue['sourceId'])) as $row) {
            if ($row['nextcloud_file_id'] === null) {
                testMarkImported($repository, $owner, strtolower($sourceValue['sourceId']), $row);
            }
        }
        return array_map(fn ($entry) => ['cloudIdentifier' => $entry['cloudIdentifier'], 'state' => $entry['state']], $response);
    };
    check($run([$asset])[0]['state'] === 'new', 'new source and asset are new');
    $original = $repository->assets($user, $id)[0];
    check($run([$asset])[0]['state'] === 'known', 'repeated scan is known');
    $seen = $repository->assets($user, $id)[0];
    check($seen['first_seen_at'] === $original['first_seen_at'] && $seen['last_seen_at'] >= $original['last_seen_at'], 'first_seen retained and last_seen updated');
    $second = array_replace($asset, ['localIdentifier' => 'local/two', 'cloudIdentifier' => 'opaque:cloud-two']);
    check(array_column($run([$asset, $second]), 'state') === ['known', 'new'], 'only second asset is new');
    $beforeOmission = $repository->assets($user, $id);
    $run([$second]);
    $afterOmission = $repository->assets($user, $id);
    check(count($afterOmission) === 2 && $afterOmission[0] === $beforeOmission[0], 'omitted asset remains completely unchanged in DB');
    $source2 = array_replace($source, ['sourceId' => '550e8400-e29b-41d4-a716-446655440001']);
    check($run([$asset], $source2)[0]['state'] === 'new', 'same cloud identifier in different source stays new');
    $local = array_replace($asset, ['cloudIdentifier' => null]);
    $source3 = array_replace($source, ['sourceId' => '550e8400-e29b-41d4-a716-446655440002']);
    $source4 = array_replace($source, ['sourceId' => '550e8400-e29b-41d4-a716-446655440003']);
    check($run([$local], $source3)[0]['state'] === 'new' && $run([$local], $source4)[0]['state'] === 'new', 'same local identifier in different sources stays separate');
    check($run([$local], $source3)[0] === ['cloudIdentifier' => null, 'state' => 'known'], 'local fallback returns known and null cloud identifier');
    check($run([array_replace($asset, ['localIdentifier' => 'another-mac/id'])])[0]['state'] === 'known', 'cloud identity wins over changed local identifier');
    check($run([$local])[0]['state'] === 'known', 'missing cloud identifier can find an earlier cloud-backed observation');
    check($run([array_replace($asset, ['cloudIdentifier' => 'different-cloud'])])[0]['state'] === 'new', 'different cloud identifier is not merged by local identifier');
    check($run([$asset], null, $user . '-other')[0]['state'] === 'new', 'different authenticated users remain isolated');
    $third = array_replace($asset, ['localIdentifier' => 'three', 'cloudIdentifier' => 'third']);
    check(array_column($run([$third, $third]), 'state') === ['new', 'new'], 'duplicates remain new until upload confirmation');
    $beforeInvalid = $repository->assets($user, $id);
    $beforeSource = $repository->source($user, $id);
    try {
        $run([$second, array_replace($asset, ['mediaType' => 'invalid'])]);
        throw new RuntimeException('invalid request accepted');
    } catch (ImportRunFailure $error) {
        check($error->getPrevious() instanceof InvalidArgumentException, 'validation cause preserved with run ID');
    }
    check($repository->assets($user, $id) === $beforeInvalid && $repository->source($user, $id) === $beforeSource, 'invalid request does not partially write');
    $run([], array_replace($source, ['name' => 'Renamed', 'createdAt' => '2025-01-01T00:00:00Z']));
    $updated = $repository->source($user, $id);
    check($updated['name'] === 'Renamed' && $updated['created_at'] === $beforeSource['created_at'] && $updated['last_seen_at'] >= $beforeSource['last_seen_at'], 'source name/last_seen updated and created_at retained');
    check($repository->assets($user, $id) === $beforeInvalid, 'empty inventory leaves every asset untouched');
    try {
        $repository->transaction(function () use ($repository, $user, $id): void {
            $repository->touchSource($user, $id, 'Must roll back', '2099-01-01T00:00:00Z');
            throw new RuntimeException('injected failure');
        });
    } catch (RuntimeException) {}
    check($repository->source($user, $id) === $updated, 'database failure rolls back transaction');
    foreach (['not-a-date', '2026-02-30T00:00:00Z'] as $invalidDate) {
        try {
            $run([array_replace($asset, ['creationDate' => $invalidDate])]);
            throw new RuntimeException('invalid date accepted');
        } catch (ImportRunFailure $error) {
            check($error->getPrevious() instanceof InvalidArgumentException, 'date validation cause preserved');
        }
    }
    check($repository->source($user, $id) === $updated, 'invalid dates rejected before writes');
    $localOnlySource = array_replace($source, ['sourceId' => '550e8400-e29b-41d4-a716-446655440004']);
    $run([$local], $localOnlySource);
    check($run([$asset], $localOnlySource)[0]['state'] === 'new', 'new cloud identity does not automatically merge a local-only record');
}
