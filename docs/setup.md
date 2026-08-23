# CSI Project — Setup / Reproduction Guide

> High-level reproduction guide. For the fully verified Raspberry Pi Nexmon
> setup steps, see `nexmon/setup/rpi-csi-devlog.md`. For day-to-day
> start/capture/status/restore commands, see
> `nexmon/scripts/csi_setup-README.md`. Only document steps here that have
> actually been verified — mark anything else as **Unverified / Under
> Investigation**.

## Hardware Required

- Raspberry Pi 4B (BCM43455C0 Wi-Fi chip)
- ESP32 (CSI transmitter)
-

## ESP32 Setup

### ESP32 Firmware / ESP-IDF Setup

**Unverified / Under Investigation**

## Raspberry Pi Setup

Verified — Raspberry Pi OS Trixie (Debian 13, aarch64). Full steps in
`nexmon/setup/rpi-csi-devlog.md`. Do **not** attempt this on Ubuntu 24.04 —
that path is documented there as a confirmed dead end for this
firmware/toolchain combination.

## Nexmon Setup

Verified — Nexmon build, firmware `7.45.189`, `nexutil`, `makecsiparams`.
Full steps in `nexmon/setup/rpi-csi-devlog.md`.

## Configuration Required

### Channel Configuration

Must match the actual channel the transmitter (ESP32) is using — never
assume a default. See "CSI Configuration" in `nexmon/setup/rpi-csi-devlog.md`.

### MAC Configuration

**Unverified / Under Investigation**

## Running the Nexmon Automation Script

See `nexmon/scripts/csi_setup-README.md` — `./csi_setup.sh start` /
`capture` / `status` / `restore`.

## Starting CSI Capture

`./csi_setup.sh capture` — tcpdump on UDP port 5500 (`wlan0`, falls back to
`any`).

## Where Captured Data Appears

Verified — CSI packets flow over UDP :5500. Do not assume the Raspberry Pi
is the final UDP destination without checking; confirm the actual export
target via `makecsiparams` / `nexutil -Iwlan0 -k`.

## How to Verify Capture Succeeded

`sudo tcpdump -i wlan0 dst port 5500` shows packets. If nothing appears,
follow the debugging order of operations in
`nexmon/scripts/csi_setup-README.md` §4.

## Known Issues

See `nexmon/scripts/csi_setup-README.md` §3 for the full list of failures
hit so far and the fixes already built into `csi_setup.sh` (firmware
auto-selection bug, stale dmesg false positives, `unmanage` disconnect
error, rfkill).

## Troubleshooting

See `nexmon/scripts/csi_setup-README.md` §3–4.
