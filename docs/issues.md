# Known Issues — Nexmon CSI pipeline

Findings from a static review (2026-11-07) of `nexmon/scripts/csi_setup.sh` and
the parsing scripts, walking the chain from install → start → capture →
parsing. Nothing here was reproduced on the Pi — it is all from reading the
code plus the snapshot copy, so each item lists the evidence to re-check
against.

Status legend: ⬜ open · 🟨 in progress · ✅ fixed · ⬛ won't fix

---

## Blockers — the chain does not complete as written

### ⬜ B1. `start` dies at the install gap

**Where:** `nexmon/scripts/csi_setup.sh:110,116,123` and `:176,180,273,286`

Restoring the release snapshot populates `~/nexmon`, but `csi_setup.sh` depends
on three **system**-side artifacts that a home-directory restore never creates:

| Script needs | Line | State after snapshot restore |
|---|---|---|
| `/lib/firmware/nexmon/brcmfmac43455-sdio.bin` | 110, 116 | absent |
| `update-alternatives` entry for `cyfmac43455-sdio.bin` → that path | 123 | not registered |
| `nexutil` on `PATH` | 176, 180, 273, 286 | absent |

`start` runs `check_pi_arch` → `check_usb0` → `check_nexmon_dir` →
`source_env` → `select_firmware`, and dies at line 117:
`Nexmon firmware not found at /lib/firmware/nexmon/brcmfmac43455-sdio.bin`.

**Fix:** nothing needs compiling — the snapshot already contains built
`nexutil`, `makecsiparams` and the patched `brcmfmac43455-sdio.bin` for
`7_45_189`. They just need installing:

- `make -f Makefile.rpi install-firmware` (from `$CSI_DIR`), which also
  registers the alternative
- `nexutil` → `/usr/bin` with `sudo setcap cap_net_admin+ep /usr/bin/nexutil`

Worth considering: have `csi_setup.sh` gain an `install` subcommand so this
stops being an undocumented manual prerequisite.

### ⬜ B2. `capture` never writes a pcap, so parsing has no input

**Where:** `nexmon/scripts/csi_setup.sh:369`

```bash
sudo tcpdump -ni "$target_iface" udp port "$UDP_PORT"
```

No `-w`. `capture` is a live viewer only. But `csi/parsing/csi_visualize.py`
takes a pcap path as a **required** argument, and `csi/parsing/csi_extraction.md`
§1 instructs a different, manual command
(`sudo tcpdump -i wlan0 udp port 5500 -w csi_capture.pcap`).

So anyone following the README's `./csi_setup.sh capture` ends up with nothing
to feed the parser. This is the break between "CSI is flowing" and "we have
data".

**Fix:** add an optional output path, e.g. `./csi_setup.sh capture out.pcap`
→ `tcpdump -w out.pcap`, keeping the no-argument form as the live view.
**Decision needed:** this changes what `capture` does for everyone already
using it, so agree the behaviour before changing it.

---

## Real bugs

### ⬜ R1. The monitor-mode verification is dead code

**Where:** `nexmon/scripts/csi_setup.sh:289-292`

`mon_state` captures the `info` header `"Current monitor/CSI mode:"`, and the
guard is `grep -qE "1|on|enabled"`. The word **m-ON-itor** contains `on`, so
the pattern always matches and the warning is unreachable. Monitor mode could
be flatly off and `start` would report nothing.

**Evidence:**
```
$ echo "Current monitor/CSI mode:" | grep -qE "1|on|enabled" && echo MATCHES
MATCHES
```

**Fix:** match on the value only, not the captured header — parse the
`nexutil -m` output field and compare it to `1` exactly.

### ⬜ R2. `restore` silently fails to unpin the firmware

**Where:** `nexmon/scripts/csi_setup.sh:392`

```bash
update-alternatives --auto cyfmac43455-sdio.bin     # no sudo
```

Line 123 correctly uses `sudo` for the `--set`; the fallback path omits it. For
a non-root user this is permission-denied, yet line 400 still prints
`Manual restore sequence completed`. The one thing `restore` exists to do
didn't happen, and it claims success.

**Fix:** add `sudo`, and check the exit status before reporting success.

### ⬜ R3. The two most important `nexutil` calls are unchecked

**Where:** `nexmon/scripts/csi_setup.sh:273` (apply CSI params), `:286` (`-m1`)

