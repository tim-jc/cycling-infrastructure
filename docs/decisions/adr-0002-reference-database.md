# ADR-0002: Introduce a durable Reference database

- Status: Accepted
- Date: 2026-08-05

## Decision

Introduce `cycling_platform_reference` as a sixth peer MariaDB database. It holds reusable, deliberately curated platform knowledge that does not originate as an external observation. Examples may later include FTP history, canonical bike mappings, coastal definitions, riders, regions and maintenance policies, but this decision introduces no objects.

Admission follows these boundaries:

- external observations enter Raw and become canonical in Silver;
- reusable human-curated platform knowledge belongs in Reference;
- consumer-oriented analytical products belong in Gold;
- operational metadata belongs in Admin;
- temporary ETL workspace belongs in Stage.

Reference is a peer rather than part of Gold because curated canonical knowledge is an input to analytical products, not itself a consumer-shaped output.

`cycling-infrastructure` is authoritative for physical database creation, database-level settings, grants, existing-instance reconciliation, restore execution and recovery procedures. `cycling-platform` owns every object inside Reference, including DDL, migrations, contracts, metadata, loaders, object validation and Gold consumption.

All platform databases use `utf8mb4` with `utf8mb4_general_ci`. Reference is durable even while empty. Admin, Raw, Reference, Silver and Gold are backed up and restored; Stage remains the sole disposable database. Historical four-file backup sets predating Reference remain restorable and produce an empty Reference database.

## Consequences

Fresh MariaDB initialization creates six databases. Existing volumes require the explicit idempotent infrastructure reconciliation command because `/docker-entrypoint-initdb.d` is first-initialization only. Deployment readiness checks require Reference existence, canonical settings, database-scoped application access and absence of unintended global privileges.

The Mac-side backup implementation and observability remain in `cycling-platform`; infrastructure defines recovery expectations and owns guarded restoration. The two repositories must coordinate the transition from four to five durable dump files.

FTP history and all other Reference object design are deferred.
