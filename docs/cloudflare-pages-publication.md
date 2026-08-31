# Cloudflare Pages analytics publication

Production analytics publication is owned by `cycling-infrastructure`. The
`cycling-analytics` application owns only the complete static artefact at
`/srv/cycling/data/analytics/output` (`index.html` plus non-empty
`index_files/`). Infrastructure publishes that complete directory to Cloudflare
Pages project `cycling-analytics`; the stable generated hostname is
<https://cycling-analytics-8bs.pages.dev>.

## Runtime and credentials

`scripts/publish_analytics.sh` invokes the ephemeral
`cloudflare-pages-publisher` Compose service. Its image pins Node
`22.18.0-bookworm-slim` and Wrangler `4.33.1`; Wrangler is never installed on the
host or in the analytics application image. Authentication is non-interactive
and requires no Wrangler login state.

The host credential is `/srv/cycling/config/analytics/cloudflare.env`, owned by
`tim:tim` with mode `0600`; its parent is `tim:tim` mode `0700`. It contains
exactly:

```text
CLOUDFLARE_ACCOUNT_ID=a3bd40c6603f35a6c5baf7952c167823
CLOUDFLARE_API_TOKEN=<Pages Edit token>
```

The account ID is non-secret but remains beside the token so one validated
credential asset identifies the intended account. The publisher rejects a
wrong account, missing/duplicate keys and unrelated keys. Compose receives the
two variables by name from the publisher process; the token is not stored in
Compose, command arguments, images or logs.

## Operation

Build the pinned publisher runtime after infrastructure deployment:

```bash
cd /home/tim/cycling-infrastructure
./scripts/compose.sh build cloudflare-pages-publisher
```

A standalone publication of an already completed artefact is:

```bash
./scripts/verify_static_config.sh --profile cloudflare \
  --plaintext /srv/cycling/config/analytics/cloudflare.env
./scripts/publish_analytics.sh
```

Normal scheduled execution uses `run_analytics_refresh.sh`: render, validate the
local artefact, publish, then notify. Render failure never invokes publication.
Publication failure leaves the valid local artefact and existing Cloudflare
deployment untouched, returns non-zero and reports `Failed stage: publication`.
Success means both rendering and Cloudflare publication succeeded.

The analytics render lock covers publication. Standalone publishing acquires
that lock and also refuses analytics deployment or database restore overlap.
The internal `--from-refresh` flag is used only by the parent refresh that
already owns the lock.

## Encrypted recovery asset

The Cloudflare token is recovered separately from Compose configuration. On the
Mac, copy it into a mode-0600 temporary file, then use the existing age workflow:

```bash
./scripts/backup_static_config.sh --profile cloudflare \
  --source /SECURE/TEMP/cloudflare.env \
  --recipient AGE_RECIPIENT \
  --identity /SECURE/AGE/identity.txt \
  --output /APPROVED/RECOVERY/cloudflare-publisher.env.age

./scripts/verify_static_config.sh --profile cloudflare \
  --ciphertext /APPROVED/RECOVERY/cloudflare-publisher.env.age \
  --identity /SECURE/AGE/identity.txt
```

Delete the temporary plaintext after successful verification. Keep the age
identity off cycling-prod. The ciphertext metadata records a SHA-256 digest and
uses format `cycling-static-cloudflare-age-v1`.

After bootstrap has recreated the protected analytics configuration directory,
restore from the Mac with:

```bash
./scripts/restore_static_config.sh --profile cloudflare \
  --ciphertext /APPROVED/RECOVERY/cloudflare-publisher.env.age \
  --identity /SECURE/AGE/identity.txt \
  --target tim@cycling-prod \
  --expected-hostname cycling-prod \
  --confirm-replace
```

Verify the restored plaintext profile and build the publisher image before a
controlled refresh. Keep application scheduling disabled during disaster
recovery until rendering, publication and notifications have passed.

The legacy Mac/GitHub Pages path remains an explicit rollback option until the
new production path has passed a controlled publication and an observed
scheduled cycle. Its retirement is separate work.
