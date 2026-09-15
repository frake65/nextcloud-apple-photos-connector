<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Controller;
use OCA\ApplePhotosConnector\AppInfo\Application;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\JSONResponse;
use OCP\IRequest;
use OCP\IUserSession;

final class StatusController extends Controller {
    public function __construct(IRequest $request, private IUserSession $session) { parent::__construct(Application::APP_ID, $request); }
    #[NoAdminRequired]
    #[NoCSRFRequired]
    public function status(): JSONResponse {
        $user = $this->session->getUser();
        if (!$user || !str_starts_with(strtolower($this->request->getHeader('Authorization')), 'basic ')) {
            return new JSONResponse(['error' => 'Authentication required'], 401);
        }
        return new JSONResponse(['status' => 'ok', 'app' => Application::APP_ID, 'version' => '0.8.2']);
    }
}
