<?php
declare(strict_types=1);
function namespaceScenarios(): void {
 $source=file_get_contents(__DIR__.'/../lib/Service/AlbumResolutionService.php');
 check(str_contains($source,'use OCP\\App\\IAppManager;'),'AlbumResolutionService uses NC34 IAppManager namespace');
    check(!str_contains($source,'use OCP\\IAppManager;'),'obsolete IAppManager namespace is absent');
}
namespaceScenarios();
