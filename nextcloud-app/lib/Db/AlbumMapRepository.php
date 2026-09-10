<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Db;
use OCP\IDBConnection;

final class AlbumMapRepository {
    public function __construct(private IDBConnection $db) {}
    public function find(string $userId, string $sourceId, string $key): ?array {
        $q=$this->db->getQueryBuilder(); $q->select('*')->from('apc_nextcloud_album_map')->where(
            $q->expr()->eq('user_id',$q->createNamedParameter($userId)),
            $q->expr()->eq('source_id',$q->createNamedParameter($sourceId)),
            $q->expr()->eq('source_album_key',$q->createNamedParameter($key)));
        return $q->executeQuery()->fetch() ?: null;
    }
    public function insert(array $row): int {
        $q=$this->db->getQueryBuilder(); $values=[];
        foreach($row as $k=>$v) $values[$k]=$q->createNamedParameter($v,$v===null?\OCP\DB\QueryBuilder\IQueryBuilder::PARAM_NULL:\OCP\DB\QueryBuilder\IQueryBuilder::PARAM_STR);
        $q->insert('apc_nextcloud_album_map')->values($values)->executeStatement(); return (int)$this->db->lastInsertId('apc_nextcloud_album_map');
    }
    public function setNextcloudAlbumId(int $id, int $nextcloudAlbumId): void {
        $q=$this->db->getQueryBuilder();
        $q->update('apc_nextcloud_album_map')->set('nextcloud_album_id',$q->createNamedParameter($nextcloudAlbumId))
            ->where($q->expr()->eq('id',$q->createNamedParameter($id)))->executeStatement();
    }
}
