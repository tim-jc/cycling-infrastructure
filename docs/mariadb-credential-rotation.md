# MariaDB Credential Rotation

Changing `compose/.env` does not change accounts inside an initialized MariaDB data directory. Rotation is an explicit database operation followed by coordinated consumer updates.

## Preparation

1. Disable Pi platform cron and pause the Mac backup schedule.
2. Inventory application, root/administrative, backup, analytics, monitoring and reporting consumers without recording passwords.
3. Generate new credentials in the approved secret store. Do not pass passwords as command-line arguments or place them in logs.
4. Back up MariaDB and confirm the latest four-file set is complete.
5. Prepare rollback values in the approved secret store.

## Application credential rotation

From the Compose directory, open an administrative client using the container environment or another approved protected credential source. Execute an `ALTER USER ... IDENTIFIED BY ...` operation using an input method that does not expose the new password in shell history. Then update, in a controlled maintenance window:

- `compose/.env` on the Pi;
- Mac backup/native `.Renviron` or equivalent protected configuration;
- analytics, reporting and monitoring consumers using the application account;
- any scheduled-job configuration outside Git.

Recreate a disposable Compose job and verify DB connectivity. Verify Mac backup connectivity and each dependent consumer before retiring rollback access.

## Root/administrative rotation

Rotate the MariaDB root account explicitly inside MariaDB, then update the protected `MARIADB_ROOT_PASSWORD` recovery source and `compose/.env`. Root is not used by routine platform jobs. Verify a container-local administrative connection without printing the value.

## Dedicated accounts

If backup, monitoring or reporting later receive dedicated accounts, rotate each independently using least privilege. Update and verify its single consumer before moving to the next account.

## Rollback

If a consumer was missed, either update that consumer promptly or restore the prior database password using the same explicit `ALTER USER` procedure. Merely reverting `.env` is not rollback. Keep schedules paused until application, backup and reporting checks all pass.

## Completion evidence

Record account names/roles, rotation time, affected secret-store records, consumer checks, backup result and whether rollback was needed. Never record credential values. Resume schedules only after verification.
