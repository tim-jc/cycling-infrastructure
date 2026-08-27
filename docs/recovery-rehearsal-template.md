# Recovery Rehearsal Record

Maintain this record during the exercise. Do not reconstruct it only at the end and do not include secrets.

## Identity

- Rehearsal date:
- Operator:
- Target hostname:
- OS release/architecture:
- Infrastructure commit SHA:
- Platform commit SHA:
- Compose image IDs/digests:
- Restore backup prefix and timestamp:
- Backup format: historical four-file / current five-file
- Six-database inventory, Reference charset/collation and application-grant result:
- Historical restore Reference-empty result (if applicable):
- Runtime credential ciphertext identifier/digest/date:
- Runtime credential backup verification result:
- Runtime credential restore/remote metadata verification result:
- Static configuration ciphertext identifier/digest/date and verification result:
- Database restore completion time:

## Live timeline

| Time | Runbook phase/step | Command or action | Result/evidence reference | Intervention or deviation ID |
|---|---|---|---|---|

## Findings and interventions

| ID | Type: defect/deviation/discovery/manual intervention | What happened | Immediate action | Proposed code/doc change | Owner/status |
|---|---|---|---|---|---|

## Migration and validation evidence

- Platform bootstrap exit status/log:
- Migration ledger query result reference:
- Migration checksum verification result:
- Publication validation exit status/log:
- Deployment-ready evidence result:
- Provider catch-up result:
- Full daily run start/end/exit status/log:
- Notification result and reported host:
- Backup-health status, restored-backup age and scheduling state:

## Stop conditions encountered

- Condition:
- Resolution:
- Was proceeding explicitly approved, and by whom?

## Sign-off

- [ ] Revised runbook followed from start to finish.
- [ ] No undocumented corrective intervention occurred.
- [ ] Database, static configuration and runtime credentials restored and verified.
- [ ] Intended repository commits and image identities recorded.
- [ ] Bootstrap/migrations, publication validation and full daily run succeeded.
- [ ] Notifications reported the target physical host.
- [ ] Backup-health status was reviewed, not suppressed.
- [ ] Scheduling was enabled only after all manual acceptance stages.
- [ ] Every finding has an owner and disposition.
- [ ] Final operational checks passed: MariaDB healthy, no application containers or managed locks, protected metadata correct, hostname correct.
- [ ] DR acceptance record reports `dr_acceptance=passed`.

Result: PASS / FAIL

Rehearsal 4 established DR sign-off for the current architecture. A future
exercise passes only when every applicable criterion above is met; a genuine
correctness defect must be fixed and may warrant another rehearsal.
