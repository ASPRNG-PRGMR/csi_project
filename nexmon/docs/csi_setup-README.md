# Raspberry Pi 4B Nexmon CSI — `csi_setup.sh` Guide & Troubleshooting

Supersedes the manual step-by-step runbook for day-to-day use. The manual
steps still apply conceptually; `csi_setup.sh` automates and hardens them based
on failures actually hit while getting this working.

**Does not automate:** the one-time Nexmon build/install (ARMHF libraries,
Python 2.7, firmware build, `nexutil`, `makecsiparams`). That's separate
provisioning, covered by the devlog. This script is only the repeatable
every-boot procedure.

---

## 0. Current Known-Good State

**Hardware**
- Raspberry Pi 4B
- BCM43455C0 Wi-Fi chip
- Nexmon-patched firmware version: `7.45.189`
- Architecture: `aarch64`
- OS: Raspberry Pi OS Trixie / Debian 13

**Management link:** administered over **USB Ethernet** (`usb0`) so `wlan0`
can be fully handed to Nexmon without losing SSH access. This matters
regardless of which laptop/host you're SSHing in from — the fragile state
lives on the Pi, not the client.

**File locations on the Pi:**
```
/home/pios/nexmon
/home/pios/nexmon/patches/bcm43455c0/7_45_189/nexmon_csi
/lib/firmware/nexmon/brcmfmac43455-sdio.bin   ← Nexmon-patched firmware
```

---

## 1. Commands

```bash
./csi_setup.sh start      Full startup: verify env → select firmware → reload
                         driver → verify firmware version → set CSI channel
                         params → enable monitor mode → confirm usb0 →
                         unmanage wlan0
./csi_setup.sh capture    tcpdump on udp port 5500 (wlan0 by default,
                         auto-brings the interface up if needed)
./csi_setup.sh status     Read-only snapshot: usb0, wlan0, rfkill, nexutil
                         chanspec/monitor state, NetworkManager state.
                         Makes no changes.
./csi_setup.sh restore    Return wlan0 to normal NetworkManager-managed Wi-Fi
```

`capture` also accepts `ANY=1 ./csi_setup.sh capture` to listen on `any`
instead of `wlan0`, useful if the CSI UDP export target isn't the Pi itself
(see §5 below).

---

## 2. Normal Session

```bash
ssh pios@raspberry.local            # over usb0, never over wlan0
./csi_setup.sh start
# → prompted for transmitter's actual channel (check AP/hotspot, don't
#   assume — e.g. 2412 MHz is channel 1, not channel 6)
# → optionally prompted for transmitter MAC
# start your transmitter (ESP32 or phone hotspot) on that channel
./csi_setup.sh capture
```

When done:
```bash
./csi_setup.sh restore
```

---

## 3. Failures Hit While Getting This Working (and the fixes now built in)

### 3a. `nexutil -s500` hangs indefinitely, no error

**Symptom:** script (or manual command) sits forever after "Applying CSI
configuration..." with no output.

**Cause found:** the loaded firmware was **not** the Nexmon build.
`update-alternatives --auto cyfmac43455-sdio.bin` was selecting the stock
Cypress firmware (`cyfmac43455-sdio-standard.bin`, priority 50) over the
Nexmon build (priority 30) — `--auto` always prefers higher priority, so it
silently picked the wrong one every time. `nexutil`'s custom CSI ioctls mean
nothing to stock firmware, so the call just blocks forever waiting for a
response that firmware will never send.

**Fix in script:** `select_firmware()` now uses
`update-alternatives --set cyfmac43455-sdio.bin /lib/firmware/nexmon/brcmfmac43455-sdio.bin`
explicitly — never `--auto`. `verify_loaded_firmware()` then checks the
actual firmware version string that got loaded, from a freshly cleared
`dmesg` buffer, and hard-fails immediately with a clear message if it isn't
`7.45.189`, instead of letting you walk into a silent hang three steps later.

