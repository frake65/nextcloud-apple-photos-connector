<?php
declare(strict_types=1);
return ['routes' => [
    ['name' => 'status#status', 'url' => '/api/v1/status', 'verb' => 'GET'],
    ['name' => 'inventory#create', 'url' => '/api/v1/inventory', 'verb' => 'POST'],
    ['name' => 'upload#complete', 'url' => '/api/v1/uploads/complete', 'verb' => 'POST'],
    ['name' => 'upload#prepare', 'url' => '/api/v1/uploads/prepare', 'verb' => 'POST'],
    ['name' => 'album#inventory', 'url' => '/api/v1/albums/inventory', 'verb' => 'POST'],
    ['name' => 'album#sync', 'url' => '/api/v1/albums/sync', 'verb' => 'POST'],
]];
