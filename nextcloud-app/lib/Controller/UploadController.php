<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Controller;

use OCA\ApplePhotosConnector\AppInfo\Application;
use OCA\ApplePhotosConnector\Service\UploadService;
use OCA\ApplePhotosConnector\Service\UploadTargetService;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\JSONResponse;
use OCP\IRequest;
use OCP\IUserSession;

class UploadController extends Controller {
    public function __construct(IRequest $request, private UploadService $service, private IUserSession $userSession, private UploadTargetService $targets) {
        parent::__construct(Application::APP_ID, $request);
    }
    #[NoAdminRequired]
    #[NoCSRFRequired]
    public function complete(): JSONResponse {
        return $this->respond(false);
    }
    #[NoAdminRequired]
    #[NoCSRFRequired]
    public function prepare(): JSONResponse {
        return $this->respond(true);
    }
    private function respond(bool $prepare): JSONResponse {
        $user = $this->userSession->getUser();
        if (!$user || !str_starts_with(strtolower($this->request->getHeader('Authorization')), 'basic ')) {
            return new JSONResponse(['error' => 'HTTP Basic authentication required'], 401);
        }
        if (strtolower(trim(explode(';', $this->request->getHeader('Content-Type'))[0])) !== 'application/json') {
            return new JSONResponse(['error' => 'Content-Type application/json required'], 415);
        }
        try {
            if ($prepare) {
                return new JSONResponse($this->targets->prepare($user->getUID(),
                    $this->request->getParam('sourceId'), $this->request->getParam('runId'),
                    $this->request->getParam('uploadId'), $this->request->getParam('bytes'), $this->request->getParam('sha256'), $this->request->getParam('folder')));
            }
            return new JSONResponse($this->service->acknowledge($user->getUID(),
                $this->request->getParam('sourceId'), $this->request->getParam('runId'),
                $this->request->getParam('uploadId'), $this->request->getParam('status'), $this->request->getParam('path')));
        } catch (\InvalidArgumentException $error) {
            $message = $error->getMessage();
            $code = match (true) {
                str_contains($message, 'Original content changed') => 'content_changed',
                str_contains($message, 'No free upload target'), str_contains($message, 'Mapped file content changed') => 'target_conflict',
                str_contains($message, 'Upload was not requested'), str_contains($message, 'Completed inventory required'), str_contains($message, 'Asset unavailable'), str_contains($message, 'Asset already uploaded') => 'invalid_ticket',
                str_contains($message, 'Invalid upload folder') => 'invalid_folder',
                str_contains($message, 'Source, run, upload, byte count') => 'invalid_request',
                default => 'unknown',
            };
            return new JSONResponse(['error' => $message, 'code' => $code], 400);
        } catch (\Throwable) {
            return new JSONResponse(['error' => 'Unable to record upload result'], 500);
        }
    }
}
