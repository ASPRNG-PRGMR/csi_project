"""
localize.py — device-free localization for a 4-ESP32-corner / 1-central-AP
CSI sensing setup.

Topology assumed: one AP transmits, four ESP32 nodes at room corners each
report a per-link disruption metric (e.g. rolling variance or top PCA
component magnitude of CSI amplitude over a short time window). This module
does NOT parse CSI itself — feed it a 4-element vector of per-link disruption
values from whatever upstream parser you're using (nexcsi, your teammate's
ESP32 parser, etc.), computed identically for all 4 links over the same time
window.

Two localization strategies:
    1. weighted_centroid()   — geometric, no calibration required, but loses
                                resolution near the room center (see README
                                note below).
    2. Fingerprint (kNN)     — needs a short calibration walk, but is more
                                accurate given only 4 links.

Known limitation: since all 4 links share the AP as one endpoint, they are
"spokes" radiating outward rather than lines crossing the room. A person near
the AP disrupts all 4 links roughly equally, so position resolution near the
center is inherently poor with this topology — that's a geometry limit, not
a bug in the code below.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Room geometry — EDIT to match your actual room dimensions / corner layout.
# Units are arbitrary but must be consistent (meters recommended).
# ---------------------------------------------------------------------------

ROOM_WIDTH = 5.0
ROOM_HEIGHT = 4.0

# Order must match the order you feed disruption vectors in everywhere else.
CORNERS = {
    "corner_1": (0.0, 0.0),
    "corner_2": (ROOM_WIDTH, 0.0),
    "corner_3": (ROOM_WIDTH, ROOM_HEIGHT),
    "corner_4": (0.0, ROOM_HEIGHT),
}
CORNER_ORDER = list(CORNERS.keys())  # index 0..3 matches vector position

AP_POSITION = (ROOM_WIDTH / 2, ROOM_HEIGHT / 2)  # edit if AP isn't centered


# ---------------------------------------------------------------------------
# Strategy 1: weighted centroid (no calibration)
# ---------------------------------------------------------------------------

def weighted_centroid(link_values: list[float]) -> tuple[float, float]:
    """
    Estimate (x, y) as the weighted average of corner positions, weighted by
    each corner's link disruption magnitude. Negative/NaN values are clamped
    to 0. Returns AP_POSITION if all weights are ~0 (no disruption detected).
    """
    if len(link_values) != len(CORNER_ORDER):
        raise ValueError(f"Expected {len(CORNER_ORDER)} link values, got {len(link_values)}")

    weights = np.clip(np.nan_to_num(np.array(link_values, dtype=float)), 0, None)
    total = weights.sum()
    if total <= 1e-9:
        return AP_POSITION

    xs = np.array([CORNERS[c][0] for c in CORNER_ORDER])
    ys = np.array([CORNERS[c][1] for c in CORNER_ORDER])
    x = float((weights * xs).sum() / total)
    y = float((weights * ys).sum() / total)
    return (x, y)


# ---------------------------------------------------------------------------
# Strategy 2: fingerprinting (kNN against a calibration map)
# ---------------------------------------------------------------------------

@dataclass
class CalibrationPoint:
    position: tuple[float, float]
    link_values: list[float]


@dataclass
class FingerprintMap:
    points: list[CalibrationPoint] = field(default_factory=list)

    def add(self, position: tuple[float, float], link_values: list[float]) -> None:
        if len(link_values) != len(CORNER_ORDER):
            raise ValueError(f"Expected {len(CORNER_ORDER)} link values, got {len(link_values)}")
        self.points.append(CalibrationPoint(position, list(link_values)))

    def save(self, path: str) -> None:
        data = [{"position": p.position, "link_values": p.link_values} for p in self.points]
        Path(path).write_text(json.dumps(data, indent=2))

    @classmethod
    def load(cls, path: str) -> "FingerprintMap":
        data = json.loads(Path(path).read_text())
        fmap = cls()
        for entry in data:
            fmap.add(tuple(entry["position"]), entry["link_values"])
        return fmap

    def localize(self, link_values: list[float], k: int = 3) -> tuple[float, float]:
        """
        k-nearest-neighbor match against calibration points, using normalized
        Euclidean distance in link-value space. Returns the weighted average
        position of the k closest calibration points (inverse-distance
        weighted), which smooths between grid points rather than snapping to
        the single nearest one.
        """
        if not self.points:
            raise RuntimeError("FingerprintMap is empty — run calibration first.")

        query = np.array(link_values, dtype=float)
        cal_matrix = np.array([p.link_values for p in self.points], dtype=float)

        # Normalize per-link scale so no single noisy/high-magnitude link
        # dominates the distance metric.
        scale = cal_matrix.std(axis=0)
        scale[scale < 1e-9] = 1.0
        cal_norm = cal_matrix / scale
        query_norm = query / scale

        dists = np.linalg.norm(cal_norm - query_norm, axis=1)
        k = min(k, len(self.points))
        nearest_idx = np.argsort(dists)[:k]

        weights = 1.0 / (dists[nearest_idx] + 1e-6)
        weights /= weights.sum()

        positions = np.array([self.points[i].position for i in nearest_idx])
        x = float((weights * positions[:, 0]).sum())
        y = float((weights * positions[:, 1]).sum())
        return (x, y)


# ---------------------------------------------------------------------------
# Example / manual calibration helper
# ---------------------------------------------------------------------------

def run_calibration_session(map_path: str = "fingerprint_map.json") -> None:
    """
    Interactive helper: stand at a known position, hit enter, type the
    live 4-link disruption values (or wire this to read from your parser
    directly instead of typing them in). Repeat for enough grid points to
    cover the room, then save.
    """
    fmap = FingerprintMap()
    print("Calibration session. Enter 'done' as the x-coordinate to finish.")
    while True:
        x_in = input("Position x (meters, or 'done'): ").strip()
        if x_in.lower() == "done":
            break
        y_in = input("Position y (meters): ").strip()
        values_in = input(f"Link values for {CORNER_ORDER} (comma-separated): ").strip()
        try:
            x, y = float(x_in), float(y_in)
            values = [float(v) for v in values_in.split(",")]
            fmap.add((x, y), values)
            print(f"  Added calibration point at ({x}, {y})")
        except ValueError as e:
            print(f"  Skipped, couldn't parse input: {e}")

    fmap.save(map_path)
    print(f"Saved {len(fmap.points)} calibration points to {map_path}")


if __name__ == "__main__":
    # Quick smoke test with made-up numbers — replace with real link values.
    example_values = [0.1, 0.8, 0.2, 0.05]  # strongest disruption near corner_2
    print("Weighted centroid estimate:", weighted_centroid(example_values))
