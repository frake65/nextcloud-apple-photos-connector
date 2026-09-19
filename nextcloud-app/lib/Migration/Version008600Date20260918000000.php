<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Migration;

use Closure;
use OCA\ApplePhotosConnector\Db\ContentIdentityRepository;
use OCP\DB\ISchemaWrapper;
use OCP\DB\Types;
use OCP\IDBConnection;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

/** Additive user-scoped content evidence and a safe backfill of confirmed APC upload targets. */
final class Version008600Date20260918000000 extends SimpleMigrationStep {
    public function __construct(private IDBConnection $db) {}

    public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
        $schema = $schemaClosure();
        if (!$schema->hasTable('apc_content_identities')) {
            $table = $schema->createTable('apc_content_identities');
            $table->addColumn('id', Types::BIGINT, ['autoincrement' => true, 'notnull' => true]);
            $table->addColumn('user_id', Types::STRING, ['length' => 64, 'notnull' => true]);
            $table->addColumn('sha256', Types::STRING, ['length' => 64, 'notnull' => true]);
            $table->addColumn('bytes', Types::BIGINT, ['notnull' => true]);
            $table->addColumn('created_at', Types::STRING, ['length' => 32, 'notnull' => true]);
            $table->setPrimaryKey(['id']);
            $table->addUniqueIndex(['user_id', 'sha256', 'bytes'], 'apc_content_identity');
        }
        if (!$schema->hasTable('apc_content_targets')) {
            $table = $schema->createTable('apc_content_targets');
            $table->addColumn('id', Types::BIGINT, ['autoincrement' => true, 'notnull' => true]);
            $table->addColumn('content_id', Types::BIGINT, ['notnull' => true]);
            $table->addColumn('user_id', Types::STRING, ['length' => 64, 'notnull' => true]);
            $table->addColumn('source_id', Types::STRING, ['length' => 36, 'notnull' => true]);
            $table->addColumn('asset_id', Types::BIGINT, ['notnull' => true]);
            $table->addColumn('upload_target_id', Types::BIGINT, ['notnull' => true]);
            $table->addColumn('nextcloud_file_id', Types::BIGINT, ['notnull' => false]);
            $table->addColumn('confirmed_at', Types::STRING, ['length' => 32, 'notnull' => true]);
            $table->setPrimaryKey(['id']);
            $table->addUniqueIndex(['upload_target_id'], 'apc_content_target');
            $table->addIndex(['content_id', 'user_id'], 'apc_content_lookup');
        }
        return $schema;
    }

    public function postSchemaChange(IOutput $output, Closure $schemaClosure, array $options): void {
        (new ContentIdentityRepository($this->db))->backfillConfirmedTargets();
    }
}
