# CSI Project — Task Assignments

> Current, working list of who's doing what. This is the doc to update
> day-to-day. `project_plan.md`'s "Current Team Tasks" table is the
> higher-level phase view — update both if a task changes phase, but this
> file is the source of truth for day-to-day status.

## Status legend

- 🟢 Done
- 🟡 In progress
- ⚪ Not started
- 🔴 Blocked

---

## Active tasks

| Person | Task | Status | Dependencies | Expected Output |
|---|---|---|---|---|
| (you) | Nexmon CSI bring-up on RPi 4B | 🟢 Done | — | Verified CSI over UDP :5500 (`nexmon/setup/rpi-csi-devlog.md`) |
| (you) | `csi_setup.sh` automation script | 🟢 Done (channel + MAC still manual input) | Nexmon bring-up | One-command start/capture/status/restore (`nexmon/scripts/`) |
| Shaily (MITBLR Junior) | Clean tabular representation of ESP32 CSI (previous repo now running) | 🟡 In progress — tabular format is the current target, nothing further yet | Previous repo running | Pretty-printed / tabular CSI output |
| Aarushi | Get the latest dual-ESP32 GitHub repo running | ⚪ Not started | Repo link (sent separately) | Confirmed working dual-ESP32 setup — precursor to the AoA question in `docs/roadmap.md` §2 |
| Rishabh (MITBLR 316) | Get the parser script running (`csi/parsing/`) and confirm it actually visualizes what Nexmon is seeing | 🟡 In progress | Nexmon CSI captures (.pcap) | Working visualization of captured CSI — script itself is unverified, not required to keep using it as-is |

## Notes

- The parser script(s) in `csi/parsing/` (`csi_visualize.py`, `localize.py`, `csi_extraction.md`) were AI-generated and **have not been tested**. Treat them as a starting point, not a known-good tool — verify output against a real capture before trusting any numbers out of them.
- `localize.py` depends on a `disruption_metric.py` that doesn't exist yet (see `docs/roadmap.md` §3) — not blocking Rishabh's current task, but worth knowing before anyone tries to run localization end-to-end.
- Channel and MAC address are still manual inputs to `csi_setup.sh` — not yet automated, not currently planned to be (transmitter identity should stay an explicit, checked input rather than assumed).
