# Nextcloud app 0.8.1 pre-signing audit

Local audit, 2026-09-15. No signing, release, version change or macOS change.

## A. Icon findings

The repository contains `nextcloud-app/appinfo/img/icon.png` and ten PNGs in
`mac-agent/Resources/AppIcon.appiconset/`. No SVG, PDF, AI or Sketch source was
found among project files. No Figma source/reference was found.
The server PNG is 1024 × 1024, RGBA, with alpha exactly 1 for every pixel:
it has an alpha channel but no transparent pixels. It shows multicolour flower
petals, a blue cloud and white linked rings, with gradients, shadow and a pale
rounded-square background. This is raster artwork with reconstructable geometry,
not a losslessly convertible vector source.

There is no runtime or info.xml reference to the PNG. It is a retained project
asset, not the conventional automatically discovered Nextcloud app icon.
Nextcloud documents `img/app.svg` relative to the app root for theming-generated
favicons and home-screen icons. Thus the target here is
`nextcloud-app/img/app.svg`, not `appinfo/img/icon.png`. An arbitrary `icon.svg`
does not replace that convention. Additional dark variants are optional and
would need a consuming context; this backend app has no such frontend reference.

Source: https://docs.nextcloud.com/server/stable/developer_manual/basics/front-end/theming.html

## B. Recommendation: B

Reconstruct the existing identity using overlapping elliptical petals, a cloud
outline and linked circles. Preserve arrangement and colours; use vector
gradients where useful. Simplify raster shadow/edge texture and omit the opaque
launcher tile for a transparent, small-size legible Nextcloud icon. This is an
approximation, not a pixel-identical conversion. Review light/dark contrast and
small sizes before accepting it. The approved reconstruction is now at
`img/app.svg`.

## C. Complete package file manifest

Exactly one top-level directory: `apple_photos_connector/`.
The following 30 regular files are relative to that directory:

```text
CHANGELOG.md
LICENSE
README.md
appinfo/img/icon.png
appinfo/info.xml
appinfo/routes.php
composer.json
lib/AppInfo/Application.php
lib/Command/AlbumSyncCommand.php
lib/Controller/AlbumController.php
lib/Controller/InventoryController.php
lib/Controller/StatusController.php
lib/Controller/UploadController.php
lib/Db/AlbumMapRepository.php
lib/Db/ImportRun.php
lib/Db/InventoryRepository.php
lib/Migration/Version008000Date20260910000000.php
lib/Service/AlbumIdentity.php
lib/Service/AlbumMembershipService.php
lib/Service/AlbumResolutionService.php
lib/Service/AlbumSyncOrchestrator.php
lib/Service/AssetIdentity.php
lib/Service/ImportRunFailure.php
lib/Service/InventoryService.php
lib/Service/InventoryValidator.php
lib/Service/NextcloudAlbumAdapter.php
lib/Service/UploadService.php
lib/Service/UploadTargetService.php
lib/Service/UploadTicketPolicy.php
lib/Service/UploadedFileLocator.php
```

## D. Development artifacts

Excluded from staging, retained in source: AlbumTestResolveCommand,
AlbumTestAddMembershipCommand, AlbumTestService, AlbumMembershipTestService.
No production consumers were found; the commands are not registered. Their
presence was unnecessary, although they were not publicly registered entrypoints.
No productive class was removed. Build/check scripts, tools, tests, this audit,
.git, macOS metadata, private keys, CSRs and certificates are absent.
README and composer.json remain useful installation/autoload metadata. Composer
test scripts are source-development instructions, not executable package hooks.
README's relative protocol links refer to repository documentation outside the
archive; they are documentation links, not runtime file dependencies.

## E. Runtime dependencies

PHP >= 8.2; no Composer runtime packages and no vendor directory/install required.
OCP interfaces, framework, database and filesystem services and Symfony Console
are provided by Nextcloud. Album services also require the enabled Photos app's
`OCA\Photos\Album\AlbumMapper`: this is NOT a core API or packaged class.
An installation without Photos cannot be claimed to support album operations.
All explicitly imported APC classes and registered commands resolve in the
extracted package. There are no runtime include/require statements or detected
external filesystem references in app code.

## F. Fresh package simulation

Extracted only the archive under `/tmp/apc-presign-final.NAwMXE/`. Structure,
info.xml/XSD, syntax, 23 PSR-4 class paths, internal imports and command paths
pass. This is static validation, not a full Nextcloud DI/bootstrap installation.
No local Nextcloud runtime was found in the project; no production instance was
modified. Tests cannot establish all external dependency behaviour.

## G. NC34/35 compatibility

No frontend OC.* use or direct private OC class import was found in runtime code.
The external Photos mapper is the principal internal integration risk.
The existing adapter allows exactly Photos 7.0.0 and 8.0.0 and verifies four
method names; it intentionally rejects other versions. Upstream stable34 and
stable35 AlbumMapper sources have matching signatures for create, get,
getForAlbumIdAndFileId and addFile, compatible with the current calls.
This comparison is against branches, not an assertion that release-tag sources
or all NC35 runtime behaviour were verified. No concrete incompatibility was
found that warrants a code refactor. A real NC35/Photos8 album end-to-end run
remains outstanding; metadata and test doubles alone cannot prove compatibility.

Sources:
- https://github.com/nextcloud/photos/blob/stable34/lib/Album/AlbumMapper.php
- https://github.com/nextcloud/photos/blob/stable35/lib/Album/AlbumMapper.php

## H. Verification

- Standalone PHP/SQLite suite: 251 PASS assertions; successful completion.
- PHP lint: 52 files pass.
- Package tests: valid baseline accepted; 19 invalid packages rejected.
- Extracted runtime checks: 23 class mappings pass.
- Official App Store info.xsd validation passes.
- git diff --check passes.

## I. Test archive

`.build/server/apple_photos_connector-0.8.1.tar.gz`: 953006 bytes.
SHA-256: `b838f7a9b6b7eb106c1dada531f1d01a0fca429b8cffb1538ff25cb9ec03a41b`.
Unsigned local test artifact; no claim of reproducible archive timestamps.

## J. Open before signing

Complete real NC35/Photos8 integration verification. Signing remains explicitly
outside this task; no keys or certificates were packaged.

## K. Working tree

Existing changes preserved: root README.md/README.de.md, nextcloud-app README.md,
info.xml, check-package.sh, NextcloudAlbumAdapter.php, tests/adapter.php,
tests/membership-command.php; untracked CHANGELOG.md, LICENSE, build-package.sh,
tests/package.php, tools/check-package.php and unrelated teaser DOCX.
The working tree remains dirty; no commit, tag, push or release performed.

## L. Additional changes in this follow-up

- build-package.sh: exclude four development classes; make directly executable.
- tools/check-package.php: reject development classes/scripts and certificate files/content.
- tests/package.php: baseline acceptance and expanded negative cases.
- tests/package-runtime.php: new extracted-package static runtime checks.
- PRE_SIGNING_AUDIT.md: this report, deliberately outside the release package.
