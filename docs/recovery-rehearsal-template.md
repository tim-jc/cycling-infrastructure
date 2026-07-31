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
- Runtime credential ciphertext identifier/digest/date:

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
- [ ] Database and runtime credentials restored.
- [ ] Intended repository commits and image identities recorded.
- [ ] Bootstrap/migrations, publication validation and full daily run succeeded.
- [ ] Notifications reported the target physical host.
- [ ] Backup-health status was reviewed, not suppressed.
- [ ] Scheduling was enabled only after all manual acceptance stages.
- [ ] Every finding has an owner and disposition.

Result: PASS / FAIL

Formal DR sign-off: **NOT PERMITTED after the first rehearsal.** The second clean-SD-card rehearsal must meet every criterion. Any material undocumented intervention is a new defect and may require another rehearsal.