**Manual check/fix if you ever see this again:**
```bash
update-alternatives --display cyfmac43455-sdio.bin   # check "currently points to"
sudo update-alternatives --set cyfmac43455-sdio.bin /lib/firmware/nexmon/brcmfmac43455-sdio.bin
sudo reboot
dmesg -T | grep "Firmware: BCM4345"    # must say 7.45.189
```

### 3b. Same hang recurs even after pinning the alternative

**Symptom:** firmware version checks out fine at `start`, but later —
specifically when `nexutil -m1` (enabling monitor mode) triggers an
`mmc1: card removed` / `new SDIO card` bus reset — `dmesg` shows the
firmware reloaded back to `7.45.265` (stock).

**Cause found:** `modprobe -r brcmfmac_wcc` / `modprobe brcmfmac_wcc` alone
doesn't reliably force the SDIO card to re-fetch firmware — no actual bus
power-cycle happens on module reload. So a firmware-version check right
after `modprobe` can match a **stale line already sitting in the dmesg ring
buffer** from an earlier boot, giving a false pass. The real firmware in use
only gets re-pulled when something (like `nexutil -m1`) actually resets the
SDIO bus — and if the alternative had drifted back to stock in the
meantime, that's when it bites.

**Fix in script:** `reload_driver()` now runs `sudo dmesg -C` (clear the
ring buffer) immediately before the `modprobe` cycle, so `verify_loaded_firmware()`
can only match genuinely fresh output — no more false positives from old
boot logs.

**Manual check if suspected:**
```bash
sudo dmesg -C
sudo modprobe -r brcmfmac_wcc; sleep 1; sudo modprobe brcmfmac_wcc; sleep 2
dmesg -T | grep "Firmware: BCM4345"
```
If nothing appears at all, the module reload didn't trigger a real firmware
fetch — reboot instead of relying on modprobe.

### 3c. `make -f Makefile.rpi unmanage` fails: `Error 6`, "not all devices disconnected"

**Symptom:**
```
NetworkManager DISCONNECT wlan0
Error: Device 'wlan0' ... disconnecting failed: This device is not active
Error: not all devices disconnected.
make: *** [Makefile.rpi:209: unmanage] Error 6
```

