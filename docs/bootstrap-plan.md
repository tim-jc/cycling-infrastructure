# Bootstrap Guide

## Session 1 – Prepare the SD Card

### Objective

Create a bootable, production-ready Raspberry Pi OS image.

### Completed

* Installed **Raspberry Pi OS Lite (64-bit)** using Raspberry Pi Imager.
* Selected Raspberry Pi 5 as the target device.
* Configured hostname: `cycling-prod`.
* Created administrator account: `tim`.
* Configured Wi-Fi.
* Configured locale, keyboard layout and timezone.
* Enabled SSH.
* Generated an Ed25519 SSH key pair on the Mac.
* Configured SSH public key authentication using the generated public key.
* Chose not to enable Raspberry Pi Connect.
* Successfully wrote and verified the operating system image on the SD card.

### Outcome

The Raspberry Pi was provisioned before first boot and configured for secure, headless administration.

### Status

**Complete**

---

## Session 2 – First Boot

### Objective

Successfully boot the Raspberry Pi, establish remote administration and record the initial system baseline.

### Completed

* Inserted the prepared SD card and successfully booted the Raspberry Pi.
* Connected to the local Wi-Fi network.
* Resolved the server using the hostname `cycling-prod.local`.
* Successfully connected via SSH using public key authentication.
* Accepted and recorded the server host key on the Mac.
* Verified hostname: `cycling-prod`.
* Verified current user: `tim`.
* Verified home directory: `/home/tim`.
* Confirmed that the user is operating as a normal account rather than as `root`.
* Began initial exploration of the Linux filesystem.
* Confirmed the presence of the SSH configuration directory at `/home/tim/.ssh`.

### Remaining Activities

* Verify the operating system and release version.
* Verify the Linux kernel version.
* Verify available and used memory.
* Verify available and used storage.
* Record CPU information.
* Record system temperature.
* Record the initial system baseline in the project documentation.
* Confirm that the basic system health checks produce no unexpected findings.

### Commands to Run

```bash
cat /etc/os-release
uname -a
free -h
df -h
lscpu
vcgencmd measure_temp
```

### Success Criteria

* Raspberry Pi is reachable remotely.
* SSH public key authentication works reliably.
* Server identity and administrator account are confirmed.
* Operating system, kernel, memory, storage, CPU and temperature are recorded.
* Basic system health is confirmed.
* Bootstrap Guide is updated.
* Changes are committed to Git.

### Status

**Complete**

---

## Session 3A – Operating System Bootstrap

### Objective

Turn the freshly installed Raspberry Pi OS environment into an updated, well-understood and manageable Linux server.

This phase establishes the host-level tools required to administer, inspect and maintain `cycling-prod`. It deliberately precedes the installation of Docker so that the underlying operating system is healthy and understood first.

### Activities

#### Review Package Management

* Understand the purpose of the `apt` package manager.
* Understand the difference between:

  * refreshing package metadata;
  * upgrading installed packages;
  * installing new packages;
  * removing unused packages.
* Review which software repositories are currently configured.
* Inspect available updates before applying them.

#### Update the Operating System

* Refresh the local package index.
* Apply available operating system and security updates.
* Review any warnings or configuration prompts.
* Remove packages that are no longer required, where appropriate.
* Determine whether a reboot is required.
* Reboot if necessary.
* Confirm that SSH access returns successfully after the reboot.

#### Install Essential Linux Utilities

Install only tools that have a defined operational purpose.

| Package | Purpose                                                       |
| ------- | ------------------------------------------------------------- |
| `git`   | Version control and deployment from Git repositories          |
| `curl`  | HTTP requests, API testing and downloading resources          |
| `wget`  | Direct file retrieval where appropriate                       |
| `htop`  | Interactive inspection of processes and resource use          |
| `tree`  | Visualising directory structures                              |
| `nano`  | Simple local text editing for operational changes             |
| `unzip` | Extracting ZIP archives                                       |
| `jq`    | Inspecting and transforming JSON data                         |
| `rsync` | Efficient file copying, synchronisation and backup operations |

Some of these packages may already be installed by Raspberry Pi OS. Existing installations should be verified rather than unnecessarily replaced.

#### Verify the Host Tooling

* Confirm each required command is available.
* Record installed versions where useful.
* Confirm Git can run successfully.
* Confirm outbound HTTPS access works.
* Confirm available disk space remains healthy.
* Confirm no failed services were introduced by the update.

### Suggested Verification Commands

```bash
git --version
curl --version
wget --version
htop --version
tree --version
nano --version
unzip -v
jq --version
rsync --version
```

Additional system checks:

```bash
systemctl --failed
df -h
free -h
```

### Success Criteria

* Operating system package metadata is current.
* Available operating system and security updates have been applied.
* Any required reboot has completed successfully.
* SSH access works after the update and reboot.
* Essential host administration utilities are installed and verified.
* No unexpected failed system services are present.
* The operating system is ready to host the container runtime.
* Bootstrap Guide is updated.
* Session Log is updated.
* Changes are committed to Git.

### Status

**Complete**

---

## Session 3B – Container Platform

### Objective

Establish Docker as the standard application runtime for long-running services on `cycling-prod`.

Docker will provide a repeatable and isolated way to deploy services while keeping application dependencies separate from the host operating system.

### Activities

#### Confirm the Container Strategy

* Record why Docker is being used.
* Confirm which responsibilities remain on the host.
* Confirm which services are expected to run in containers.
* Decide how Docker configuration will be represented in `cycling-infrastructure`.

#### Install Docker

