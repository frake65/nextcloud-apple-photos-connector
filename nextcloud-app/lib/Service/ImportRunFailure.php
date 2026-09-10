<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

/** Preserve both the audit correlation and the original error for HTTP classification. */
final class ImportRunFailure extends \RuntimeException {
    public function __construct(public readonly string $runId, \Throwable $previous) {
        parent::__construct('Inventory run failed', 0, $previous);
    }
}
