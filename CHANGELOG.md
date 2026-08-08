# Changelog

All notable changes to the cycling-infrastructure project are documented here.

## [Unreleased]

### Added

- Guarded `age`-encrypted backup, verification and atomic recovery tooling for
  the cycling-platform runtime OAuth credential file.
- Docker Compose deployment for MariaDB 11 and ephemeral `cycling-platform` jobs.
- First-initialisation creation of six `cycling_platform_*` databases with explicit canonical defaults.
- Idempotent existing-instance provisioning and readiness checks for `cycling_platform_reference`.
- Restore compatibility for historical four-file and current five-file durable backup sets.
- Cron entry points for the 02:00 daily run and 03:30 deep validation.
- Current architecture and operations documentation.

### Changed

- Database restore and operator Compose commands now share one canonical host
  identity and runtime UID/GID initialization contract.
- Ephemeral platform jobs now run as the host `tim` UID/GID, preserving
  `tim:tim` ownership when runtime credentials are atomically replaced.
- Host bootstrap now uses deterministic numbered stages for system update, packages, Docker, production paths and final verification, with explicit reboot-and-rerun handling.
- Production deployment completed on `cycling-prod`.
- Scheduling uses cron on `cycling-prod`.
- Database backup runs off-host on the Mac at 05:00 and excludes disposable `cycling_platform_stage`.
- Reference is a durable peer database; Stage remains the only disposable database.
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
