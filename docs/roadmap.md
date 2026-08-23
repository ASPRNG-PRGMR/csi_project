# After Nexmon CSI: Roadmap & File Index

Nexmon CSI on the RPi 4B is fully working — firmware pinned, `wlan0`
unmanaged, CSI packets confirmed flowing over UDP :5500. This document is
the map of what exists so far and what can be built next.

---

## 1. Files produced so far

| File | What it does | Where it runs |
|---|---|---|
| `rpi-csi.sh` | Interactive `start` / `capture` / `status` / `restore` automation for the every-boot Nexmon CSI startup sequence. `capture` can save straight to a `.pcap`. | Raspberry Pi |
| `rpi-csi-README.md` | Full runbook: commands, normal-session walkthrough, and every failure hit so far (firmware auto-selection bug, stale dmesg false-positives, `unmanage` disconnect error, rfkill) with root causes and fixes. | Reference doc |
| `csi_visualize.py` | Decodes a `.pcap` capture with `nexcsi` and plots an amplitude waterfall (subcarrier × time) + a raw phase slice. First real look at the data. | Wherever the pcap ends up (e.g. Fedora) |
| `localize.py` | Device-free localization for a 4-corner-ESP32 / 1-central-AP spoke topology: `weighted_centroid()` (no calibration) and `FingerprintMap` (kNN, calibration-based). Takes a plain 4-value disruption vector — decoupled from whichever CSI parser feeds it. | Anywhere Python runs |

---

## 2. Current team assignments

**Junior 1 — raw ESP32 CSI, tabular format, browser plot later**
- Current: raw CSI values in a pretty table for manual analysis.
- Next: add derived columns (amplitude, phase per subcarrier, RSSI, sequence
  number) so the table is analysis-ready, not just a raw dump.
- Next: CSV/log export with timestamps, so captures can be replayed/compared
  later instead of only viewed live.
- Next: the browser plot itself — live-updating amplitude heatmap
  (Chart.js/Plotly.js), same idea as `csi_visualize.py` but live and in-browser.
- Later: rolling variance (or mean-across-subcarriers variance) per time
  window — this becomes `disruption_metric.py` (see §3), and plugs straight
  into `localize.py`.

**Junior 2 — dual-ESP32 repo, <10 cm antenna spacing**
- First: confirm with them whether the <10 cm spacing is an intentional
  Angle-of-Arrival (AoA) pair or incidental. At 2.4 GHz (~12.5 cm
  wavelength), that spacing is in classic AoA range.
- If AoA is the goal: phase-difference estimation between the two ESP32s on
  matching subcarriers, averaged across subcarriers, converted to an angle
  via the standard array-spacing formula. Flag ambiguity: at >half-wavelength
  spacing (~6.25 cm), multiple angles can produce the same wrapped phase
  difference — needs either a restricted field of view or explicit
  ambiguity resolution.
- Precursor task: one-time hardware phase-offset calibration (known
  reference angle, solve for the static per-device offset) — needed before
  AoA numbers mean anything.
- Later: log AoA over time and validate against the ground-truth logger
  (§4) once that exists.

---

## 3. Immediate next steps (natural continuation)

- **`disruption_metric.py`** — not yet built. Reads live/pcap CSI and computes a rolling variance (or PCA-component magnitude) per time window, in the same format `localize.py` expects. This is the missing link between "CSI is flowing" and "`localize.py` has real numbers to work with."
- **Cross-validate RPi vs ESP32 links** — run the same disruption metric on both, confirm they agree on obvious cases (e.g. someone walking near one corner) before trusting either for localization.
- **Fix the disruption-metric definition across teammates** — whoever computes ESP32-side values needs to use the same window size and same statistic (variance vs PCA) as the RPi side, or `localize.py`'s math won't be comparing like with like.

---

## 4. Ground truth, fingerprinting, and "do we need to train a model?"

Worth being explicit about this with the team, since these three get
conflated easily:

- **Ground-truth logging** (not yet built) — a simple tool where someone
  marks "I am now standing at (x, y)" with a timestamp while the system
  runs. This is *not* training data — it's just a record of what really
  happened, so any method's output (weighted centroid, fingerprinting, AoA)
  can be scored against reality afterward. Needed regardless of which
  localization method is used. Small, standalone, high-value — good task
  for anyone with spare bandwidth.
- **Fingerprinting (`FingerprintMap` in `localize.py`) is not ML training.**
  It's a lookup table: walk to ~10–20 marked spots once, record the CSI
  signature at each, done. No train/test split, no generalization
  requirement, because it's deployed in the same room it was calibrated in.
  Room changes (furniture moved, different day) → re-walk, not retrain.
- **Actual ML with multiple scenarios** is only needed if the goal moves
  past "where is a person" into something that must generalize — activity
  recognition (walking/falling/sitting), gesture recognition, or working
  across different rooms/people without recalibrating. That requires real
  labeled classes across repeated trials and a proper train/val/test split.
  This is a later, separate goal from localization — not a prerequisite.

