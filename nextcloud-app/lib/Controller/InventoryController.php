<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Controller;

use OCA\ApplePhotosConnector\AppInfo\Application;
use OCA\ApplePhotosConnector\Service\InventoryService;
use OCA\ApplePhotosConnector\Service\ImportRunFailure;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\JSONResponse;
use OCP\DB\Exception as DBException;
use OCP\IRequest;
use OCP\IUserSession;

class InventoryController extends Controller {
    public function __construct(IRequest $request, private InventoryService $service, private IUserSession $userSession) {
        parent::__construct(Application::APP_ID, $request);
    }

    #[NoAdminRequired]
    #[NoCSRFRequired]
    public function create(): JSONResponse {
        $user = $this->userSession->getUser();
        if ($user === null) { return new JSONResponse(['error' => 'Authentication required'], 401); }
        // Only app-password/Basic-auth API calls; never allow cookie-only CSRF writes.
        if (!$this->request->getHeader('Authorization') || !str_starts_with(strtolower($this->request->getHeader('Authorization')), 'basic ')) {
            return new JSONResponse(['error' => 'HTTP Basic authentication with an app password required'], 401);
        }
        if (strtolower(trim(explode(';', $this->request->getHeader('Content-Type'))[0])) !== 'application/json') {
            return new JSONResponse(['error' => 'Content-Type application/json required'], 415);
        }
        $source = $this->request->getParam('source');
        $assets = $this->request->getParam('assets');
        $rawRetransfer = $this->request->getParam('retransferMissing');
        $retransferMissing = $rawRetransfer === true || $rawRetransfer === 1 || $rawRetransfer === '1' || $rawRetransfer === 'true';
        try {
            return new JSONResponse($this->service->ingest($user->getUID(), $source, $assets, $retransferMissing));
        } catch (ImportRunFailure $failure) {
            $error = $failure->getPrevious();
            if ($error instanceof \InvalidArgumentException) {
                return new JSONResponse(['runId' => $failure->runId, 'error' => $error->getMessage()], 400);
            }
            if ($error instanceof DBException && $error->getReason() === DBException::REASON_UNIQUE_CONSTRAINT_VIOLATION) {
                return new JSONResponse(['runId' => $failure->runId, 'error' => 'Concurrent source registration; retry the inventory'], 409);
            }
            return new JSONResponse(['runId' => $failure->runId, 'error' => 'Inventory processing failed'], 500);
        } catch (DBException $error) {
            // Initial run creation failed, so no persistent runId can be promised.
            return new JSONResponse(['error' => 'Unable to create inventory run'], 503);
        }
    }
}
