<?php
declare(strict_types=1);
function membershipCommandScenarios(): void {
    $command = file_get_contents(__DIR__ . '/../lib/Command/AlbumTestAddMembershipCommand.php');
    $service = file_get_contents(__DIR__ . '/../lib/Service/AlbumMembershipTestService.php');
    $info = file_get_contents(__DIR__ . '/../appinfo/info.xml');
    check(!str_contains($info, 'AlbumTestAddMembershipCommand') && !str_contains($info, 'AlbumTestResolveCommand'), 'development commands are not publicly registered');
    check(str_contains($command, 'apple-photos-connector:album:test-add-membership'), 'membership command name is stable');
    check(str_contains(file_get_contents(__DIR__ . '/../lib/Service/AlbumMembershipService.php'), 'new NextcloudAlbumAdapter') && str_contains(file_get_contents(__DIR__ . '/../lib/Service/AlbumMembershipService.php'), 'addFileMembership'), 'production membership service delegates to adapter');
    check(!str_contains($command, 'photos_albums') && !str_contains($command, 'addFile('), 'membership command has no direct Photos DB writes');
    $orchestrator = file_get_contents(__DIR__ . '/../lib/Service/AlbumSyncOrchestrator.php');
    $syncCommand = file_get_contents(__DIR__ . '/../lib/Command/AlbumSyncCommand.php');
    check(str_contains($info, 'AlbumSyncCommand') && str_contains($syncCommand, 'apple-photos-connector:album:sync'), 'album sync command is registered');
    check(str_contains($orchestrator, 'folders_skipped') && str_contains($orchestrator, 'memberships_skipped_not_imported'), 'orchestrator reports folder and import counters');
    check(!str_contains($orchestrator, 'removeFile') && !str_contains($orchestrator, 'photos_albums'), 'orchestrator has no destructive or direct Photos writes');
}
