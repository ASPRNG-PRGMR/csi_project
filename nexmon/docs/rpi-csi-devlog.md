# Nexmon CSI on Raspberry Pi 4B — Setup Guide & Devlog

**Target hardware:** Raspberry Pi 4B, BCM43455C0, firmware `7.45.189`

---

## ⚠️ Do Not Attempt This on Ubuntu 24.04 — Read This First

An earlier attempt was made on **Ubuntu 24.04 LTS (kernel 6.8, aarch64)**. It's documented here only as a warning, **not** as a path to keep debugging.

**What happened:**

- Nexmon's bundled toolchain is an ancient 32-bit **ARMHF** GCC (`gcc-arm-none-eabi-5_4-2016q2`), which doesn't match Ubuntu's ARM64 userspace.
- Getting the compiler to run required manually rebuilding `libisl.so.10` and `libmpfr.so.4` for ARMHF from source, plus fighting ancient Autotools and incorrect GMP header paths.
- The Python 2-only `b43-beautifier` script needed manual porting to Python 3, since Ubuntu 24.04 ships no Python 2 in its repos.
- The UCODE assembler failed on `COND_RX_IFS2` — traced to a missing preprocessing step (`cond.inc` wasn't being included). Fixable, but not the real problem.
- **The real, unfixable-on-this-path problem:** the Nexmon CSI patch expects **symbolic** UCODE (`SHM_CHAN`, `SPR_TSF_0x3e`, etc.), but the UCODE produced by disassembly/beautification on this Ubuntu setup came out **raw/numeric** (`[0x50]`, `spr11f`, etc. instead). Patch context never matches as a result, so **11 of 39 patch hunks fail silently** (the Makefile runs `patch -p1 ... || true`), and `enable_carrier_search` / `disable_carrier_search` — defined only inside the failed hunks — end up missing, which breaks final assembly.
- Confirmed with a manual `patch --verbose` run outside the Makefile: identical hunk failures. This is not a tooling bug — it's a structural mismatch between the toolchain's UCODE output and what the CSI patch expects.

**Conclusion:** dead end on Ubuntu 24.04 for this firmware/toolchain combination. Do not re-attempt the ARMHF compiler rebuild, the ISL/MPFR rebuilds, or symbolic-vs-raw UCODE patch reconciliation on Ubuntu — go straight to Raspberry Pi OS Trixie below.

---

## ✅ Working Path: Raspberry Pi OS Trixie (Debian 13, aarch64)

### 1. Fresh OS

Flash and boot **Raspberry Pi OS Trixie** (Debian 13.6, aarch64) — clean install.

### 2. Enable ARMHF Compatibility

```bash
sudo dpkg --add-architecture armhf
sudo apt update

sudo apt install -y \
    libc6:armhf \
    libisl23:armhf \
    libmpfr6:armhf \
    libmpc3:armhf \
    libstdc++6:armhf
```

```bash
sudo ln -sf \
    /usr/lib/arm-linux-gnueabihf/libisl.so.23 \
    /usr/lib/arm-linux-gnueabihf/libisl.so.10

sudo ln -sf \
    /usr/lib/arm-linux-gnueabihf/libmpfr.so.6 \
    /usr/lib/arm-linux-gnueabihf/libmpfr.so.4
```

### 3. Install Python 2.7

Temporarily add the Debian Stretch archive, install `python2.7`, then restore the normal Pi OS sources.

```bash
/usr/bin/env python2.7 --version
# Python 2.7.13
```

**⚠️ Shebang gotcha** — don't blindly append `2.7` to an existing shebang line:

```bash
# WRONG if the shebang is already "#!/usr/bin/env python2.7":
sed -i '1 s/$/2.7/' ~/nexmon/buildtools/b43-v3/debug/b43-beautifier
# → becomes "#!/usr/bin/env python2.72.7"
# → env: 'python2.72.7': No such file or directory
```

Correct fix — replace the whole line instead of appending to it:

```bash
sed -i '1c#!/usr/bin/env python2.7' \
    ~/nexmon/buildtools/b43-v3/debug/b43-beautifier

head -n 1 ~/nexmon/buildtools/b43-v3/debug/b43-beautifier
# #!/usr/bin/env python2.7
```

### 4. Build and Install the Nexmon-Patched Firmware

```bash
rm -f gen/ucode.asm
make -f Makefile.rpi install-firmware
```

Expected tail of output:

```
COMPILING src/version.c
DISASSEMBLING UCODE
...
PREPARING gen/nexmon.pre => gen/nexmon2.pre
GENERATING LINKER FILE
LINKING OBJECTS
GENERATING MAKE FILE
APPLYING FLASHPATCHES
APPLYING PATCHES
COPYING brcmfmac43455-sdio.bin
SETTING FIRMWARE ALTERNATIVE
```

### 5. Build nexutil

```bash
cd ~/nexmon/utilities/nexutil
sudo -E make install USE_VENDOR_CMD=1
sudo setcap cap_net_admin+ep /usr/bin/nexutil
```

### 6. Build the CSI Param Utility

```bash
cd ~/nexmon/patches/bcm43455c0/7_45_189/nexmon_csi/utils/makecsiparams
make
./makecsiparams -h
```

---

## Networking: USB Ethernet Gadget Mode, Not Wi-Fi, for SSH

`make -f Makefile.rpi unmanage` takes `wlan0` away from NetworkManager. **If SSH is running over `wlan0` when you do this, you will lock yourself out.**

Use USB Ethernet gadget mode instead:

```bash
ssh pios@raspberry.local
```

With SSH isolated on `usb0`, it's safe to run:

```bash
make -f Makefile.rpi unmanage
```

**Recovery** (`restore-wifi` target, or manually):

```bash
update-alternatives --auto cyfmac43455-sdio.bin
modprobe -r brcmfmac_wcc
modprobe brcmfmac_wcc
ifconfig wlan0 up
rfkill unblock wifi
nmcli dev set wlan0 managed yes
nmcli radio wifi on
nmcli dev connect wlan0
```

---

## CSI Configuration

The CSI config must match the **actual channel the target (ESP) transmits on** — not an assumed or default one.

Example — if `nexutil -k` reports `chanspec: 0x100b, 11`, that's channel 11 (not 36):

```bash
./makecsiparams -c 11/20 -C 1 -N 1
```

```bash
nexutil -s500 -b -l34 -v<STRING>
nexutil -k
```

### Monitor Mode Note

Don't try to force a standard Linux `mon0` interface:

```bash
sudo iw phy "$(iw dev wlan0 info | gawk '/wiphy/ {printf "phy" $2}')" \
    interface add mon0 type monitor
# command failed: Operation not supported (-95)   ← expected, not a bug
```

Use Nexmon's own control interface instead:

```bash
nexutil -m1
nexutil -m
```

### Capturing CSI Packets

```bash
sudo tcpdump -i wlan0 dst port 5500
```

If no packets appear, check in this order:

1. BCM43455 channel (`nexutil -k`)
2. CSI config matches the target's actual channel
3. Monitor state (`nexutil -m`)
4. Whether the ESP is actually transmitting
5. Whether the frames it sends match the CSI filters

---

## Final Architecture

```
ESP (Wi-Fi transmitter)
        │ 802.11 frames
        ▼
BCM43455C0 (Raspberry Pi 4B)
        │ Nexmon CSI
        ▼
UDP :5500
        │
        ▼
Pi usb0 ── USB ── Fedora (CSI processing)
```

---

## Status Checklist

| Component | Status |
|---|---|
| Pi 4B / Pi OS Trixie | ✅ |
| BCM43455C0 firmware 7.45.189 | ✅ |
| Nexmon build | ✅ |
| Nexmon CSI firmware | ✅ |
| Python 2.7 | ✅ |
| nexutil | ✅ |
| makecsiparams | ✅ |
| USB Ethernet / SSH isolation | ✅ |
| ESP producing CSI on UDP :5500 | ⏳ remaining |

---

## Lessons Learned

- ❌ Don't repeat the Ubuntu ARMHF rebuild rabbit hole — Trixie solves it with `dpkg --add-architecture armhf` plus the two symlinks above.
- ❌ Don't blindly `sed`-append `2.7` to the beautifier shebang — replace the whole line.
- ❌ Don't SSH over `wlan0` while running `unmanage` — use `usb0`.
- ❌ Don't assume zero UDP packets means broken firmware — check channel alignment first.
- ❌ Don't fight for a Linux `mon0` interface — use `nexutil -m` instead.
