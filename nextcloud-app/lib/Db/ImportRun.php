<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Db;

/** Immutable initial state of one authenticated inventory request. */
final class ImportRun {
    public const RUNNING = 'running';
    public const COMPLETED = 'completed';
    public const FAILED = 'failed';

    public function __construct(
        public readonly string $runId,
        public readonly ?string $sourceId,
        public readonly string $userId,
        public readonly string $startedAt,
        public readonly int $assetsSeen,
    ) {}

    public static function start(string $userId, ?string $sourceId, int $assetsSeen): self {
        $bytes = random_bytes(16);
        $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
        $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
        $hex = bin2hex($bytes);
        $uuid = substr($hex, 0, 8) . '-' . substr($hex, 8, 4) . '-' . substr($hex, 12, 4)
            . '-' . substr($hex, 16, 4) . '-' . substr($hex, 20);
        return new self($uuid, $sourceId, $userId, self::now(), $assetsSeen);
    }

    public static function now(): string {
        return (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))->format('Y-m-d\TH:i:s.u\Z');
    }

    public function toRow(): array {
        return [
            'run_id' => $this->runId, 'source_id' => $this->sourceId, 'user_id' => $this->userId,
            'started_at' => $this->startedAt, 'completed_at' => null, 'status' => self::RUNNING,
            'assets_seen' => $this->assetsSeen, 'assets_new' => 0, 'assets_known' => 0,
            'assets_uploaded' => 0, 'assets_failed' => 0,
            'error_code' => null,
        ];
    }
}
