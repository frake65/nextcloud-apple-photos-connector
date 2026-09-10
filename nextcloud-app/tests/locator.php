<?php
declare(strict_types=1);

function locatorScenarios(): void {
    $node = new class implements \OCP\Files\File {
        public string $bytes = '';
        public int $locks = 0;
        public bool $failOpen = false, $failLock = false;
        public function isReadable(): bool { return true; }
        public function lock(int $mode): void {
            if ($this->failLock) { throw new RuntimeException('Writer holds lock'); }
            $this->locks++;
        }
        public function unlock(int $mode): void { $this->locks--; }
        public function fopen(string $mode): mixed {
            if ($this->failOpen) { return false; }
            $stream = fopen('php://temp', 'w+b');
            fwrite($stream, $this->bytes);
            rewind($stream);
            return $stream;
        }
    };
    $root = new class($node) implements \OCP\Files\IRootFolder {
        public function __construct(private object $node) {}
        public function getUserFolder(string $user): object { return $this; }
        public function get(string $path): object { return $this->node; }
    };
    $locator = new \OCA\ApplePhotosConnector\Service\UploadedFileLocator($root);
    foreach (['', 'abc', str_repeat('abcdefgh', 400000)] as $bytes) {
        $node->bytes = $bytes;
        $actual = $locator->identity('test', 'test.jpg');
        check($actual === ['bytes' => strlen($bytes), 'sha256' => hash('sha256', $bytes)] && $node->locks === 0,
            'server hashes actual bytes across chunk boundaries and releases read lock');
    }
    $node->failOpen = true;
    try { $locator->identity('test', 'test.jpg'); throw new LogicException('Open failure ignored'); }
    catch (RuntimeException) {}
    check($node->locks === 0, 'failed content verification releases shared lock');
    $node->failOpen = false;
    $node->failLock = true;
    try { $locator->identity('test', 'test.jpg'); throw new LogicException('Write lock ignored'); }
    catch (RuntimeException $error) { check($error->getMessage() === 'Writer holds lock', 'in-progress writes cannot be misclassified as collisions'); }
}