**Cause found:** the `unmanage` target's first step is
`nmcli device disconnect wlan0`. Since `wlan0` was never associated to an AP
(expected — it's used for CSI reception, not networking), NetworkManager has
nothing to disconnect and errors out, which aborts `make` before it reaches
the actual `nmcli device set wlan0 managed no` step. Benign but blocking.

**Fix in script:** `cmd_start()` captures the `make` output; if it matches
this known-benign pattern (`not all devices disconnected` / `is not
active`), it falls back to running `nmcli device set wlan0 managed no`
directly and verifies the result, instead of treating it as fatal.

**Manual fix if seen outside the script:**
```bash
sudo nmcli device set wlan0 managed no
nmcli dev status | grep wlan0    # confirm "unmanaged"
```

### 3d. `tcpdump: wlan0: That device is not up` after a successful `start`

**Cause found:** the `unmanage` fallback (3c) sets the device unmanaged but
NetworkManager can leave the link administratively down afterward — `make
unmanage`'s normal path apparently also brings it up, which the fallback
path didn't originally replicate.

**Fix in script:** both the `unmanage` fallback and `capture` now check
`ip link show wlan0` for `state UP` and run `sudo ip link set wlan0 up` if
needed before proceeding.

### 3e. `RTNETLINK answers: Operation not possible due to RF-kill`

**Symptom:** `sudo ip link set wlan0 up` itself fails with an RF-kill error,
and `tcpdump` then also fails since the interface never came up.

**Cause found:** the radio ends up soft-blocked, most likely as a side
effect of NetworkManager relinquishing control of an interface it no longer
manages.

**Fix in script:** added `ensure_radio_unblocked()`
(`rfkill unblock wifi` + `rfkill unblock all`), called defensively —
**every time**, whether or not anything looks blocked — right before any
`ip link set wlan0 up`: in the `unmanage` fallback, in `capture`'s auto-up
path, before attempting `unmanage` itself, and in `restore`'s manual
fallback. `status` also now prints `rfkill list` output directly so you can
see blocked/unblocked state at a glance without hunting for it.

**Manual fix if seen:**
```bash
rfkill list
sudo rfkill unblock wifi
sudo rfkill unblock all      # if a hardware-block entry also shows blocked
sudo ip link set wlan0 up
```

---

## 4. Debugging Order of Operations

Unchanged from the original runbook — still the right order to walk through
before assuming something is fundamentally broken:

```
1. Transmitter is actually sending frames        (confirm on ESP/phone side)
2. Pi is on the same RF channel                  (nexutil -Iwlan0 -k)
3. Pi's wlan0 is unmanaged / under Nexmon         (ip link show wlan0)
4. Nexmon monitor/CSI mode is enabled             (nexutil -Iwlan0 -m)
5. CSI UDP destination is known                   (inspect makecsiparams/nexutil config)
6. tcpdump on the correct host shows packets      (Pi and/or wherever the
                                                    UDP export target is)
```

Run `./csi_setup.sh status` at any point to get a snapshot of steps 2–4 (plus
rfkill and NetworkManager state) without changing anything.

### Quick troubleshooting table (updated)

| Symptom | Likely cause | Fix |
|---|---|---|
| `nexutil -s...` hangs forever, no error | Stock firmware loaded instead of Nexmon (§3a) | Pin the alternative explicitly, reboot, re-check `dmesg` |
| Firmware reverts to stock mid-session, especially around `-m1` | `modprobe` reload doesn't force a real SDIO refetch (§3b) | `dmesg -C` before reload; verify against fresh output only |
| `make unmanage` → `Error 6` / "not all devices disconnected" | `nmcli disconnect` fails on a never-associated interface (§3c) | `nmcli device set wlan0 managed no` directly |
| `tcpdump: wlan0: That device is not up` | Interface left down after unmanage fallback (§3d) | `sudo ip link set wlan0 up` |
| `RTNETLINK ... RF-kill` | Radio soft-blocked (§3e) | `sudo rfkill unblock wifi` (and `all`) before bringing link up |
| `tcpdump` shows nothing anywhere | Transmitter not actually sending | Confirm ESP/phone is powered/sending |
| `tcpdump` shows nothing anywhere | Channel mismatch | `nexutil -Iwlan0 -k` vs transmitter's actual channel |
| Packets on Pi but not elsewhere | CSI UDP export target isn't the Pi | Re-check export target IP; capture directly on that host, or use a forwarder |
| SSH drops after `unmanage` | Was using Wi-Fi SSH instead of `usb0` | Always use `usb0` for management |

---

## 5. First Milestone

```
Transmitter → Wi-Fi transmission → Pi BCM43455 → Nexmon → UDP :5500 →
tcpdump on receiving host → PACKETS VISIBLE
```

Don't start writing CSI parsing/ML code before this is hit. Once packets are
visible in `tcpdump`, save a few lines of output as evidence — the pipeline
is proven end-to-end.

**Don't assume the Pi is the final UDP destination** — Nexmon CSI export is
configured to a specific destination IP:port. If it's not the Pi, capture on
whichever host it actually targets, or forward the Pi-local stream onward.

---

## 6. Starting a Fresh Debugging Session

When opening a new chat/session to continue this work, attach this README
and `csi_setup.sh`, and say:

> "This is my current Nexmon CSI state and automation script. Walk me
> through startup and first successful CSI packet capture using
> `csi_setup.sh`. Known fixed issues are documented in §3 — don't re-diagnose
> those from scratch, but do treat any new symptom as new. Don't assume the
> UDP destination/port, transmitter channel, or transmitter MAC — inspect
> what `makecsiparams` and `nexutil -Iwlan0 -k` actually configure and what
> the transmitter is actually using."
