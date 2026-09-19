<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Controller;

use OCA\ApplePhotosConnector\AppInfo\Application;
use OCA\ApplePhotosConnector\Service\AlbumSyncDiagnosticException;
use OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\JSONResponse;
use OCP\IRequest;
use OCP\IUserSession;
use OCP\IDBConnection;

class AlbumController extends Controller {
    public function __construct(IRequest $r, private IUserSession $session, private IDBConnection $db, private ?AlbumSyncOrchestrator $orchestrator = null) {
        parent::__construct(Application::APP_ID, $r);
    }

    #[NoAdminRequired]
    #[NoCSRFRequired]
    public function sync(): JSONResponse {
        $user = $this->session->getUser();
        if (!$user || !str_starts_with(strtolower($this->request->getHeader('Authorization')), 'basic ')) return new JSONResponse(['error' => 'Authentication required'], 401);
        $params = $this->request->getParams();
        $sourceId = $params['sourceId'] ?? null;
        if (!is_string($sourceId) || !$this->orchestrator) return new JSONResponse(['error' => 'Invalid album sync request'], 400);
        $albumIds = $params['selectedAlbumIDs'] ?? null;
        $assetIds = $params['selectedAssetIDs'] ?? null;
        if (($albumIds !== null && !is_array($albumIds)) || ($assetIds !== null && !is_array($assetIds))) return new JSONResponse(['error' => 'Invalid album selection'], 400);
        $albumIds = $albumIds === null ? null : array_values(array_filter($albumIds, 'is_string'));
        $assetIds = $assetIds === null ? null : array_values(array_filter($assetIds, 'is_string'));
        $requestContext = [
            'selected_album_count' => count($albumIds ?? []),
            'selected_asset_count' => count($assetIds ?? []),
            'selected_asset_prefixes' => $this->identityPrefixCounts($assetIds ?? []),
        ];
        $this->debug('album.sync.request source='.strtolower($sourceId).' '.json_encode($requestContext, JSON_UNESCAPED_SLASHES));

        try {
            $result = $this->orchestrator->sync(strtolower($sourceId), $user->getUID(), $albumIds, $assetIds);
            return new JSONResponse(['status' => $result['errors'] ? 'partial' : 'completed', 'summary' => [
                'albumsSeen' => $result['albums_seen'], 'albumsCreated' => $result['albums_created'], 'albumsReused' => $result['albums_reused'],
                'foldersSkipped' => $result['folders_skipped'], 'membershipsSeen' => $result['memberships_seen'],
                'membershipsCreated' => $result['memberships_created'], 'membershipsReused' => $result['memberships_reused'],
                'membershipsSkippedNotImported' => $result['memberships_skipped_not_imported'], 'errors' => $result['errors'],
            ]]);
        } catch (AlbumSyncDiagnosticException $e) {
            return $this->syncFailure($e, $requestContext);
        } catch (\InvalidArgumentException $e) {
            return new JSONResponse(['error' => $e->getMessage()], 400);
        } catch (\Throwable $e) {
            return $this->syncFailure($e, $requestContext);
        }
    }

    private function syncFailure(\Throwable $error, array $requestContext): JSONResponse {
        $diagnostic = $error instanceof AlbumSyncDiagnosticException ? $error : null;
        $cause = $diagnostic?->getPrevious() ?? $error;
        if ($cause instanceof \InvalidArgumentException) return new JSONResponse(['error' => $cause->getMessage()], 400);

        $this->debug('album.sync.failure stage='.($diagnostic?->stage ?? 'album.sync.unclassified').' exception='.get_class($cause));
        $response = ['error' => 'Album sync failed'];
        if (defined('OC_DEBUG') && OC_DEBUG) {
            $message = preg_replace('/[\r\n\t]+/', ' ', $cause->getMessage()) ?? '';
            $message = preg_replace('/(authorization|password|token|secret|cookie)\s*[:=]\s*\S+/i', '$1=[redacted]', $message) ?? $message;
            $response['diagnostic'] = [
                'stage' => $diagnostic?->stage ?? 'album.sync.unclassified',
                'exceptionClass' => get_class($cause),
                'message' => substr($message, 0, 500),
                'context' => $diagnostic?->context ?? [],
                'request' => $requestContext,
            ];
        }
        return new JSONResponse($response, 500);
    }

    private function identityPrefixCounts(array $identities): array {
        $counts = ['cloud' => 0, 'local' => 0, 'other' => 0];
        foreach ($identities as $identity) {
            $prefix = str_starts_with($identity, 'cloud:') ? 'cloud' : (str_starts_with($identity, 'local:') ? 'local' : 'other');
            $counts[$prefix]++;
        }
        return $counts;
    }

    private function debug(string $message): void {
        if (defined('OC_DEBUG') && OC_DEBUG && class_exists('OC') && isset(\OC::$server)) {
            try { \OC::$server->getLogger()->debug('Apple Photos Connector: '.$message, ['app' => 'apple_photos_connector']); } catch (\Throwable) {}
        }
    }

