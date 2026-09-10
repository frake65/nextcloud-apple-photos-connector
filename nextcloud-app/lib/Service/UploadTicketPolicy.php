<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

final class UploadTicketPolicy {
    public const TTL_SECONDS = 86400;
    public const EXPIRED = 'expired';

    public function __construct(private readonly \DateTimeImmutable $now) {}

    public static function live(): self { return new self(new \DateTimeImmutable('now', new \DateTimeZone('UTC'))); }

    public function expired(string $createdAt): bool {
        $created = new \DateTimeImmutable($createdAt, new \DateTimeZone('UTC'));
        return $created->getTimestamp() + self::TTL_SECONDS <= $this->now->getTimestamp();
    }
}
