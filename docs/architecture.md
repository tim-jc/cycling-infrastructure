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


production root: /srv/cycling;
directory purposes;
/srv/cycling
├── backups
├── compose
├── config
├── data
└── logs
ownership: tim:tim initially;
bootstrap script is safe to rerun.