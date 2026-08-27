# Disaster-Recovery Rehearsal History

## Bare-metal Recovery Rehearsal 4 — PASSED

- Date: 14 August 2026
- Recovery host: `cycling-recovery-test`
- Recovery set: `2026-08-12_122819`
- Result: DR sign-off for the current architecture

The rehearsal rebuilt a fresh Debian 13.5 Raspberry Pi host, restored encrypted
static Compose configuration and encrypted runtime credentials, restored the
five durable databases (Admin, Raw, Reference, Silver and Gold), and
deliberately excluded disposable Stage. An explicit platform revision was
deployed and passed bootstrap, migrations and restored-state publication
validation. The normal daily pipeline then completed Raw, Silver and Gold,
including notifications, with status 0 in approximately 2029 seconds. No
manual Silver repair was required. Production scheduling remained disabled on
the isolated host, and final metadata, health, container, lock and hostname
checks passed.

The restore completed at `2026-08-13T22:32:41+01:00`. The database restore RTO
remains accepted technical debt: the restore took approximately 30 hours.

## Accepted technical debt

- **Investigate MariaDB disaster-recovery restore performance / RTO.** Restore
  correctness is proven, but a greater-than-24-hour restore is operationally
  poor. Future work may evaluate dump strategy, indexes, MariaDB settings and
  storage performance without changing the signed-off logical workflow.
- The isolated recovery host used Wi-Fi and experienced transient SSH loss.
  Durable restore execution in `tmux` protected correctness; networking is not
  redesigned as part of sign-off.

