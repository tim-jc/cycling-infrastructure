# Session Log

## Session 1 – SD Card Preparation

### Summary

The Raspberry Pi production environment was provisioned before first boot.

### Key Decisions

* Raspberry Pi OS Lite (64-bit)
* Headless operation
* Public key SSH authentication
* Hostname: `cycling-prod`
* Username: `tim`
* Mac designated as **DEV**
* Raspberry Pi designated as **PROD**
* Raspberry Pi Connect disabled

### Lessons Learned

* Modern Raspberry Pi Imager can provision users, networking and SSH keys before the first boot.
* Public key authentication provides a cleaner long-term administration model than password authentication.

---

## Session 2 – First Boot

### Summary

Successfully established the first secure connection to `cycling-prod`.

### Completed

* Booted the Raspberry Pi.
* Connected over Wi-Fi.
* Logged in via SSH using public key authentication.
* Verified the machine identity and user account.
* Began exploring the Linux filesystem.

### Current Focus

Complete the system baseline by recording:

* Operating system
* Kernel
* Memory
* Storage
* CPU
* Temperature

### Next Session

Complete the remaining Session 2 validation checks, record the baseline configuration, and commit the updated documentation to Git before moving on to Session 3 (Core Bootstrap).
