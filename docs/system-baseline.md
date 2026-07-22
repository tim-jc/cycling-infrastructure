# System Baseline

| Item              | Value                         |
| ----------------- | ----------------------------- |
| Host              | `cycling-prod`                |
| Environment       | Production                    |
| Baseline Date     | 2026-07-10                    |
| Bootstrap Session | Session 2 – First Boot        |
| Status            | Initial Provisioning Complete |

This document records the initial state of `cycling-prod` before any additional software beyond the base Raspberry Pi OS installation has been installed.

---

## Hardware

| Item        | Value                     |
| ----------- | ------------------------- |
| Platform    | Raspberry Pi 5            |
| Memory      | 16 GB                     |
| Boot Device | 128 GB SanDisk A2 microSD |

---

## Operating System

| Item              | Value                          |
| ----------------- | ------------------------------ |
| Distribution      | Raspberry Pi OS Lite (64-bit)  |
| Base Distribution | Debian GNU/Linux 13.5 (Trixie) |

---

## Kernel

| Item           | Value                  |
| -------------- | ---------------------- |
| Kernel Version | `6.18.34+rpt-rpi-2712` |

---

## CPU

| Item           | Value          |
| -------------- | -------------- |
| Architecture   | ARM64          |
| Processor      | ARM Cortex-A76 |
| Physical Cores | 4              |

---

## Memory

| Item                       | Value                |
| -------------------------- | -------------------- |
| Installed RAM              | 16 GB                |
| Available After First Boot | Approximately 15 GiB |

---

## Storage

| Item            | Value                                 |
| --------------- | ------------------------------------- |
| Boot Device     | 128 GB SanDisk A2 microSD             |
| Root Filesystem | Approximately 111 GB available on `/` |

---

## Temperature

Recorded immediately after first boot and initial login.

| Item            | Value   |
| --------------- | ------- |
| CPU Temperature | 47.7 °C |

---

## Network

| Item              | Value                                                   |
| ----------------- | ------------------------------------------------------- |
| Hostname          | `cycling-prod`                                          |
| Primary Interface | `wlan0`                                                 |
| Connection Type   | Wi-Fi                                                   |
| Ethernet          | Available but not connected during initial provisioning |

---

## Firmware

Not recorded as part of the initial baseline.

---

## Asset Information

| Item          | Value              |
| ------------- | ------------------ |
| Serial Number | `5e9fe1568951c95e` |

---

## Notes

Initial provisioning completed successfully.

* Headless installation completed using Raspberry Pi Imager.
* SSH public key authentication configured before first boot.
* Remote administration established successfully.
* Wi-Fi connectivity verified.
* Initial Linux filesystem exploration completed.
* No additional software installed beyond the base Raspberry Pi OS image.
* Baseline captured prior to Session 3A (Operating System Bootstrap).

---

## Purpose

This document represents the **initial known-good state** of `cycling-prod`.

It should remain a historical record of the server immediately after provisioning. Subsequent infrastructure changes should be recorded in the project changelog and session log rather than by modifying this baseline.
