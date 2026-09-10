<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

/** Apply only to assets already scoped to one user/source. Strings are opaque and case-sensitive. */
class AssetIdentity {
    public function key(?string $cloudIdentifier, string $localIdentifier): string {
        return $cloudIdentifier !== null ? 'cloud:' . $cloudIdentifier : 'local:' . $localIdentifier;
    }

    /** A request without cloud ID can match a previously cloud-backed observation. */
    public function lookupKeys(?string $cloudIdentifier, string $localIdentifier): array {
        return array_unique([$this->key($cloudIdentifier, $localIdentifier), $this->key(null, $localIdentifier)]);
    }
}
