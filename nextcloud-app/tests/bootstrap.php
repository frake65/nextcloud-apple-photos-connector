<?php
declare(strict_types=1);
spl_autoload_register(static function (string $class): void {
    $prefix = 'OCA\\ApplePhotosConnector\\';
    if (str_starts_with($class, $prefix)) {
        require __DIR__ . '/../lib/' . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
    }
});

final class TestNullUserFolder {
    public function nodeExists(string $path): bool { return str_contains($path, '/fixture-'); }
    public function get(string $path): mixed { throw new \RuntimeException('test target is absent'); }
}
final class TestNullRootFolder implements \OCP\Files\IRootFolder {
    public function getUserFolder(string $user): TestNullUserFolder { return new TestNullUserFolder(); }
}
function testUploadedFileLocator(): \OCA\ApplePhotosConnector\Service\UploadedFileLocator {
    return new \OCA\ApplePhotosConnector\Service\UploadedFileLocator(new TestNullRootFolder());
}

/** Synthetic successful-import fixture, with explicit current target rather than cache authority. */
function testMarkImported(\OCA\ApplePhotosConnector\Db\InventoryRepository $repo, string $user, string $source, array $asset): void {
    $path = 'Photos/Apple Photos Connector/fixture-' . $asset['id'] . '.jpg';
    $id = $repo->insertTarget(['user_id'=>$user,'source_id'=>$source,'asset_id'=>$asset['id'],
        'filename'=>'fixture-'.$asset['id'].'.jpg','path'=>$path,'path_key'=>hash('sha256',$path),
        'bytes'=>8,'sha256'=>hash('sha256','ORIGINAL'),'attempt'=>0]);
    $repo->setCurrentTarget($user,$source,(int)$asset['id'],$id);
    $repo->updateOwned('apc_assets',$user,'id',$asset['id'],['nextcloud_file_id'=>$asset['id'],'nextcloud_path'=>$path,'uploaded_at'=>'2026-01-01T00:00:00Z']);
}
