<?php
declare(strict_types=1);
// Static checks against ONLY an extracted release; not a Nextcloud bootstrap substitute.
$root = ($argv[1] ?? '') . '/apple_photos_connector';
$composer = json_decode(file_get_contents($root . '/composer.json'), true, 512, JSON_THROW_ON_ERROR);
$prefix = 'OCA\\ApplePhotosConnector\\';
if (($composer['autoload']['psr-4'][$prefix] ?? null) !== 'lib/') throw new RuntimeException('Unexpected PSR-4 mapping');
$count = 0;
foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS)) as $file) {
    if ($file->getExtension() !== 'php') continue;
    $source = file_get_contents($file->getPathname());
    exec(escapeshellarg(PHP_BINARY) . ' -l ' . escapeshellarg($file->getPathname()) . ' 2>&1', $output, $status);
    if ($status !== 0) throw new RuntimeException('Invalid PHP: ' . $file);
    foreach (token_get_all($source) as $token) {
        if (is_array($token) && in_array($token[0], [T_REQUIRE, T_REQUIRE_ONCE, T_INCLUDE, T_INCLUDE_ONCE], true)) throw new RuntimeException('Include requires manual review: ' . $file);
    }
    if (str_contains($file->getPathname(), '/lib/')) {
        preg_match('/namespace\s+([^;]+);/', $source, $namespace);
        preg_match('/(?:class|interface|trait)\s+(\w+)/', $source, $class);
        $fqcn = ($namespace[1] ?? '') . '\\' . ($class[1] ?? '');
        $expected = $root . '/lib/' . str_replace('\\', '/', substr($fqcn, strlen($prefix))) . '.php';
        if (!str_starts_with($fqcn, $prefix) || $expected !== $file->getPathname()) throw new RuntimeException('PSR-4 mismatch: ' . $file);
        $count++;
    }
    preg_match_all('/use\s+(OCA\\\\ApplePhotosConnector\\\\[A-Za-z0-9_\\\\]+)\s*;/', $source, $imports);
    foreach ($imports[1] as $import) {
        if (!is_file($root . '/lib/' . str_replace('\\', '/', substr($import, strlen($prefix))) . '.php')) throw new RuntimeException('Missing internal import: ' . $import);
    }
}
$xml = simplexml_load_file($root . '/appinfo/info.xml');
foreach ($xml->commands->command as $command) {
    $name = ltrim((string)$command, '\\');
    if (!str_starts_with($name, $prefix) || !is_file($root . '/lib/' . str_replace('\\', '/', substr($name, strlen($prefix))) . '.php')) throw new RuntimeException('Missing registered command');
}
echo "PASS: extracted package syntax, $count PSR-4 classes, internal imports, commands and no runtime includes\n";
