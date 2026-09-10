<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use OCP\Files\IRootFolder;
use OCP\Files\File;

/** Resolve through the authenticated user's filesystem, never trust a client-supplied file ID. */
class UploadedFileLocator {
    public function __construct(private IRootFolder $root) {}
    public function exists(string $user, string $path): bool {
        return $this->root->getUserFolder($user)->nodeExists($path);
    }

    /** Relative to the authenticated user's file root; never raw filesystem mkdir. */
    public function ensureFolder(string $user, string $folder): void {
        UploadTargetService::validateFolder($folder);
        $parent = $this->root->getUserFolder($user);
        foreach (explode('/', $folder) as $part) {
            $parent = $parent->getOrCreateFolder($part);
        }
    }

    /** Hold a shared lock on the same file node through verification and metadata writes. */
    public function withVerifiedFile(string $user, string $path, callable $work): mixed {
        $node = $this->root->getUserFolder($user)->get($path);
        if (!$node instanceof File || !$node->isReadable() || !$node->isUpdateable()) {
            throw new \InvalidArgumentException('Uploaded file is unavailable');
        }
        $node->lock(\OCP\Lock\ILockingProvider::LOCK_SHARED);
        try { return $work($this->readIdentity($node), (int)$node->getId()); }
        finally { $node->unlock(\OCP\Lock\ILockingProvider::LOCK_SHARED); }
    }

    /** Read the actual bytes, not ETags or unverified client-provided WebDAV checksums. */
    public function identity(string $user, string $path): array {
        $node = $this->root->getUserFolder($user)->get($path);
        if (!$node instanceof File) { return ['bytes' => -1, 'sha256' => str_repeat('0', 64)]; }
        if (!$node->isReadable()) { throw new \InvalidArgumentException('Cannot verify target contents'); }
        // Do not mistake a concurrent/incomplete write for a foreign file and select another path.
        $node->lock(\OCP\Lock\ILockingProvider::LOCK_SHARED);
        try { return $this->readIdentity($node); }
        finally { $node->unlock(\OCP\Lock\ILockingProvider::LOCK_SHARED); }
    }

    private function readIdentity(File $node): array {
        $stream = $node->fopen('rb');
        if (!is_resource($stream)) { throw new \RuntimeException('Cannot read target'); }
        $hash = hash_init('sha256');
        $bytes = 0;
        try {
            while (!feof($stream)) {
                $chunk = fread($stream, 1048576);
                if ($chunk === false || ($chunk === '' && !feof($stream))) { throw new \RuntimeException('Incomplete target read'); }
                $bytes += strlen($chunk);
                hash_update($hash, $chunk);
            }
        } finally { fclose($stream); }
        return ['bytes' => $bytes, 'sha256' => hash_final($hash)];
    }
    public function fileId(string $user, string $path): int {
        $node = $this->root->getUserFolder($user)->get($path);
        if (!$node instanceof File || !$node->isReadable() || !$node->isUpdateable()) {
            throw new \InvalidArgumentException('Uploaded file is unavailable');
        }
        return (int)$node->getId();
    }
}
