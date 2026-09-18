<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

final class AlbumSyncDiagnosticException extends \RuntimeException {
    /** @param array<string, scalar|null> $context */
    public function __construct(
        public readonly string $stage,
        \Throwable $cause,
        public readonly array $context = [],
    ) {
        parent::__construct($cause->getMessage(), 0, $cause);
    }

    /** @param array<string, scalar|null> $context */
    public static function wrap(string $stage, \Throwable $cause, array $context = []): self {
        if ($cause instanceof self) {
            return $cause;
        }
        return new self($stage, $cause, $context);
    }
}
