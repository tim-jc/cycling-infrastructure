# Runtime Credential Backup and Recovery

## Contract

The authoritative live copy is `/srv/cycling/config/platform/runtime.Renviron` on `cycling-prod`. It contains mutable application credentials; `cycling-platform` updates keys through `update_renviron()`. Infrastructure owns its dedicated directory, mode, encrypted backup and restoration. Compose mounts `/srv/cycling/config/platform` at `/run/cycling-platform:rw`; the application still selects `/run/cycling-platform/runtime.Renviron`. It is not part of Git or the MariaDB dumps. The parent directory must contain no unrelated files. A directory bind mount is deliberate: token persistence creates a sibling temporary file and renames it over `runtime.Renviron`; a direct bind mount of the target file makes that atomic rename fail with `Device or resource busy`.

`scripts/compose.sh` resolves the host `tim` account's numeric UID/GID and Compose runs platform jobs under that identity. This guarantees that the temporary inode created by `update_renviron()` and atomically renamed onto the bind-mounted host filesystem remains `tim:tim`. The canonical ownership is required so the operator can recover the file and so future non-root platform jobs can update it; mode `0600` prevents group or world access.

The live file is authoritative for current token state. The recovery copy is an encrypted off-host snapshot and must be refreshed after OAuth bootstrap, token rotation, or an intentional credential change. Until that reconciliation is automated and tested, the operator must perform it after any such event.

## Recommended design: age-encrypted off-host file

Use `age` on the Mac with a recovery recipient whose private identity is backed up independently. Store only the `.age` ciphertext in a protected Mac recovery directory that itself is included in Mac backup. Do not put the identity and ciphertext on the Pi or in Git.

Manual decisions required before first use:

1. choose the `age` recipient/public key;
2. choose the Mac ciphertext destination and its independent backup;
3. name the custodian responsible for the private age identity and its independent backup;
4. name the operator responsible for refreshing the ciphertext after credential-changing events.

This implementation is deliberately manual. A future separately reviewed change may schedule it after the 05:00 database backup, but automation is outside the current contract. The decryption identity remains outside the Pi.

## Backup procedure

Install `age` on the trusted Mac and run from its `cycling-infrastructure` checkout. The identity must be a regular mode-`0600` file. The destination must be an absolute `.age` path in a protected directory included in Mac backup.

```bash
./scripts/backup_runtime_credentials.sh \
  --recipient AGE_RECIPIENT \
  --identity /secure/path/to/age-identity \
  --output /approved/encrypted/cycling-recovery/runtime.Renviron.age
```

The script pulls the production file into an owner-only temporary directory, validates required token presence, encrypts it, decrypts the candidate, compares plaintext without displaying it, then atomically replaces the ciphertext and its mode-`0600` `.metadata` sidecar. Temporary plaintext is removed on exit; encrypted/SSD filesystems may not provide meaningful overwrite guarantees. Output reports the timestamp, source, ciphertext path and SHA-256 only.

Verify independently at any time:

```bash
./scripts/verify_runtime_credentials.sh \
  --ciphertext /approved/encrypted/cycling-recovery/runtime.Renviron.age \
  --identity /secure/path/to/age-identity
```

## Restore procedure

After reviewing the non-secret `.metadata` timestamp, source and digest, restore from the trusted Mac. The explicit hostname assertion and replacement confirmation are mandatory and support either production or an isolated rehearsal target:

```bash
./scripts/restore_runtime_credentials.sh \
  --ciphertext /approved/encrypted/cycling-recovery/runtime.Renviron.age \
  --identity /secure/path/to/age-identity \
  --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test \
  --confirm-replace
```

Restore verifies the ciphertext digest/decryption first, transfers an owner-only staging file, validates the dedicated target directory and token presence, atomically replaces the target, removes staging material and invokes remote verification. It never starts MariaDB or the application.

Repeat remote verification without restoring:

```bash
./scripts/verify_runtime_credentials.sh \
  --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test
```

This confirms hostname, `tim:tim` ownership, directory mode `0700`, file mode `0600`, dedicated-directory contents, and required token presence. It does not print values. After platform deployment, provider authentication remains the final functional check. Re-authorise rather than repeatedly using a token that returns `invalid_grant`, then refresh the encrypted backup immediately.

## Ownership drift detection and repair

Both platform preflight and runtime credential verification fail if the directory or file is not owned by `tim:tim`. Do not relax those checks and do not use periodic ownership correction. If drift is ever observed, deploy the Compose UID/GID contract first, ensure no platform container or managed operation is active, and then repair the existing inode once without displaying its contents:

```bash
cd /home/tim/cycling-infrastructure
./scripts/compose.sh ps

credential=/srv/cycling/config/platform/runtime.Renviron
before_digest="$(sudo sha256sum "$credential" | awk '{print $1}')"
sudo chown tim:tim "$credential"
sudo chmod 0600 "$credential"
after_digest="$(sha256sum "$credential" | awk '{print $1}')"
test "$before_digest" = "$after_digest"

stat -c '%U:%G %a %s %n' /srv/cycling/config/platform /srv/cycling/config/platform/runtime.Renviron
./scripts/preflight.sh
```

The digests are safe evidence about file identity, not credential values. After repair, use a no-ingestion container check to exercise the real mount and atomic replacement while retaining the exact bytes:

```bash
before_digest="$(sha256sum "$credential" | awk '{print $1}')"
./scripts/compose.sh run --rm --no-deps --entrypoint sh cycling-platform -c '
  set -eu
  target=/run/cycling-platform/runtime.Renviron
  candidate=/run/cycling-platform/.runtime-renviron-ownership-check
  cp "$target" "$candidate"
  chmod 0600 "$candidate"
  mv -f "$candidate" "$target"
'
after_digest="$(sha256sum "$credential" | awk '{print $1}')"
test "$before_digest" = "$after_digest"
stat -c '%U:%G %a %s %n' "$credential"
```

This deliberately performs no OAuth request or ingestion. The final owner must remain `tim:tim`, the mode `0600`, and the digest unchanged. The encrypted backup workflow may resume only after these checks pass.

## Recovery acceptance

A credential recovery test passes only if ciphertext digest/decryption verification succeeds, the remote verifier confirms the dedicated directory and restored file metadata plus required token presence, provider authentication succeeds after deployment, and the evidence record identifies when the encrypted snapshot was last refreshed.
