# Bootstrap Guide

## Session 1 – Prepare the SD Card

### Objective

Create a bootable, production-ready Raspberry Pi OS image.

### Completed

* Installed **Raspberry Pi OS Lite (64-bit)** using Raspberry Pi Imager.
* Configured hostname: `cycling-prod`
* Created administrator account: `tim`
* Configured Wi-Fi.
* Configured locale and timezone.
* Enabled SSH.
* Generated an Ed25519 SSH key pair on the Mac.
* Configured public key authentication using the generated public key.
* Chose not to enable Raspberry Pi Connect.
* Successfully wrote the operating system image to the SD card.

### Outcome

The Raspberry Pi was fully provisioned before first boot and configured for secure, headless administration.

---

# Session 2 – First Boot

## Objective

Successfully boot the Raspberry Pi and establish remote administration.

### Completed

* Raspberry Pi booted successfully.
* Connected to the local Wi-Fi network.
* Successfully connected via SSH using public key authentication.
* Verified hostname (`cycling-prod`).
* Verified current user (`tim`).
* Verified home directory (`/home/tim`).
* Began initial exploration of the Linux filesystem.

### Remaining Tasks

* Verify operating system version.
* Verify kernel version.
* Verify available memory.
* Verify available storage.
* Record CPU information.
* Record system temperature.
* Record system information in the project documentation.

### Session 2 Status

**In Progress**

The Raspberry Pi has successfully completed first boot and secure remote administration has been established. Remaining activities are focused on recording system health and documenting the baseline configuration.

---

# Session 3 – Core Bootstrap

## Goal

Install the core software required for all future services.

## Activities

* Update operating system
* Install Git
* Install Docker
* Install Docker Compose
* Install essential Linux utilities
* Verify installations

## Success Criteria

* Core tooling installed.
* Environment ready for application deployment.
* Bootstrap Guide updated.
* Changes committed to Git.

---

# Session 4 – Production Hardening

## Goal

Prepare the server for long-term operation.

## Activities

* Harden SSH configuration
* Configure Tailscale
* Configure automatic updates
* Create deployment directories
* Create backup locations
* Create standard directory structure

## Success Criteria

* Secure production environment established.
* Backup strategy in place.
* Bootstrap Guide updated.
* Changes committed to Git.

---

# Session 5 – Platform Deployment

## Goal

Deploy the Cycling Platform.

## Activities

* Install MariaDB
* Restore databases
* Validate schemas
* Clone repositories
* Configure environment
* Configure scheduled ETL
* Validate end-to-end operation

## Success Criteria

* Cycling Platform running successfully.
* ETL operational.
* Database validated.
* Bootstrap Guide updated.
* Changes committed to Git.

---

# Future Sessions

Once the production platform is stable, additional services can be introduced incrementally.

Potential future work includes:

* MCP Server
* Grafana
* Monitoring
* Reverse proxy
* HTTPS
* Local AI services
* Automated deployment
* Infrastructure automation

---

# Working Philosophy

For every session:

1. Understand the objective.
2. Discuss the architecture.
3. Implement deliberately.
4. Validate the result.
5. Document what was done.
6. Commit the changes to Git.

The aim is not simply to build a Raspberry Pi server.

The aim is to create a production environment that is understandable, reproducible, maintainable and capable of evolving alongside the Cycling Platform for years to come.
