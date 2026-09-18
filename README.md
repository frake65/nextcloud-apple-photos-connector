# Nextcloud Apple Photos Connector

English | [Deutsch](README.de.md)

The current server app patch is 0.8.6; the separate **Nextcloud APC** macOS
agent is at 0.8.3. App Store submission is being prepared; the signing
certificate is pending. The macOS app is required
and will not be distributed through the Nextcloud App Store. Server metadata
targets Nextcloud 34–35. Idempotence and album recovery were manually verified
against Nextcloud 35 and Photos 8.0.0.

## What is it?

Apple Photos Connector (APC) consists of two components, and both are
required:

- the Nextcloud server app `apple_photos_connector`
- the macOS app `Nextcloud APC`

The server app maintains import status, upload targets and album information.
The macOS agent uses Apple's PhotoKit to read Apple Photos and transfer the
selected photos to Nextcloud.

APC is non-destructive: it does not delete Nextcloud files because a photo is
missing from Apple Photos, does not overwrite existing foreign files, and does
not re-upload photos that are already known to the server.

> **Install the Nextcloud server app first.** The macOS app cannot connect until
> `apple_photos_connector` is copied to Nextcloud's `custom_apps` directory and
> enabled with `occ`. See [Server installation](#nextcloud-server-app--standard-installation)
> before installing the macOS app.

## Key principles

- PhotoKit is read locally by the macOS agent.
- The server keeps the authoritative import history.
- Selection determines inventory; the server determines transfer.
- Stable Asset Identity is used instead of filenames.
- Multiple Sources remain isolated.
- Existing Nextcloud files are never overwritten automatically.
- Missing Apple Photos assets do not delete Nextcloud files or album memberships.
- WebDAV carries binary files; Photos database internals are not required.

## Architecture

| Component | Responsibility |
| --- | --- |
| `mac-agent/` | SwiftUI app, PhotoKit selection, inventory, original export and WebDAV transport |
| `nextcloud-app/` | PHP app, inventory history, upload targets, tickets and album membership |
| `protocol/` | JSON schemas and the shared API contract |

Album Membership and file transfer are separate operations. Album names are not identities; Source and Asset identities remain stable across retries.

## Release 0.8.2

Release 0.8.2 contains the current stable connector architecture. The GitHub
release provides both required components:

- `apple_photos_connector-0.8.2.tar.gz` — Nextcloud server app
- `Nextcloud-APC-0.8.2.zip` — universal macOS agent for Apple Silicon and Intel

## Albums

Album inventory and synchronization are supported as a separate step. Membership is source-aware and idempotent. Missing source data is not treated as a delete request, and folders are not created as Photos albums.

## Requirements

- macOS 14 or newer
- Xcode/Swift 6 for development
- Nextcloud with the APC server app and HTTPS
- A Nextcloud App Password for the client
- Apple Photos access granted to the macOS app

## Installation

Install and activate the Nextcloud server app before installing the macOS
agent. Then configure the connection in the agent and start an import.

### Nextcloud server app — standard installation

1. Download `apple_photos_connector-0.8.2.tar.gz` from the GitHub release.
2. Extract it; the archive contains the app directory
   `apple_photos_connector/`.
3. Copy that directory to the Nextcloud directory configured for additional
   apps, typically `custom_apps`.
4. Set ownership to the web server user and enable the app with `occ`.

For a typical installation under `/var/www/html`:

```sh
tar xzf apple_photos_connector-0.8.2.tar.gz
sudo mv apple_photos_connector /var/www/html/custom_apps/
sudo chown -R www-data:www-data /var/www/html/custom_apps/apple_photos_connector
cd /var/www/html
sudo -u www-data php occ app:enable apple_photos_connector
```

Paths and the web server user vary by distribution and installation method.

### Nextcloud server app — Nextcloud AIO

Nextcloud AIO is containerized. Do not run the standard-installation commands
blindly on the host. The supported deployment structure used for APC places
the app in the Nextcloud container at:

`/var/www/html/custom_apps/apple_photos_connector`

One safe AIO procedure is to copy the archive to the container, extract it in
a temporary container directory, and then copy the app into `custom_apps`:

```sh
docker cp apple_photos_connector-0.8.2.tar.gz nextcloud-aio-nextcloud:/tmp/
docker exec nextcloud-aio-nextcloud sh -c \
  'rm -rf /tmp/apple_photos_connector && tar xzf /tmp/apple_photos_connector-0.8.2.tar.gz -C /tmp'
docker exec nextcloud-aio-nextcloud sh -c \
  'rm -rf /var/www/html/custom_apps/apple_photos_connector && \
   cp -a /tmp/apple_photos_connector /var/www/html/custom_apps/'
docker exec nextcloud-aio-nextcloud sh -c \
  'chown -R www-data:www-data /var/www/html/custom_apps/apple_photos_connector'
docker exec --user www-data nextcloud-aio-nextcloud \
  php occ app:enable apple_photos_connector
docker exec --user www-data nextcloud-aio-nextcloud \
  php occ app:list
```

The container name may differ in a particular AIO installation. Verify the
actual Nextcloud container and the resulting app path before enabling the app.
Because manually copied files in `custom_apps` depend on the AIO storage
layout, confirm that this directory is backed by the persistent AIO setup and
repeat the installation after a container recreation if that setup does not
persist custom apps.

### macOS agent

1. Download `Nextcloud-APC-0.8.2.zip` from the GitHub release.
2. Extract the ZIP and move `Nextcloud APC.app` to `/Applications` (Programme).
3. Start the app.
4. Allow access to Apple Photos when macOS asks for permission.
5. Configure the Nextcloud connection in the app's settings.

The agent requires macOS 14 Sonoma or newer and supports both Apple Silicon
and Intel. It is Developer-ID signed and Apple notarized. Access to the photo
library uses Apple's PhotoKit and requires the macOS Photos-library permission.

### Recommended order

1. Install and enable the Nextcloud server app.
2. Install the macOS agent.
3. Configure the Nextcloud connection.
4. Test the connection.
5. Select photos and albums.
6. Choose **Fotos & Alben übernehmen** / **Import Photos & Albums**.

### Updates

When updating the Nextcloud app, keep APC's database and import information.
The server-side import history is used to recognize already transferred
photos. Do not delete APC database tables as part of an app update.

## Development

```sh
cd mac-agent
CONFIGURATION=debug bash build-app.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox
```

The PHP/SQLite suite runs with `php nextcloud-app/tests/run.php`. No command above requires a live server.

## Documentation

- [macOS agent](mac-agent/README.md)
- [Nextcloud app](nextcloud-app/README.md)
- [Protocol](protocol/README.md)
- [Upload flow](protocol/uploads.md)

Historical development and test reports remain in `docs/`; they are not normative API documentation.

## Roadmap

- Broader manual validation across multiple Sources and libraries
- More complete Photos album interoperability validation
- Complete App Store signing and submission
- Upstream discussion of a generic external-photo-source abstraction

## Project status

The project is an active development prototype. The documented safeguards and local tests are part of the current design; deployment, migration and operational support require additional validation.
