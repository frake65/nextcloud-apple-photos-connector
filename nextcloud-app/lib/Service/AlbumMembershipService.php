<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;
use OCA\ApplePhotosConnector\Db\AlbumMapRepository;
use OCP\IDBConnection;
use OCP\App\IAppManager;
use OCP\Files\IRootFolder;
use OCA\Photos\Album\AlbumMapper;

class AlbumMembershipService {
 public function __construct(private IDBConnection $db, private AlbumMapRepository $maps, private AlbumMapper $albumMapper, private IAppManager $appManager, private IRootFolder $root){}
 public function add(int $sourceAlbumId,int $assetId,string $userId):array{$q=$this->db->getQueryBuilder();$q->select('*')->from('apc_source_albums')->where($q->expr()->eq('id',$q->createNamedParameter($sourceAlbumId)),$q->expr()->eq('user_id',$q->createNamedParameter($userId)));$album=$q->executeQuery()->fetch();if(!$album||($album['kind']??null)!=='album')throw new \InvalidArgumentException('Source album not found, not owned by user, or is not an album');$source=(string)$album['source_id'];$q=$this->db->getQueryBuilder();$q->select('*')->from('apc_sources')->where($q->expr()->eq('source_id',$q->createNamedParameter($source)),$q->expr()->eq('user_id',$q->createNamedParameter($userId)));if(!$q->executeQuery()->fetch())throw new \InvalidArgumentException('Source not found or not owned by user');$q=$this->db->getQueryBuilder();$q->select('*')->from('apc_assets')->where($q->expr()->eq('id',$q->createNamedParameter($assetId)),$q->expr()->eq('user_id',$q->createNamedParameter($userId)));$asset=$q->executeQuery()->fetch();if(!$asset||(string)$asset['source_id']!==$source||$asset['nextcloud_file_id']===null||!$asset['nextcloud_path'])throw new \InvalidArgumentException('Asset is not imported for this source/user');$adapter=new NextcloudAlbumAdapter($this->maps,$this->albumMapper,$this->appManager->getAppVersion('photos'));$resolved=$adapter->resolveOrCreateAlbum($userId,$source,(int)$album['id'],['localIdentifier'=>$album['local_identifier'],'cloudIdentifier'=>$album['cloud_identifier']??null,'name'=>$album['name'],'kind'=>'album']);$fileId=(int)$this->root->getUserFolder($userId)->get((string)$asset['nextcloud_path'])->getId();if($fileId!==(int)$asset['nextcloud_file_id'])throw new \InvalidArgumentException('Imported file mapping is inconsistent');$created=$adapter->addFileMembership($userId,(int)$resolved['nextcloud_album_id'],$fileId,$userId);return ['album_id'=>(int)$resolved['nextcloud_album_id'],'file_id'=>$fileId,'created_or_reused'=>$created?'created':'reused'];}
}
