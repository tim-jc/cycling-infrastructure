Home network
│
├── Mac DEV
│
└── cycling-prod
    │
    ├── Raspberry Pi OS
    ├── Docker Engine
    │
    └── Compose project
    │       │
    │       ├── private Docker network
    │       │      ├── MariaDB
    │       │      └── cycling-platform job
    │       │
    │       └── persistent storage
    │              ├── MariaDB data
    │              ├── backups
    │              └── logs
    │
    └── systemd
           └── schedules platform runs