**So for localization specifically:** build the ground-truth logger, do one
calibration walk per room config, and compare `weighted_centroid()` vs
`FingerprintMap` output against the logged ground truth. Skip "collect
multi-scenario data and train a model" until/unless activity or gesture
recognition becomes an actual goal.

---

## 5. Classical signal processing (no ML yet)

- **PCA/eigenvalue decomposition** across subcarriers — collapses ~50 correlated subcarrier signals into a few components that track motion far more cleanly than raw amplitude. Used by CARM, WiFall.
- **Bandpass filtering for vitals** — isolate ~0.1–0.5 Hz for breathing rate, ~0.8–2 Hz for heartbeat.
- **STFT / spectrogram (micro-Doppler)** — turns CSI amplitude-over-time into a radar-like image; different activities (walking, falling, waving) get visually distinct signatures. Basis of WiSee (gesture) and Widar (gait/activity).

## 6. ML on top of extracted features

- Windowed statistical features (mean, std, skew, kurtosis, entropy) → SVM / Random Forest for coarse activity classes.
- CNN/LSTM directly on spectrograms → finer gesture/activity recognition (Widar3.0-style).

## 7. Multi-node localization (where `localize.py` fits)

- Current state: 1 AP + 4 corner receivers = 4 "spoke" links radiating from the AP. Good resolution near individual corners, weak resolution near the room center — a geometry limit of this topology, documented in `localize.py`.
- **Fingerprinting calibration walk** — `FingerprintMap` in `localize.py` needs ~8–12 labeled positions to meaningfully outperform the plain weighted centroid, especially near the center.
- **AoA fusion** — if Junior 2's pair produces a usable angle, combining it with the 4-corner spoke estimate gives a real 2D fix (angle + rough distance) instead of only "closer to this corner" — a solid unlock once both pieces work independently.
- **If node count/topology ever grows**: switching from "1 AP + N receivers" to "all N nodes as peers" (mesh) turns spoke links into criss-crossing links, which is what real Radio Tomographic Imaging needs for actual 2D imaging rather than coarse zone estimates. Worth revisiting if the 4-ESP32 setup expands.

## 8. Once localization/detection is reliable

- **Visualization dashboard** — live plot of estimated position over time (matplotlib animation, or a simple web dashboard) instead of one-off static PNGs from `csi_visualize.py`.
- **Event logging** — timestamped log of detected motion/position for later analysis, rather than only real-time viewing.
- **Multi-person handling** — current pipeline assumes one person in the room; multi-target tracking is a substantially harder, separate problem if that's ever a requirement.

---

## 9. Work for peers (parallel, not junior-scoped)

These are bigger/more architectural pieces, better suited to whoever's more
senior on the team rather than the juniors' current task queue:

- **Central data collector / time sync** — ingest RPi Nexmon CSI, the ESP32
  corner streams, and eventually the AoA pair, all timestamped into one
  aligned stream (NTP or a shared collector clock). Needed before any of the
  above sources can be meaningfully fused — right now they're independent
  pipelines with no shared clock.
- **Ground-truth logger build-out** — the concept is simple (§4), but making
  it easy enough that anyone can run it during a test session (mobile-friendly
  UI, or even a physical button/QR-code-per-tile scheme) is worth real
  design effort, since data quality for every future comparison depends on it.
- **Cross-source validation harness** — a script that takes RPi, ESP32-corner,
  and (later) AoA outputs plus the ground-truth log, and reports accuracy/error
  per method automatically, instead of eyeballing it each time.
- **Repo/pipeline consolidation** — right now there are at least 3 separate
  codebases in play (Nexmon RPi pipeline, Junior 1's ESP32 table/plot,
  Junior 2's cloned dual-ESP32 repo). Worth someone owning a shared repo
  structure/interfaces (e.g. a common CSI-sample schema) before these
  multiply further and integration becomes painful.
- **Room geometry & AP placement decisions** — `localize.py`'s accuracy is
  sensitive to `CORNERS`/`AP_POSITION` matching reality precisely; worth one
  person owning an accurate room map (measured, not eyeballed) that all
  localization code references.

---

## 10. Suggested order of attack

1. Build `disruption_metric.py` so `localize.py` has real input (Junior 1's
   later task, or a peer if it's time-sensitive).
2. Build the ground-truth logger (§4/§9) — needed before anything else can
   be judged as "working."
3. Get RPi + ESP32 corners agreeing on the same metric/window definition.
4. Run `weighted_centroid()` live, sanity-check against the ground-truth log.
5. Do a calibration walk, switch to `FingerprintMap` for better accuracy.
6. Resolve Junior 2's AoA question, get a working angle estimate, fuse with
   the spoke-based position if it pans out.
7. Only then reach for PCA/spectrogram/ML — useful for richer sensing
   (activity, not just position), but not required to get basic
   localization working.