* Install Docker using an appropriate, supported installation method.
* Confirm that the Docker service starts automatically.
* Confirm that the Docker daemon is running.
* Add the `tim` user to the Docker group, if this remains the agreed approach.
* Log out and reconnect if required for group membership to take effect.

#### Install and Verify Docker Compose

* Install or confirm availability of the Docker Compose plugin.
* Verify use of the modern command:

```bash
docker compose
```

rather than the older standalone command:

```bash
docker-compose
```

#### Run a Test Container

* Pull a small test image.
* Start a test container.
* Confirm that it runs successfully.
* Inspect the container.
* Stop and remove it.
* Confirm that no unnecessary test resources remain.

#### Introduce Core Container Concepts

* Image
* Container
* Registry
* Port
* Network
* Bind mount
* Named volume
* Environment variable
* Compose project

### Suggested Verification Commands

```bash
docker --version
docker compose version
systemctl status docker
docker info
docker run --rm hello-world
```

### Success Criteria

* Docker is installed.
* Docker starts automatically with the server.
* Docker Compose is available through `docker compose`.
* The `tim` user can run the agreed Docker commands.
* A test container runs successfully.
* The distinction between images, containers and persistent storage is understood.
* No unnecessary test containers or resources remain.
* The environment is ready for application service deployment.
* Bootstrap Guide is updated.
* Session Log is updated.
* Changes are committed to Git.

### Status

**Not Started**

---

## Session 4 – Production Hardening

### Objective

Prepare the server for secure, reliable and maintainable long-term operation.

### Activities

* Review and harden the SSH configuration.
* Verify that SSH public key authentication works before disabling any fallback authentication.
* Configure Tailscale for secure remote access.
* Review firewall requirements.
* Configure automatic security updates.
* Define the standard production directory structure.
* Create deployment directories.
* Create persistent data locations.
* Create backup locations.
* Define ownership and permissions for operational directories.
* Establish initial logging and health-check conventions.
* Document recovery access and troubleshooting procedures.

### Success Criteria

* Remote access is secure and recoverable.
* Unnecessary authentication methods are disabled where appropriate.
* Tailscale access is working.
* Automatic security updates are configured.
* Production directories exist with appropriate ownership and permissions.
* Backup locations are established.
* Basic operational and recovery procedures are documented.
* Bootstrap Guide is updated.
* Changes are committed to Git.

### Status

**Not Started**

---

## Session 5 – Platform Deployment

### Objective

Deploy the Cycling Platform and migrate its production data and scheduled workloads to `cycling-prod`.

### Activities

* Decide and document the MariaDB deployment model.
* Deploy MariaDB.
* Configure persistent database storage.
* Configure database users, credentials and permissions.
* Restore the required databases.
* Validate schemas, tables, indexes and row counts.
* Clone the required Git repositories.
* Configure production environment variables and secrets.
* Install the required R runtime and project dependencies.
* Configure the Cycling Platform for the production database.
* Run the Raw, Silver and Gold workflows manually.
* Validate end-to-end processing.
* Configure scheduled retrieval and transformation jobs.
* Configure logging and failure handling.
* Confirm restart and reboot behaviour.
* Establish and test database backups.
* Complete a test restore before declaring the platform production-ready.

### Success Criteria

* MariaDB is running with persistent storage.
* Required databases and schemas are restored and validated.
* `cycling-platform` runs successfully in the production environment.
* Raw ingestion is operational.
* Silver transformations are operational.
* Gold transformations are operational.
* Scheduled jobs run without requiring an interactive shell.
* Logs and failures can be inspected.
* Database backup and restore have both been tested.
* Bootstrap Guide is updated.
* Operations Guide is updated.
* Changes are committed to Git.

### Status

**Not Started**

---

## Future Sessions

Once the core production platform is stable, additional capabilities can be introduced incrementally.

Potential future work includes:

* MCP server
* Cycling analytics deployment
* Monitoring and alerting
* Grafana
* Metrics collection
* Reverse proxy
* HTTPS
* Service health checks
* Automated deployments
* GitHub Actions
* Secrets management
* Infrastructure automation
* Ansible
* Local AI services
* NVMe storage migration
* Off-device backups
* Disaster recovery testing

Each future service must justify its operational cost and should not be introduced merely because it is available.

---

## Working Philosophy

For every session:

1. Understand the objective.
2. Discuss the architecture and intended outcome.
3. Observe the current state before making changes.
4. Implement deliberately.
5. Validate the result.
6. Document both the actions and the reasoning.
7. Commit the changes to Git.

The aim is not simply to build a Raspberry Pi server.

The aim is to create a production environment that is understandable, reproducible, maintainable and capable of evolving alongside the Cycling Platform for years to come.

---

## Environment Model

```text
Mac
└── DEV
    ├── code development
    ├── testing
    ├── documentation
    ├── Git commits
    └── controlled deployments

GitHub
└── source of truth
    ├── cycling-platform
    ├── cycling-analytics
    └── cycling-infrastructure

cycling-prod
└── PROD
    ├── database
    ├── scheduled ingestion
    ├── Silver transformations
    ├── Gold transformations
    ├── production services
    └── backups
```

The Raspberry Pi 5 is the current hardware host for `cycling-prod`. The server identity, infrastructure documentation and deployment model should remain valid if that hardware changes in the future.

## Standard Operating Procedure – Operating System Update

1. Refresh package metadata.
2. Review available updates.
3. Apply updates.
4. Reboot.
5. Reconnect via SSH.
6. Verify kernel version.
7. Verify uptime.
8. Verify no failed services.
9. Remove obsolete packages.
10. Commit documentation.