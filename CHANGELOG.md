# Changelog

All notable changes to the cycling-infrastructure project are documented here.

## [Unreleased]

### Added

- Docker Compose deployment for MariaDB 11 and ephemeral `cycling-platform` jobs.
- First-initialisation creation of the five `cycling_platform_*` schemas.
- Cron entry points for the 02:00 daily run and 03:30 deep validation.
- Current architecture and operations documentation.

### Changed

- Production deployment completed on `cycling-prod`.
- Scheduling uses cron on `cycling-prod`.
- Database backup runs off-host on the Mac at 05:00 and excludes disposable `cycling_platform_stage`.
- Bootstrap now creates only the persistent data and log paths used by the deployed Compose project.
- Transitional bootstrap and session notes were consolidated into enduring documentation.

### Removed

- Empty bootstrap stages and unused `config` and `systemd` scaffolding.
- Obsolete on-host database backup path.

---

## [0.1.0] - 2026-07-10

### Added

- Raspberry Pi OS Lite
- SSH public key authentication
- Hostname: cycling-prod
- Headless configuration
- Wi-Fi configuration
- Initial project documentation
