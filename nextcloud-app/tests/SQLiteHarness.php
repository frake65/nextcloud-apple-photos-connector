<?php
declare(strict_types=1);
// Minimal OCP compatibility surface for standalone SQLite tests, NOT a Nextcloud runtime.
namespace OCP {
    interface IDBConnection {}
    interface IRequest {
        public function getHeader(string $name): string;
        public function getParam(string $name): mixed;
        public function getParams(): array;
    }
    interface IUserSession { public function getUser(): mixed; }
}
namespace OCP\AppFramework {
    class App {}
    class Controller {
        public function __construct(string $name, protected \OCP\IRequest $request) {}
    }
}
namespace OCP\AppFramework\Http {
    class JSONResponse {
        public function __construct(private mixed $data, private int $status = 200) {}
        public function getStatus(): int { return $this->status; }
        public function getData(): mixed { return $this->data; }
    }
}
namespace OCP\DB {
    interface ISchemaWrapper {}
    class Types {
        public const BOOLEAN = 'boolean', BIGINT = 'bigint', STRING = 'string', TEXT = 'text';
    }
}
namespace OCP\DB\QueryBuilder {
    interface IQueryBuilder {
        public const PARAM_BOOL = \PDO::PARAM_BOOL, PARAM_NULL = \PDO::PARAM_NULL, PARAM_STR = \PDO::PARAM_STR, PARAM_INT = \PDO::PARAM_INT;
    }
}
namespace OCP\Migration {
    interface IOutput {}
    class SimpleMigrationStep {}
}
namespace OCP\Files {
    interface IRootFolder {}
    interface File {}
}
namespace OCP\Lock {
    interface ILockingProvider { public const LOCK_SHARED = 1; }
}
namespace TestHarness {
    class Connection implements \OCP\IDBConnection {
        public function __construct(public \PDO $pdo) {
            $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        }
        public function beginTransaction(): void { $this->pdo->beginTransaction(); }
        public function commit(): void { $this->pdo->commit(); }
        public function rollBack(): void { $this->pdo->rollBack(); }
        public function inTransaction(): bool { return $this->pdo->inTransaction(); }
        public function lastInsertId(string $table): string { return $this->pdo->lastInsertId(); }
        public function getQueryBuilder(): Query { return new Query($this->pdo); }
    }
    class Query {
        private string $operation = '';
        private string $table = '';
        private array $parameters = [], $values = [], $where = [];
        public function __construct(private \PDO $pdo) {}
        public function select(string $columns): self { $this->operation = 'select'; return $this; }
        public function from(string $table): self { $this->table = $table; return $this; }
        public function insert(string $table): self { $this->operation = 'insert'; $this->table = $table; return $this; }
        public function update(string $table): self { $this->operation = 'update'; $this->table = $table; return $this; }
        public function values(array $values): self { $this->values = $values; return $this; }
        public function set(string $key, string $value): self { $this->values[$key] = $value; return $this; }
        public function where(string ...$where): self { $this->where = $where; return $this; }
        public function expr(): self { return $this; }
        public function orX(string ...$where): string { return '(' . implode(' OR ', $where) . ')'; }
        public function eq(string $key, string $parameter): string { return "$key = $parameter"; }
        public function createNamedParameter(mixed $value, mixed $type = null): string {
            $key = ':p' . count($this->parameters);
            $this->parameters[$key] = $value;
            return $key;
        }
        private function statement(): \PDOStatement {
            $sql = match ($this->operation) {
                'select' => 'SELECT * FROM ' . $this->table,
                'insert' => 'INSERT INTO ' . $this->table . ' (' . implode(',', array_keys($this->values)) . ') VALUES (' . implode(',', $this->values) . ')',
                'update' => 'UPDATE ' . $this->table . ' SET ' . implode(',', array_map(fn ($key) => "$key = " . $this->values[$key], array_keys($this->values))),
            };
            if ($this->where) { $sql .= ' WHERE ' . implode(' AND ', $this->where); }
            $statement = $this->pdo->prepare($sql);
            $statement->execute($this->parameters);
            return $statement;
        }
        public function executeStatement(): int { return $this->statement()->rowCount(); }
        public function executeQuery(): Result { return new Result($this->statement()); }
    }
    class Result {
        public function __construct(private \PDOStatement $statement) {}
        public function fetchAllAssociative(): array { return $this->statement->fetchAll(\PDO::FETCH_ASSOC); }
        public function fetch(): mixed { return $this->statement->fetch(\PDO::FETCH_ASSOC); }
        public function closeCursor(): void { $this->statement->closeCursor(); }
    }
    class Schema implements \OCP\DB\ISchemaWrapper {
        public array $tables = [];
        public function hasTable(string $name): bool { return isset($this->tables[$name]); }
        public function getTable(string $name): Table { return $this->tables[$name]; }
        public function createTable(string $name): Table { return $this->tables[$name] = new Table($name); }
        public function apply(\PDO $pdo): void { foreach ($this->tables as $table) { $table->apply($pdo); } }
    }
    class Table {
        private array $columns = [], $indices = [];
        public function __construct(private string $name) {}
        public function hasColumn(string $name): bool { return isset($this->columns[$name]); }
        public function addColumn(string $name, string $type, array $options): void {
            $this->columns[$name] = !empty($options['autoincrement']) ? 'INTEGER PRIMARY KEY AUTOINCREMENT'
                : (in_array($type, ['bigint', 'boolean'], true) ? 'INTEGER' : 'TEXT') . (!empty($options['notnull']) ? ' NOT NULL' : '')
                    . (array_key_exists('default', $options) ? ' DEFAULT ' . (int)$options['default'] : '');
        }
        public function setPrimaryKey(array $columns): void {}
        public function addUniqueIndex(array $columns, string $name): void { $this->indices[] = [$columns, $name, true]; }
        public function addIndex(array $columns, string $name): void { $this->indices[] = [$columns, $name, false]; }
        public function apply(\PDO $pdo): void {
            $columns = array_map(fn ($key) => "$key " . $this->columns[$key], array_keys($this->columns));
            $pdo->exec('CREATE TABLE ' . $this->name . ' (' . implode(',', $columns) . ')');
            foreach ($this->indices as [$keys, $name, $unique]) {
                $pdo->exec('CREATE ' . ($unique ? 'UNIQUE ' : '') . "INDEX $name ON {$this->name} (" . implode(',', $keys) . ')');
            }
        }
    }
}
