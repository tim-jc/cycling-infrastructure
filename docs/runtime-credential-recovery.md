# Runtime Credential Backup and Recovery

## Contract

The authoritative live copy is `/srv/cycling/config/platform/runtime.Renviron` on `cycling-prod`. It contains mutable application credentials; `cycling-platform` updates keys through `update_renviron()`. Infrastructure owns its directory, mode, encrypted backup and restoration. It is not part of Git or the MariaDB dumps.

The live file is authoritative for current token state. The recovery copy is an encrypted off-host snapshot and must be refreshed after OAuth bootstrap, token rotation, or an intentional credential change. Until that reconciliation is automated and tested, the operator must perform it after any such event.

## Recommended design: age-encrypted off-host file

Use `age` on the Mac with a recovery recipient whose private identity is backed up independently. Store only the `.age` ciphertext in a protected Mac recovery directory that itself is included in Mac backup. Do not put the identity and ciphertext on the Pi or in Git.

Decision required before implementation:

1. choose the `age` recipient/public key;
2. choose the Mac ciphertext destination and its independent backup;
3. name the operator responsible for refreshing it;
4. decide whether refresh is manual after credential-changing events or automated with a tightly scoped SSH pull.

Start with the documented manual flow for the next rehearsal. For production freshness, the recommended steady-state design is a Mac-scheduled pull immediately after the 05:00 database backup: fetch to a mode-`0600` temporary file, encrypt with the public recipient, verify decryption, atomically replace the ciphertext, and record source host/time/digest. The decryption identity remains outside the Pi. This expands the Mac backup job's SSH access but avoids relying on an operator after every automatic token rotation. A password-manager secure-file attachment is simpler but makes freshness and automated verification less visible. An encrypted disk-image copy is acceptable but operationally heavier.

## Backup procedure

Run from the Mac. Replace placeholders with approved non-secret paths/recipient identifiers; do not place credential values on the command line.

```bash
umask 077
mkdir -p /approved/encrypted/cycling-recovery
scp tim@cycling-prod.local:/srv/cycling/config/platform/runtime.Renviron \
  /private/tmp/cycling-runtime.Renviron
chmod 600 /private/tmp/cycling-runtime.Renviron
age --recipient AGE_RECIPIENT \
  --output /approved/encrypted/cycling-recovery/runtime.Renviron.age.new \
  /private/tmp/cycling-runtime.Renviron
age --decrypt --identity /secure/path/to/age-identity \
  --output /private/tmp/cycling-runtime.verify \
  /approved/encrypted/cycling-recovery/runtime.Renviron.age.new
cmp -s /private/tmp/cycling-runtime.Renviron /private/tmp/cycling-runtime.verify
mv /approved/encrypted/cycling-recovery/runtime.Renviron.age.new \
  /approved/encrypted/cycling-recovery/runtime.Renviron.age
```

Remove the two temporary plaintext files immediately using the operating system's approved protected-temporary-file procedure; encrypted/SSD filesystems may not provide meaningful overwrite guarantees. Record backup time, source hostname, ciphertext path and a SHA-256 digest of the ciphertext—not plaintext—in the recovery evidence. Never print or diff plaintext.

## Restore procedure

Decrypt on the recovery operator's trusted machine into an owner-only temporary file, verify the expected ciphertext digest and freshness record, then copy it to the prepared host:

```bash
umask 077
age --decrypt --identity /secure/path/to/age-identity \
  --output /private/tmp/cycling-runtime.Renviron \
  /approved/encrypted/cycling-recovery/runtime.Renviron.age
scp /private/tmp/cycling-runtime.Renviron \
  tim@TARGET_HOST:/home/tim/runtime.Renviron.recovery
ssh tim@TARGET_HOST \
  'sudo install -o tim -g tim -m 0600 /home/tim/runtime.Renviron.recovery /srv/cycling/config/platform/runtime.Renviron && rm /home/tim/runtime.Renviron.recovery'
```

Verify only metadata and token presence through the Compose diagnostic in the bootstrap runbook. If freshness is uncertain, test provider authentication. Re-authorise rather than repeatedly using a token that returns `invalid_grant`. Refresh the encrypted backup immediately after re-authorisation.

## Recovery acceptance

A credential recovery test passes only if the ciphertext decrypts, the restored file is `tim:tim` mode `0600`, a fresh Compose container reports required tokens present without printing them, provider authentication succeeds, and the evidence record identifies when the encrypted snapshot was last refreshed.
