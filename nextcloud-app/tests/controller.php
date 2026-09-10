<?php
declare(strict_types=1);

use OCA\ApplePhotosConnector\Controller\InventoryController;
use OCA\ApplePhotosConnector\Db\InventoryRepository;
use OCA\ApplePhotosConnector\Service\AssetIdentity;
use OCA\ApplePhotosConnector\Service\InventoryService;
use OCA\ApplePhotosConnector\Service\InventoryValidator;

function controllerScenarios(InventoryRepository $repository): void {
    $request = new class implements \OCP\IRequest {
        public array $headers = ['Authorization' => 'Basic test', 'Content-Type' => 'application/json; charset=utf-8'];
        public array $params = ['source' => ['sourceId' => '550e8400-e29b-41d4-a716-446655440009', 'name' => 'Controller test'], 'assets' => []];
        public function getHeader(string $name): string { return $this->headers[$name] ?? ''; }
        public function getParam(string $name): mixed { return $this->params[$name] ?? null; }
        public function getParams(): array { return $this->params; }
    };
    $session = new class implements \OCP\IUserSession {
        public bool $authenticated = true;
        public function getUser(): mixed {
            return $this->authenticated ? new class { public function getUID(): string { return 'controller-test'; } } : null;
        }
    };
    $controller = new InventoryController($request, new InventoryService($repository, new AssetIdentity(), new InventoryValidator(), testUploadedFileLocator()), $session);
    $response = $controller->create();
    $data = $response->getData();
    check($response->getStatus() === 200 && $data['assets'] === [] && $data['summary'] === ['seen' => 0, 'new' => 0, 'known' => 0]
        && $repository->run('controller-test', $data['runId'])['status'] === 'completed', 'controller returns completed run with inventory response');
    $session->authenticated = false;
    check($controller->create()->getStatus() === 401, 'controller rejects unauthenticated requests');
    $session->authenticated = true;
    unset($request->headers['Authorization']);
    check($controller->create()->getStatus() === 401, 'controller rejects cookie-only requests');
    $request->headers['Authorization'] = 'Basic test';
    $request->headers['Content-Type'] = 'application/json-invalid';
    check($controller->create()->getStatus() === 415, 'controller validates exact JSON media type');
    $request->headers['Content-Type'] = 'application/json';
    $request->params['assets'] = 'invalid';
    $response = $controller->create();
    check($response->getStatus() === 400 && $repository->run('controller-test', $response->getData()['runId'])['status'] === 'failed', 'controller records invalid request structure as failed');
    $request->params['assets'] = [];
    $request->params['source']['sourceId'] = 'invalid';
    $response = $controller->create();
    $failed = $repository->run('controller-test', $response->getData()['runId']);
    check($response->getStatus() === 400 && $failed['status'] === 'failed' && $failed['source_id'] === null, 'invalid source UUID produces attributable failed run with null source reference');
}
