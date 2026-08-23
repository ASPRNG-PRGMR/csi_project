# CSI Extraction from Nexmon UDP Capture

Pipeline covered by this guide:

```
ESP32
  │  WiFi frames
  ▼
BCM43455C0 (Pi radio)
  │  Nexmon
  ▼
CSI
  │
  ▼
UDP :5500
  │
  ▼
PCAP
  │
  ▼
Python (Scapy)
  │
  ▼
Raw CSI (.npy)
```

---

## 1. Capture the UDP packets with tcpdump

On the Raspberry Pi:

```bash
sudo tcpdump -i wlan0 udp port 5500 -w csi_capture.pcap
```

Let the ESP32 transmit for the desired duration, then stop the capture:

```
Ctrl+C
```

You should now have `csi_capture.pcap`.

> **Important:** Do not redirect normal tcpdump output to a `.txt` file. The `.pcap` file contains the actual packet bytes required to recover CSI.

---

## 2. Verify the capture contains Nexmon packets

```bash
tcpdump -nn -r csi_capture.pcap
```

You should see UDP packets involving port 5500. Check the packet count:

```bash
tcpdump -nn -r csi_capture.pcap | wc -l
```

---

## 3. Install Python packet-parsing dependencies

```bash
sudo apt update
sudo apt install python3-scapy
```

Verify:

```bash
python3 -c "from scapy.all import rdpcap; print('Scapy OK')"
```

Expected output:

```
Scapy OK
```

---

## 4. Create the CSI extraction script

```bash
nano extract_csi.py
```

```python
from scapy.all import rdpcap, UDP
import struct
import numpy as np

PCAP_FILE = "csi_capture.pcap"

packets = rdpcap(PCAP_FILE)

all_csi = []
metadata = []

for packet_index, packet in enumerate(packets):

    # Only process UDP packets
    if UDP not in packet:
        continue

    udp = packet[UDP]

    # Nexmon CSI uses UDP destination port 5500
    if udp.dport != 5500:
        continue

    payload = bytes(udp.payload)

    # Ignore packets that are too short
    if len(payload) < 16:
        continue

    # -------------------------------------------------
    # Nexmon CSI header
    # -------------------------------------------------

    magic = payload[0:2]

    # Verify Nexmon CSI magic
    if magic != b"\x11\x11":
        continue

    source_mac = payload[2:8]
    sequence = struct.unpack("<H", payload[8:10])[0]
    core_nss = struct.unpack("<H", payload[10:12])[0]
    chanspec = struct.unpack("<H", payload[12:14])[0]
    chip_version = struct.unpack("<H", payload[14:16])[0]

    # -------------------------------------------------
    # CSI data
    # -------------------------------------------------

    csi_bytes = payload[16:]

    # CSI consists of signed 16-bit values:
    # Re0, Im0, Re1, Im1, Re2, Im2, ...

    # Make sure the number of bytes is even
    if len(csi_bytes) % 2 != 0:
        continue

    csi_values = np.frombuffer(csi_bytes, dtype=np.int16)

    # Separate real and imaginary components
    real = csi_values[0::2]
    imag = csi_values[1::2]

    # Construct complex CSI
    csi = real.astype(np.float32) + 1j * imag.astype(np.float32)

    all_csi.append(csi)

    metadata.append([
        packet_index,
        sequence,
        core_nss,
        chanspec,
        chip_version,
        source_mac.hex(":")
    ])


# -----------------------------------------------------
# Save results
# -----------------------------------------------------

if len(all_csi) == 0:
    print("No valid Nexmon CSI packets found.")
    exit()

# Check that all packets have the same CSI length
lengths = [len(x) for x in all_csi]

if len(set(lengths)) != 1:
    print("Warning: CSI packet lengths are not identical.")
    min_length = min(lengths)
    all_csi = [x[:min_length] for x in all_csi]

# Convert to matrix
csi_matrix = np.vstack(all_csi)

# Save complex CSI
np.save("csi_raw.npy", csi_matrix)

# Save metadata
with open("csi_metadata.csv", "w") as f:
    f.write(
        "packet_index,sequence,core_nss,"
        "chanspec,chip_version,source_mac\n"
    )
    for row in metadata:
        f.write(",".join(map(str, row)) + "\n")


# -----------------------------------------------------
# Display information
# -----------------------------------------------------

print("\nCSI extraction successful")
print("--------------------------------")
print("CSI packets :", len(csi_matrix))
print("CSI shape   :", csi_matrix.shape)
print("CSI saved   : csi_raw.npy")
print("Metadata    : csi_metadata.csv")

print("\nFirst CSI packet:")
print(csi_matrix[0])
```

