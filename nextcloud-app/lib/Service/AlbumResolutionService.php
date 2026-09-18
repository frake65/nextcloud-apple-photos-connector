<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;
use OCA\ApplePhotosConnector\Db\AlbumMapRepository;
use OCP\IDBConnection;
use OCP\App\IAppManager;
use OCA\Photos\Album\AlbumMapper;

class AlbumResolutionService {
 public function __construct(private IDBConnection $db, private AlbumMapRepository $maps, private AlbumMapper $albumMapper, private IAppManager $appManager){}
 public function resolve(int $sourceAlbumId,string $userId):array{$q=$this->db->getQueryBuilder();$q->select('*')->from('apc_source_albums')->where($q->expr()->eq('id',$q->createNamedParameter($sourceAlbumId)),$q->expr()->eq('user_id',$q->createNamedParameter($userId)));$a=$q->executeQuery()->fetch();if(!$a)throw new \InvalidArgumentException('Source album not found or not owned by user');if(($a['kind']??null)!=='album')throw new \InvalidArgumentException(($a['kind']??null)===null?'Source album kind is unknown; run album inventory again before resolving.':'Folders are not Photos albums');$s=$this->source($userId,(string)$a['source_id']);if(!$s)throw new \InvalidArgumentException('Source not found or not owned by user');$key=AlbumIdentity::key($a['cloud_identifier']??null,(string)$a['local_identifier']);$r=(new NextcloudAlbumAdapter($this->maps,$this->albumMapper,$this->appManager->getAppVersion('photos')))->resolveOrCreateAlbum($userId,(string)$a['source_id'],(int)$a['id'],['localIdentifier'=>$a['local_identifier'],'cloudIdentifier'=>$a['cloud_identifier']??null,'name'=>$a['name'],'kind'=>'album']);return ['source_album_id'=>(int)$a['id'],'source_id'=>$a['source_id'],'display_name'=>$a['name'],'source_album_key'=>$key,'nextcloud_album_id'=>$r['nextcloud_album_id'],'created_or_reused'=>$r['photos_action']];}
 private function source(string $u,string $s):?array{$q=$this->db->getQueryBuilder();$q->select('*')->from('apc_sources')->where($q->expr()->eq('user_id',$q->createNamedParameter($u)),$q->expr()->eq('source_id',$q->createNamedParameter($s)));return $q->executeQuery()->fetch()?:null;}
}