Neither return code is checked, and the script sets only `set -u`, not
`set -e`. If applying the CSI configuration fails, `start` continues, hands
`wlan0` to Nexmon via `unmanage`, and prints `Startup sequence complete.`

**Fix:** check both explicitly and `die` on failure — especially before
`unmanage`, which is the point of no return for the management path.

### ⬜ R4. `show_chanspec` / `show_monitor_state` both display and return

**Where:** `nexmon/scripts/csi_setup.sh:183-197`, called at `:277` and `:289`

Each function prints its value twice (indented, then bare) *and* echoes it for
capture. Consequences:

- in `status`, the chanspec and monitor state each appear twice
- captured via `$(...)` at lines 277 and 289 they print **nothing**, so
  `"double-check output above"` (line 279) and `"Review above"` (line 291)
  refer to output that the command substitution swallowed

**Fix:** split into a `get_*` (value only, for capture) and a `show_*`
(display only) pair.

### ⬜ R5. The chanspec confirmation is unreliable

**Where:** `nexmon/scripts/csi_setup.sh:278`

Greps a raw hex chanspec blob for a **decimal** channel number, so it can pass
by coincidence or fail on a correct configuration. It is the only guard on the
input the devlog calls out as most error-prone ("don't assume the channel").

**Fix:** decode the chanspec properly, or compare against what
`makecsiparams` was given rather than substring-matching the hex.

---

## Parsing

### ⬜ P1. Two divergent parsers, neither validated against the other

- `csi/parsing/csi_visualize.py` uses `nexcsi`'s per-device
  `decoder("raspberrypi")` → `read_pcap()` → `unpack()`
- `csi/parsing/csi_extraction.md` hand-rolls Scapy: `magic == b"\x11\x11"`,
  then `payload[16:]` as raw little-endian `int16` pairs

`nexcsi` carries per-device profiles precisely because this unpacking is
device-specific, so the hand-rolled version may yield numbers that look
plausible and are wrong. Which one is correct cannot be settled without a real
capture.

**Fix:** run both over the *same* pcap and compare amplitude/phase element-wise
before any numbers from either are trusted. `docs/tasks.md` already flags both
as AI-generated and untested — keep that caveat until this is done.

### ⬜ P2. `csi_visualize.py` applies the null-subcarrier mask only to phase

**Where:** `csi/parsing/csi_visualize.py:50,55,62`

`nonzero_mask` is computed at line 50 but used only for the phase plot (62).
The amplitude waterfall (55) still includes zero-filled null/pilot
subcarriers, which compresses the colour scale. The comment's own reasoning at
lines 48-49 applies to the waterfall too.

**Fix:** apply `nonzero_mask` to the waterfall as well, or state why not.

### ⬜ P3. The chain ends at visualization

`csi/parsing/localize.py` needs a 4-element per-link disruption vector from a
`disruption_metric.py` that does not exist (see `docs/roadmap.md` §3). Already
tracked there; recorded here so the end-to-end gap is visible in one place.

---

## Documentation drift

### ⬜ D1. `docs/roadmap.md:13` is wrong on two counts

- names the script **`rpi-csi.sh`**; the actual file is
  `nexmon/scripts/csi_setup.sh`
- claims *"`capture` can save straight to a `.pcap`"* — it cannot, see **B2**

The same row's companion doc `rpi-csi-README.md` is likewise now
`nexmon/docs/csi_setup-README.md`.

### ⬜ D2. README and `docs/tasks.md` overstate the Pi's state

Both describe Nexmon CSI as "confirmed working end-to-end" on the Pi. The
current SD card is a reinstall: `~/nexmon` was empty, `nexutil` and
`makecsiparams` were absent, and the Wi-Fi firmware was stock Cypress
`7.45.265` rather than the patched `7.45.189`. The tree has since been restored
from the `snapshot-2026-08-24` release, but the install steps in **B1** are
still outstanding, so "working end-to-end" is not yet true again.

**Fix:** reword once B1 is done, or qualify with the date the claim was last
verified.

---

## Verified clean

- `csi_visualize.py` and `localize.py` both compile (`python3 -m py_compile`).
- `nexmon/scripts/csi_setup.sh` is byte-identical to the known-working copy in
  the `snapshot-2026-08-24` release apart from one trailing blank line, so
  these findings apply to the version that was actually in use.
- `shellcheck` was not available in the review environment — the shell
  findings above are from reading, not a linter. Worth re-running under
  `shellcheck` before closing these out.
