<?php
declare(strict_types=1);
// Run against an extracted archive: php tests/package.php STAGING_PARENT.
$stage = $argv[1] ?? '';
$root = $stage . '/apple_photos_connector';
if (!is_dir($root)) throw new RuntimeException('Extract a test archive first');
$checker = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/../tools/check-package.php') . ' ' . escapeshellarg($stage);
exec($checker . ' 2>&1', $baselineOutput, $baselineCode);
if ($baselineCode !== 0) throw new RuntimeException('Valid baseline package rejected');
function rejected(string $stage): void {
    $command = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/../tools/check-package.php') . ' ' . escapeshellarg($stage);
    exec($command . ' 2>&1', $output, $code);
    if ($code === 0) throw new RuntimeException('Invalid package accepted');
}
foreach (['.DS_Store', '._junk', 'signing.key', 'secret.txt', 'signing.crt', 'signing.cer', 'signing.der', 'AlbumTestResolveCommand.php', 'AlbumTestAddMembershipCommand.php', 'AlbumTestService.php', 'AlbumMembershipTestService.php', 'build-package.sh', 'check-package.sh'] as $name) {
    $path = "$root/$name";
    if (file_exists($path)) throw new RuntimeException('Fixture path already exists');
    file_put_contents($path, $name === 'secret.txt' ? '-----BEGIN PRIVATE KEY-----' : 'fixture');
    try { rejected($stage); } finally { unlink($path); }
}
mkdir("$stage/unexpected");
try { rejected($stage); } finally { rmdir("$stage/unexpected"); }
foreach (['LICENSE', 'CHANGELOG.md', 'appinfo/info.xml'] as $name) {
    $path = "$root/$name";
    $original = file_get_contents($path);
    file_put_contents($path, '');
    try { rejected($stage); } finally { file_put_contents($path, $original); }
}
$path = "$root/appinfo/info.xml";
$original = file_get_contents($path);
foreach (['<id>apple_photos_connector</id>' => '<id>wrong</id>', '<version>0.8.7</version>' => '<version>9.0.0</version>'] as $from => $to) {
    file_put_contents($path, str_replace($from, $to, $original));
    try { rejected($stage); } finally { file_put_contents($path, $original); }
}
echo "PASS: 19 invalid package scenarios rejected\n";
