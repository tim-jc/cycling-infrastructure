# Static Compose Configuration Recovery

`compose/.env` is an ignored, owner-only deployment input. Its authoritative
recovery copy is an `age`-encrypted asset held off the Pi, with its generated
`.metadata` file. It is separate from the independently encrypted
`runtime.Renviron`: OAuth client credentials are static; refresh tokens are
mutable runtime credentials and are forbidden in the static asset.

The static contract requires MariaDB user, application/root passwords and
port, Strava and Google Health client IDs/secrets, and the ntfy topic.
`NTFY_BASE_URL` is optional. Host identity and runtime UID/GID are derived by
the Compose wrapper and must not be stored in this asset.

Create and verify an asset on the trusted Mac without displaying values:

```bash
./scripts/backup_static_config.sh --source /SECURE/SOURCE/compose.env \
  --recipient AGE_RECIPIENT --identity /SECURE/IDENTITY/age-identity \
  --output /APPROVED/RECOVERY/compose.env.age
./scripts/verify_static_config.sh --ciphertext /APPROVED/RECOVERY/compose.env.age \
  --identity /SECURE/IDENTITY/age-identity
```

Whenever a represented production secret changes, creating and verifying a new
encrypted static-config asset is part of that same credential-rotation
procedure. Periodic review is only a secondary safeguard. Keep the working age
identity on the trusted Mac and one separately protected backup copy; verify
both identities derive the same public recipient. Record only their approved
location convention and custodian—never the private-key material. Keep the
identity separately from the ciphertext. The metadata digest
identifies the ciphertext; successful decryption and contract validation
establish usability.

After host bootstrap, restore from the trusted Mac:

```bash
./scripts/restore_static_config.sh --ciphertext /APPROVED/RECOVERY/compose.env.age \
  --identity /SECURE/IDENTITY/age-identity \
  --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test --confirm-replace
```

The restore uses owner-only temporary files, verifies the plaintext contract,
asserts the remote hostname, atomically installs `compose/.env`, and verifies
`tim:tim` mode `0600`. It never prints values. Use expected hostname
`cycling-prod` for production. Replacement always requires confirmation.
