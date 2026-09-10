<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

final class AlbumIdentity {
    public static function key(?string $cloudIdentifier, string $localIdentifier): string {
        return $cloudIdentifier !== null && $cloudIdentifier !== ''
            ? 'cloud:' . $cloudIdentifier
            : 'local:' . $localIdentifier;
    }
}
