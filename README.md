# Nextcloud Apple Photos Connector

English | [Deutsch](README.de.md)

## What is it?

A safe, non-destructive Apple Photos importer for Nextcloud with incremental uploads, album preservation and stable asset identities.

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

## Current status

APC 0.8.0 is a development milestone. The current local verification includes one successful manual flow:

Apple Photos → PhotoKit selection → Stable Identity → Inventory → upload ticket → original export → Prepare → WebDAV PUT → Complete → file at the configured Nextcloud Target Root.

Automated verification: Swift **60/60 PASS** and PHP/SQLite tests **PASS**. This is not a claim of production readiness. Multi-Source operation, album synchronization, re-inventory and retarget behavior remain documented and tested locally, while broader deployment validation is still required.

## Albums

Album inventory and synchronization are supported as a separate step. Membership is source-aware and idempotent. Missing source data is not treated as a delete request, and folders are not created as Photos albums.

## Requirements

- macOS 14 or newer
- Xcode/Swift 6 for development
- Nextcloud with the APC server app and HTTPS
- A Nextcloud App Password for the client
- Apple Photos access granted to the macOS app

## Installation

The repository contains the client, server app and protocol reference. Follow [server documentation](nextcloud-app/README.md), [macOS documentation](mac-agent/README.md) and [protocol documentation](protocol/README.md). Use a fresh Connector state for development validation; upgrade paths from earlier experiments are outside this milestone.

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
- Packaging, distribution and installation documentation
- Upstream discussion of a generic external-photo-source abstraction

## Project status

The project is an active development prototype. The documented safeguards and local tests are part of the current design; deployment, migration and operational support require additional validation.
