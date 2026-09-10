<?php
declare(strict_types=1);
$count = 0;
foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator(dirname(__DIR__))) as $file) {
    if ($file->getExtension() === 'php') {
        token_get_all(file_get_contents($file->getPathname()), TOKEN_PARSE);
        $count++;
    }
}
echo "PASS: PHP syntax ($count files)\n";
