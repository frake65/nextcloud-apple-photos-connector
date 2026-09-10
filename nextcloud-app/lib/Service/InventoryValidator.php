<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Service;

use DateTimeImmutable;
use DateTimeZone;
use InvalidArgumentException;

class InventoryValidator {
    /** Normalize a usable source reference even when the rest of a request is invalid. */
    public function sourceId(mixed $source): ?string {
        $id = is_array($source) ? ($source['sourceId'] ?? null) : null;
        return is_string($id) && preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iD', $id)
            ? strtolower($id) : null;
    }

    public function validate(array $source, array $assets): array {
        $id = $this->text($source['sourceId'] ?? null, 'source.sourceId', 36);
        if ($this->sourceId($source) === null) {
            throw new InvalidArgumentException('source.sourceId must be a UUID');
        }
        $normalized = [
            'source_id' => strtolower($id),
            'name' => $this->text($source['name'] ?? null, 'source.name', 255),
            'created_at' => $this->date($source['createdAt'] ?? null, 'source.createdAt'),
        ];
        if (!array_is_list($assets) || count($assets) > 10000) {
            throw new InvalidArgumentException('assets must be a list with at most 10000 entries');
        }
        $rows = [];
        foreach ($assets as $index => $asset) {
            if (!is_array($asset)) { throw new InvalidArgumentException("assets[$index] must be an object"); }
            $media = $this->text($asset['mediaType'] ?? null, 'mediaType', 16);
            if (!in_array($media, ['image', 'video', 'audio', 'unknown'], true)) {
                throw new InvalidArgumentException('Invalid mediaType');
            }
            $rows[] = [
                'local_identifier' => $this->text($asset['localIdentifier'] ?? null, 'localIdentifier', 4096),
                'cloud_identifier' => $this->text($asset['cloudIdentifier'] ?? null, 'cloudIdentifier', 16384, true),
                'filename' => $this->text($asset['filename'] ?? null, 'filename', 4096, true),
                'media_type' => $media,
                'creation_date' => $this->date($asset['creationDate'] ?? null, 'creationDate'),
            ];
        }
        return [$normalized, $rows];
    }

    private function text(mixed $value, string $field, int $max, bool $nullable = false): ?string {
        if ($value === null && $nullable) { return null; }
        if (!is_string($value) || $value === '' || strlen($value) > $max || str_contains($value, "\0")) {
            throw new InvalidArgumentException("$field must be a nonempty string of at most $max bytes");
        }
        return $value;
    }

    private function date(mixed $value, string $field): ?string {
        if ($value === null) { return null; }
        if (!is_string($value) || !preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/D', $value)) {
            throw new InvalidArgumentException("$field must be an RFC3339 timestamp or null");
        }
        try { $date = new DateTimeImmutable($value); }
        catch (\Exception) { throw new InvalidArgumentException("Invalid $field"); }
        $errors = DateTimeImmutable::getLastErrors();
        if ($errors !== false && ($errors['warning_count'] || $errors['error_count'])) {
            throw new InvalidArgumentException("Invalid $field");
        }
        return $date->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d\TH:i:s.u\Z');
    }
}
