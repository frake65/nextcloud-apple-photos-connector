<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\DB\Types;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

/** APC 0.8.0: initial installation only, no historical data conversion. */
final class Version008000Date20260910000000 extends SimpleMigrationStep {
    public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
        $schema = $schemaClosure();
        $id = [Types::BIGINT, ['autoincrement' => true, 'notnull' => true]];
        $integer = [Types::BIGINT, ['notnull' => true]];
        $reference = [Types::BIGINT, ['notnull' => false]];
        $text = [Types::TEXT, ['notnull' => false]];
        $requiredText = [Types::TEXT, ['notnull' => true]];
        $string = static fn(int $length, bool $required = true): array => [Types::STRING, ['length' => $length, 'notnull' => $required]];
        $owner = ['user_id' => $string(64), 'source_id' => $string(36)];
        $tables = [
            'apc_sources' => ['id' => $id] + $owner + [
                'name' => $string(255), 'created_at' => $string(32), 'last_seen_at' => $string(32),
            ],
            'apc_assets' => ['id' => $id] + $owner + [
                'local_identifier' => $requiredText, 'cloud_identifier' => $text, 'filename' => $text,
                'media_type' => $string(16), 'creation_date' => $string(32, false),
                'first_seen_at' => $string(32), 'last_seen_at' => $string(32),
                'nextcloud_file_id' => $reference, 'nextcloud_path' => $text, 'uploaded_at' => $string(32, false),
                'current_upload_target_id' => $reference,
            ],
            'apc_import_runs' => [
                'id' => $id, 'run_id' => $string(36), 'user_id' => $string(64), 'source_id' => $string(36, false),
                'started_at' => $string(32), 'completed_at' => $string(32, false), 'status' => $string(16),
                'error_code' => $string(32, false),
            ],
            'apc_uploads' => ['id' => $id] + $owner + [
                'upload_id' => $string(36), 'run_id' => $string(36), 'asset_id' => $integer,
                'filename' => $text, 'status' => $string(16), 'created_at' => $string(32),
                'retarget_allowed' => [Types::BOOLEAN, ['notnull' => true, 'default' => false]],
                // Ticket bindings, not another current-state authority.
                'base_target_id' => $reference, 'target_id' => $reference,
            ],
            'apc_upload_targets' => ['id' => $id] + $owner + [
                'asset_id' => $integer, 'bytes' => $integer, 'attempt' => $integer,
                'sha256' => $string(64), 'path_key' => $string(64), 'filename' => $requiredText, 'path' => $requiredText,
            ],
            'apc_source_albums' => ['id' => $id] + $owner + [
                'name' => $string(255), 'created_at' => $string(32), 'last_seen_at' => $string(32),
                'local_identifier' => $requiredText, 'cloud_identifier' => $text, 'parent_local_identifier' => $text,
                'kind' => $string(16, false),
            ],
            'apc_album_memberships' => ['id' => $id] + $owner + [
                'album_id' => $integer, 'asset_id' => $integer, 'first_seen_at' => $string(32), 'last_seen_at' => $string(32),
            ],
            'apc_nextcloud_album_map' => ['id' => $id] + $owner + [
                'source_album_key' => $string(512), 'display_name' => $string(255),
                'source_album_id' => $integer, 'nextcloud_album_id' => $reference,
                'created_at' => $string(32), 'updated_at' => $string(32),
            ],
        ];
        foreach (['assets_seen', 'assets_new', 'assets_known', 'assets_uploaded', 'assets_failed'] as $name) {
            $tables['apc_import_runs'][$name] = [Types::BIGINT, ['notnull' => true, 'default' => 0]];
        }
        foreach (array_keys($tables) as $name) {
            if ($schema->hasTable($name)) {
                throw new \RuntimeException('APC 0.8.0 requires a fresh installation without existing APC tables');
            }
        }
        foreach ($tables as $name => $columns) {
            $table = $schema->createTable($name);
            foreach ($columns as $column => [$type, $definition]) { $table->addColumn($column, $type, $definition); }
            $table->setPrimaryKey(['id']);
        }
        $indices = [
            'apc_sources' => [['apc_source_owner', ['user_id', 'source_id'], true]],
            'apc_assets' => [['apc_asset_source', ['user_id', 'source_id'], false], ['apc_asset_current_target', ['current_upload_target_id'], false]],
            'apc_import_runs' => [['apc_run_uuid', ['run_id'], true], ['apc_run_source', ['user_id', 'source_id'], false]],
            'apc_uploads' => [['apc_upload_uuid', ['upload_id'], true], ['apc_upload_run_asset', ['run_id', 'asset_id'], true], ['apc_upload_source', ['user_id', 'source_id'], false]],
            'apc_upload_targets' => [['apc_target_asset_idx', ['asset_id'], false], ['apc_target_path', ['user_id', 'path_key'], true]],
            'apc_source_albums' => [['apc_album_identity', ['user_id', 'source_id', 'local_identifier'], true]],
            'apc_album_memberships' => [['apc_album_member', ['user_id', 'source_id', 'album_id', 'asset_id'], true]],
            'apc_nextcloud_album_map' => [['apc_nc_album_key', ['user_id', 'source_id', 'source_album_key'], true], ['apc_nc_album_id', ['nextcloud_album_id'], false], ['apc_nc_source_album_id', ['source_album_id'], false]],
        ];
        foreach ($indices as $name => $definitions) {
            foreach ($definitions as [$index, $columns, $unique]) {
                $table = $schema->getTable($name);
                if ($unique) { $table->addUniqueIndex($columns, $index); } else { $table->addIndex($columns, $index); }
            }
        }
        return $schema;
    }
}
