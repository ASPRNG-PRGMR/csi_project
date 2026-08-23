#!/usr/bin/env python3
"""
csi_visualize.py — decode a Nexmon CSI pcap capture and produce basic
amplitude/phase visualizations.

Requires:
    pip install nexcsi matplotlib numpy --break-system-packages

Usage:
    python3 csi_visualize.py capture.pcap
    python3 csi_visualize.py capture.pcap --device raspberrypi --out csi_plot.png
"""
import argparse
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")  # save to file; works headless, no display required
import matplotlib.pyplot as plt

from nexcsi import decoder


def main():
    parser = argparse.ArgumentParser(description="Visualize Nexmon CSI from a pcap capture")
    parser.add_argument("pcap", help="Path to pcap captured via tcpdump on udp port 5500")
    parser.add_argument(
        "--device", default="raspberrypi",
        help="Nexmon device profile: raspberrypi, nexus5, nexus6p, rtac86u (default: raspberrypi)"
    )
    parser.add_argument("--out", default="csi_plot.png", help="Output PNG path")
    args = parser.parse_args()

    dec = decoder(args.device)
    samples = dec.read_pcap(args.pcap)

    n_packets = len(samples)
    if n_packets == 0:
        sys.exit(f"No CSI packets found in {args.pcap} — check the capture actually contains udp/5500 CSI frames.")

    print(f"Loaded {n_packets} CSI packets from {args.pcap}")
    print(f"RSSI range: {samples['rssi'].min()} to {samples['rssi'].max()} dBm")

    csi = dec.unpack(samples["csi"])  # complex, shape (n_packets, n_subcarriers)
    amplitude = np.abs(csi)
    phase = np.angle(csi)

    # Nexmon zero-fills null/pilot subcarriers; exclude them from the phase
    # plot below so the x-axis isn't padded with meaningless flat segments.
    nonzero_mask = amplitude.mean(axis=0) > 0
    print(f"Subcarriers: {csi.shape[1]} total, {nonzero_mask.sum()} non-null")

    fig, axes = plt.subplots(2, 1, figsize=(10, 8))

    im = axes[0].imshow(amplitude.T, aspect="auto", origin="lower", cmap="viridis")
    axes[0].set_title(f"CSI Amplitude — {n_packets} packets, {csi.shape[1]} subcarriers")
    axes[0].set_xlabel("Packet index (time)")
    axes[0].set_ylabel("Subcarrier index")
    fig.colorbar(im, ax=axes[0], label="Amplitude")

    mid_packet = n_packets // 2
    axes[1].plot(phase[mid_packet, nonzero_mask])
    axes[1].set_title(f"CSI Phase — packet #{mid_packet} (raw, unwrapped/unsanitized)")
    axes[1].set_xlabel("Subcarrier index (non-null only)")
    axes[1].set_ylabel("Phase (radians)")

    fig.tight_layout()
    fig.savefig(args.out, dpi=150)
    print(f"Saved plot to {args.out}")


if __name__ == "__main__":
    main()
