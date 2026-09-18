<?php
declare(strict_types=1);
use OCA\ApplePhotosConnector\Service\AlbumSyncOrchestrator;
function albumSelectionScenarios(): void {
    $album=['local_identifier'=>'album-a','cloud_identifier'=>'album-cloud-a'];
    check(!AlbumSyncOrchestrator::selectedAlbumMatches($album,['cloud:other']),'selected filter skips an unselected album');
    check(AlbumSyncOrchestrator::selectedAlbumMatches($album,['cloud:album-cloud-a']),'selected filter keeps a selected album');
    check(!AlbumSyncOrchestrator::selectedAssetMatches(['local_identifier'=>'asset-a','cloud_identifier'=>'cloud:a'],['cloud:other']),'zero relevant assets are skipped');
    check(AlbumSyncOrchestrator::selectedAssetMatches(['local_identifier'=>'asset-a','cloud_identifier'=>'cloud:a'],['cloud:a']),'one relevant asset is retained');
    check(AlbumSyncOrchestrator::selectedAssetMatches(['local_identifier'=>'asset-a','cloud_identifier'=>'cloud-a'],['cloud:cloud-a']),'stable cloud-prefixed selected identity matches server inventory');
    check(AlbumSyncOrchestrator::selectedAssetMatches(['local_identifier'=>'asset-a','cloud_identifier'=>null],['local:asset-a']),'stable local-prefixed selected identity matches server inventory');
    check(!AlbumSyncOrchestrator::selectedAssetMatches(['local_identifier'=>'asset-b','cloud_identifier'=>'cloud:b'],['cloud:a']),'mixed album assets exclude unselected assets');
    check(AlbumSyncOrchestrator::selectedAssetMatches(['local_identifier'=>'asset-a','cloud_identifier'=>'cloud:a','nextcloud_file_id'=>7,'nextcloud_path'=>'Photos/a.jpg'],['asset-a']),'already imported asset remains eligible for membership');
    $members=[]; foreach(['cloud:a','cloud:a'] as $id) $members[$id]=true;
    check(count($members)===1,'repeated selected asset remains one logical membership');
    check(AlbumSyncOrchestrator::selectedAlbumMatches($album,null),'legacy unfiltered sync remains supported');
}
