# CSI Project

## What this project is trying to accomplish
TODO: one or two sentences on the end goal.

## Current phase
CSI acquisition and validation. Nexmon CSI on the Raspberry Pi 4B is confirmed
working end-to-end (CSI packets flowing over UDP :5500), and startup is now a
single automated script (`csi_setup.sh`) apart from channel/MAC input.
ESP32-side representation (tabular format), the dual-ESP32 repo, and a
CSI parsing/visualization script are actively being worked on.

## Current objective
See `docs/tasks.md` for who's doing what right now, and `docs/roadmap.md`
for the detailed technical breakdown of what comes after acquisition.

## High-level pipeline
ESP32 / RPi Nexmon CSI acquisition -> Parsing & representation -> Visualization
-> Disruption metric -> Localization (weighted centroid / fingerprinting / AoA
fusion) -> (later) classical signal processing & ML

## Repository structure

```
csi_project/
│
├── README.md
│
├── docs/
│   ├── project_plan.md      Objective, phases, team tasks, timeline, blockers
│   ├── setup.md              High-level reproduction guide
│   ├── roadmap.md            Detailed technical roadmap + file index
│   └── tasks.md               Current, day-to-day task assignments
│
├── nexmon/
│   ├── scripts/
│   │   └── csi_setup.sh              Start/capture/status/restore automation
│   └── docs/
│       ├── rpi-csi-devlog.md         One-time provisioning devlog (verified)
│       └── csi_setup-README.md       csi_setup.sh command reference + troubleshooting
│
├── csi/
│   ├── acquisition/          Code that pulls CSI from the Nexmon/ESP32 setup
│   ├── parsing/               Rishabh's parser/visualization work
│   │   ├── csi_extraction.md
│   │   ├── csi_visualize.py
│   │   └── localize.py
│   └── visualization/        Dashboard/plots (Shaily)
│
├── experiments/               Things being investigated, not yet established
│
├── working/
│   └── latest/                Latest known-working operational setup
│
├── data/
│   └── README                 Where CSI datasets/captures conceptually live
│
└── .gitignore
```

## Running CSI capture

`csi_setup.sh` (in `nexmon/scripts/`) automates the every-boot Nexmon CSI
startup sequence and data collection:

```
# Usage:
#   ./csi_setup.sh start      Run the full startup sequence up through `unmanage`
#   ./csi_setup.sh capture    tcpdump on udp port 5500 (wlan0, fallback to any)
#   ./csi_setup.sh status     Print current CSI/wlan0/usb0 state, no changes made
#   ./csi_setup.sh restore    Restore normal Wi-Fi (Makefile.rpi restore-wifi)
```

Channel and transmitter MAC are the only manual inputs — everything else is
automated. See `nexmon/docs/csi_setup-README.md` for the full command
reference and troubleshooting, and `nexmon/docs/rpi-csi-devlog.md` for the
one-time provisioning steps (firmware build, Python 2.7, ARMHF compat, etc).

## Backups

A full pre-existing Nexmon backup (config, hidden files, build artifacts —
too large and permission-sensitive for a normal commit) is kept as a GitHub
Release asset rather than in the repo tree or Git LFS. See the repo's
Releases page; not part of this directory structure.

## Where to look for what

| Question | Doc |
|---|---|
| What's the overall plan / phases / deliverables? | `docs/project_plan.md` |
| How do I set this up from scratch? | `docs/setup.md` → `nexmon/docs/rpi-csi-devlog.md` |
| How do I run capture day-to-day? | `nexmon/docs/csi_setup-README.md` |
| What's the deeper technical roadmap after acquisition? | `docs/roadmap.md` |
| Who's doing what right now? | `docs/tasks.md` |

## Current status
- Nexmon CSI acquisition path verified on RPi 4B (Raspberry Pi OS Trixie).
- `csi_setup.sh` automates start/capture/status/restore.
- ESP32 tabular representation, dual-ESP32 repo bring-up, and CSI
  parsing/visualization are actively in progress — see `docs/tasks.md`.
- `docs/project_plan.md` (objective, timeline, blockers) is still a
  skeleton — needs filling in before this is push-ready.