 #[NoAdminRequired]
 #[NoCSRFRequired]
 public function inventory(): JSONResponse {
  $u=$this->session->getUser(); if(!$u||!str_starts_with(strtolower($this->request->getHeader('Authorization')),'basic ')) return new JSONResponse(['error'=>'Authentication required'],401);
  $p=$this->request->getParams(); $s=$p['source']??null; $as=$p['albums']??null; if(!is_array($s)||!is_string($s['sourceId']??null)||!is_string($s['name']??null)||!is_array($as)||!array_is_list($as)) return new JSONResponse(['error'=>'Invalid album inventory'],400);
  $uid=$u->getUID(); $sid=strtolower($s['sourceId']); $now=(new \DateTimeImmutable('now',new \DateTimeZone('UTC')))->format('Y-m-d\\TH:i:s.u\\Z'); $this->db->beginTransaction();
  try { $q=$this->db->getQueryBuilder(); $q->select('id')->from('apc_sources')->where($q->expr()->eq('user_id',$q->createNamedParameter($uid)),$q->expr()->eq('source_id',$q->createNamedParameter($sid))); if(!$q->executeQuery()->fetch()) throw new \InvalidArgumentException('Source must be registered first'); $ids=[];
   foreach($as as $a){if(!is_array($a)||!is_string($a['localIdentifier']??null)||!is_string($a['name']??null)||!in_array($a['kind']??null,['album','folder'],true)) throw new \InvalidArgumentException('Invalid album kind'); $q=$this->db->getQueryBuilder(); $q->select('id')->from('apc_source_albums')->where($q->expr()->eq('user_id',$q->createNamedParameter($uid)),$q->expr()->eq('source_id',$q->createNamedParameter($sid)),$q->expr()->eq('local_identifier',$q->createNamedParameter($a['localIdentifier']))); $row=$q->executeQuery()->fetch(); if($row){$id=(int)$row['id']; $q=$this->db->getQueryBuilder(); $q->update('apc_source_albums')->set('name',$q->createNamedParameter($a['name']))->set('cloud_identifier',$q->createNamedParameter($a['cloudIdentifier']??null))->set('parent_local_identifier',$q->createNamedParameter($a['parentLocalIdentifier']??null))->set('kind',$q->createNamedParameter($a['kind']))->set('last_seen_at',$q->createNamedParameter($now))->where($q->expr()->eq('id',$q->createNamedParameter($id))); $q->executeStatement();} else {$q=$this->db->getQueryBuilder(); $q->insert('apc_source_albums')->values(['user_id'=>$q->createNamedParameter($uid),'source_id'=>$q->createNamedParameter($sid),'local_identifier'=>$q->createNamedParameter($a['localIdentifier']),'cloud_identifier'=>$q->createNamedParameter($a['cloudIdentifier']??null),'name'=>$q->createNamedParameter($a['name']),'parent_local_identifier'=>$q->createNamedParameter($a['parentLocalIdentifier']??null),'kind'=>$q->createNamedParameter($a['kind']),'created_at'=>$q->createNamedParameter($now),'last_seen_at'=>$q->createNamedParameter($now)])->executeStatement(); $id=(int)$this->db->lastInsertId('apc_source_albums');} $ids[]=$id; }
   foreach($as as $i=>$a) foreach(($a['assets']??$a['assetIdentities']??[]) as $ident){if(!is_string($ident)) throw new \InvalidArgumentException('Invalid asset identity'); $prefix=null; $value=$ident; if(str_starts_with($ident,'cloud:')){$prefix='cloud_identifier';$value=substr($ident,6);} elseif(str_starts_with($ident,'local:')){$prefix='local_identifier';$value=substr($ident,6);} if($value==='') throw new \InvalidArgumentException('Invalid asset identity'); $q=$this->db->getQueryBuilder(); $q->select('id','source_id','user_id')->from('apc_assets')->where($q->expr()->orX(...array_filter([$prefix ? $q->expr()->eq($prefix,$q->createNamedParameter($value)) : null, $prefix===null ? $q->expr()->eq('local_identifier',$q->createNamedParameter($value)) : null, $prefix===null ? $q->expr()->eq('cloud_identifier',$q->createNamedParameter($value)) : null]))); $rows=$q->executeQuery()->fetchAllAssociative(); if(!$rows) continue; $ar=$rows[0]; if($ar['user_id']!==$uid||$ar['source_id']!==$sid) continue; $q=$this->db->getQueryBuilder(); $q->select('id')->from('apc_album_memberships')->where($q->expr()->eq('user_id',$q->createNamedParameter($uid)),$q->expr()->eq('source_id',$q->createNamedParameter($sid)),$q->expr()->eq('album_id',$q->createNamedParameter($ids[$i])),$q->expr()->eq('asset_id',$q->createNamedParameter((int)$ar['id']))); if($q->executeQuery()->fetch()) continue; $q=$this->db->getQueryBuilder(); $q->insert('apc_album_memberships')->values(['user_id'=>$q->createNamedParameter($uid),'source_id'=>$q->createNamedParameter($sid),'album_id'=>$q->createNamedParameter($ids[$i]),'asset_id'=>$q->createNamedParameter((int)$ar['id']),'first_seen_at'=>$q->createNamedParameter($now),'last_seen_at'=>$q->createNamedParameter($now)])->executeStatement(); }
   $this->db->commit(); return new JSONResponse(['albums'=>$ids,'count'=>count($ids)]);
  } catch(\Throwable $e){if($this->db->inTransaction()) $this->db->rollBack(); return new JSONResponse(['error'=>$e->getMessage()],400);}
 }
}
