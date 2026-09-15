<?php
declare(strict_types=1);
function fail(string $message): never { fwrite(STDERR, "Package rejected: $message\n"); exit(1); }
$parent = $argv[1] ?? '';
if (!is_dir($parent)) fail('staging parent not found');
if (array_values(array_diff(scandir($parent), ['.', '..'])) !== ['apple_photos_connector']) fail('expected exactly one apple_photos_connector directory');
$root = $parent . '/apple_photos_connector';
if (!is_dir($root) || is_link($root)) fail('app root must be a real directory');
foreach (['appinfo/info.xml', 'LICENSE', 'CHANGELOG.md'] as $file) {
    if (!is_file("$root/$file") || filesize("$root/$file") === 0) fail("missing or empty $file");
}
libxml_use_internal_errors(true);
$xml = new DOMDocument();
if (!$xml->load($root . '/appinfo/info.xml', LIBXML_NONET) || $xml->doctype !== null) fail('invalid XML or forbidden DOCTYPE');
$xpath = new DOMXPath($xml);
foreach (['id' => 'apple_photos_connector', 'version' => '0.8.2', 'licence' => 'AGPL-3.0-or-later'] as $key => $value) {
    if ($xpath->evaluate("string(/info/$key)") !== $value) fail("unexpected $key");
}
if (($argv[2] ?? '') !== '' && !$xml->schemaValidate($argv[2])) fail('info.xml does not validate against supplied XSD');
$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST);
foreach ($files as $file) {
    $name = $file->getFilename();
    if ($file->isLink()) fail('symbolic links are not allowed');
    if ($name === '.DS_Store' || str_starts_with($name, '._') || in_array($name, ['.git', '.build', 'tests', 'tools'], true)) fail("unwanted entry: $name");
    if (in_array($name, ['AlbumTestResolveCommand.php', 'AlbumTestAddMembershipCommand.php', 'AlbumTestService.php', 'AlbumMembershipTestService.php', 'build-package.sh', 'check-package.sh'], true)) fail("development artifact: $name");
    if (preg_match('/\.(key|p12|pfx|pem|csr|crt|cer|der)$/i', $name) || preg_match('/^id_(rsa|dsa|ecdsa|ed25519)$/', $name)) fail("key/certificate material: $name");
    if ($file->isFile() && preg_match('/-----BEGIN (?:CERTIFICATE|(?:NEW )?CERTIFICATE REQUEST)-----/', file_get_contents($file->getPathname()))) fail("certificate/CSR content: $name");
    if ($file->isFile() && preg_match('/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/', file_get_contents($file->getPathname()))) fail("private key content: $name");
}
echo "Package checks passed.\n";