Save: `Ctrl+O`, `Enter`, `Ctrl+X`

---

## 5. Run the extractor

Make sure both files are in the same directory:

```
your_directory/
├── csi_capture.pcap
└── extract_csi.py
```

Run:

```bash
python3 extract_csi.py
```

A successful extraction looks approximately like:

```
CSI extraction successful
--------------------------------
CSI packets : 1000
CSI shape   : (1000, N)
CSI saved   : csi_raw.npy
Metadata    : csi_metadata.csv
```

> `N` depends on your actual Nexmon CSI configuration — channel bandwidth, number of subcarriers, cores, etc.

---

## 6. Understand what you just extracted

`csi_raw.npy` contains a matrix:

|              | Subcarrier 0 | Subcarrier 1 | Subcarrier 2 | Subcarrier 3 | ... |
|---|---|---|---|---|---|
| **Packet 0** | H0 | H1 | H2 | H3 | ... |
| **Packet 1** | H0 | H1 | H2 | H3 | ... |
| **Packet 2** | H0 | H1 | H2 | H3 | ... |
| **Packet 3** | H0 | H1 | H2 | H3 | ... |

Each `H` is complex: `H = Real + j·Imaginary`

Example:
```
H0 = 124 + 37j
H1 = 118 - 42j
H2 = 130 + 51j
```

These are the **raw CSI complex values** extracted from the Nexmon UDP packets.

**Not yet calculated at this stage:**
- amplitude
- phase
- variance
- mean
- standard deviation
- filtering
- ML features

That's expected — this stage only produces the raw complex CSI.

---

## 7. Verify the saved CSI

```bash
python3
```

```python
import numpy as np

csi = np.load("csi_raw.npy")

print(csi.shape)
print(csi[0])
```

Expected output:

```
(1000, 256)
[123.+45.j 118.-32.j  ...]
```

> Exact dimensions depend on your configuration.

Exit Python:

```python
exit()
```

---

## 8. Check the metadata

```bash
head csi_metadata.csv
```

Expected format:

```
packet_index,sequence,core_nss,chanspec,chip_version,source_mac
0,1234,...,...,...,xxxxxxxxxxxx
1,1235,...,...,...,xxxxxxxxxxxx
2,1236,...,...,...,xxxxxxxxxxxx
```

The `source_mac` column is particularly useful for confirming CSI comes specifically from your ESP32.

---

## 9. Verify the source is your ESP32

This step is important for the project.

The `source_mac` stored in `csi_metadata.csv` should correspond to the WiFi MAC address of your ESP32.

> If it doesn't match, don't proceed with the dataset yet — you may be capturing CSI generated from other WiFi traffic, not your ESP32.

---

## 10. Final directory structure

```
csi_capture/
│
├── csi_capture.pcap
├── extract_csi.py
├── csi_raw.npy
└── csi_metadata.csv
```

### What each file is

| File | Purpose |
|---|---|
| `csi_capture.pcap` | Original packet capture — keep this |
| `extract_csi.py` | Converts Nexmon UDP packets into CSI |
| `csi_raw.npy` | Extracted complex raw CSI |
| `csi_metadata.csv` | Sequence/MAC/core/chanspec information |
