# Canonical Architecture & Technical Specifications

> **Notice:** This document contains the canonical architectural specifications, hardware constraints, and development guidelines for `quickshare-hotspot.sh`. All agents and contributors must follow these guidelines.

---

## 1. Hardware & Physical Radio Constraints

### Intel Wi-Fi 7 / 6E Client Chips (e.g. Intel BE200, AX210) on Linux
1. **DFS & Regulatory Restrictions in AP Mode:**
   - Intel cards running under the Linux `iwlwifi` driver enforce firmware-managed Location-Aware Regulatory (LAR).
   - Client Wi-Fi cards are certified strictly as **client-only** devices; they lack Master Radar Detection certification (DFS Master).
   - In Linux AP/Hotspot mode, all DFS frequency ranges (UNII-2A channels 52–64, UNII-2C channels 100–144) are marked `NO-IR` (No Initiate Radiation). The kernel strictly forbids transmitting beacons on these channels.
   - Consequently, the only non-DFS 5 GHz channels available for SoftAP are **UNII-1 (channels 36–48)** and **UNII-3 (channels 149–165)**.

2. **The 160 MHz Myth on 5 GHz SoftAP:**
   - A contiguous 160 MHz channel on 5 GHz requires spanning across channels 36–64 (which overlaps UNII-2A DFS) or 100–128 (pure DFS).
   - In UNII-3, channels 149–165 only span 80 MHz (channels 149, 153, 157, 161). Spanning 160 MHz in UNII-3 would require UNII-4 (channels 165–177), which is not universally available or unconstrained.
   - **Conclusion:** On Linux client hardware, **80 MHz width on channel 149 is the absolute physical ceiling** for 5 GHz AP mode. 160 MHz cannot be enabled without DFS master hardware.

3. **6 GHz (Wi-Fi 6E / Wi-Fi 7) AP Status:**
   - Linux kernel and Intel firmware strictly disallow AP beaconing in the 6 GHz band for client cards due to the requirement for AFC (Automated Frequency Coordination) or strict LPI (Low Power Indoor) enforcement.

4. **Physical Speed Ceiling & Optimal RF Geometry:**
   - **Theoretical PHY Rate:** 80 MHz on 2x2 MIMO (HE / Wi-Fi 6) yields a theoretical max of 1201 Mbps (or 1300 Mbps in EHT Wi-Fi 7 with 4096-QAM).
   - **Real-world Throughput:** After accounting for 802.11 framing, TCP ACK overhead, TLS encryption, and Quick Share framing, the real-world ceiling is **~80–90+ MB/s** (~640–720 Mbps, approximately 70–75% of physical capacity).
   - **LNA Clipping:** Placing the phone immediately next to the laptop (< 5 cm) oversaturates the Low-Noise Amplifier (LNA) on the receiver, dropping the modulation from MCS 11 to MCS 8. An optimal RF distance is **30–100 cm** (yielding -35 dBm to -45 dBm RSSI).

---

## 2. Software Architecture & Invariants

### Network Layer
- **NetworkManager Profile:** Uses a temporary profile (`qs-hotspot`) with `ipv4.method=shared` on subnet `10.42.0.0/24`. NetworkManager runs an internal `dnsmasq` instance for DHCP leases.
- **Firewall (UFW / iptables):** When UFW is active, incoming traffic on the hotspot interface (`$WIFI_IFACE`) is temporarily allowed. Legacy specific rules (5353/udp, 10.42.0.0/24) are cleaned up during teardown.
- **Cleanup Trap:** The script installs a strict trap on `INT`, `TERM`, `EXIT`. When invoked, it:
  1. Terminates the spawned Quick Share process.
  2. Deletes the `qs-hotspot` NetworkManager connection.
  3. Deletes temporary firewall rules.
  4. Automatically reconnects to the pre-existing Wi-Fi connection (`PREV_WIFI`).

### Traffic Measurement Engine
- **Kernel Polling:** Throughput is sampled directly from `/sys/class/net/$WIFI_IFACE/statistics/{rx,tx}_bytes`.
- **Timing Accuracy:** Sampling delta is measured using nanosecond timers (`date +%s%N`). Rates are calculated as `delta_bytes / dt_seconds` as floating-point / millisecond calculations, preventing integer division spikes.
- **Burst Smoothing:** A 3-tick idle confirmation window (`IDLE_CONFIRM_TICKS=3`) ensures transfers with minor pauses are not prematurely logged as multiple fragmented sessions.
- **Non-blocking Station Query:** Station MAC, RSSI, and TX/RX link bitrates are gathered via `iw dev $WIFI_IFACE station dump`. Client IP/hostname lookup is cached and resolved asynchronously in a background subshell so the 1-second TUI tick is never delayed.

### Quick Share Backends
- **`rquickshare`:** Default / native CachyOS & Arch implementation (`cachyos/r-quick-share`).
- **`Packet`:** Alternative GTK4 / libadwaita client (`nozwock/packet`), supported via native binary (`packet`) or Flatpak (`io.github.nozwock.Packet`).
- Both backends leverage the `rqs_lib` core Rust crate and listen on mDNS `5353/udp` and dynamically allocated TCP sockets.

---

## 3. Development & Maintenance Rules for AI Agents

1. **NO `set -e`:**
   - Do **NOT** enable `set -e` in `quickshare-hotspot.sh`. Many probing operations (`nmcli`, `iw`, `pgrep`, `ss`) intentionally return non-zero exit codes during initial environment detection. `set -e` triggers premature exit and fires the cleanup trap unexpectedly.

2. **Preserve Variable Initialization:**
   - Since `set -uo pipefail` is enforced, all variables checked in `cleanup()` (`HAS_UFW`, `ADDED_UFW_RULE`, `HOTSPOT_CREATED`, `WIFI_IFACE`, `PREV_WIFI`, `RQS_PID`, `RQS_LOG`) **must** be initialized with safe default values at the top of the script.

3. **QR Code Formatting Invariant:**
   - In terminal half-block rendering (`ANSIUTF8`), each character row contains 2 vertical module pixels.
   - `QR_MARGIN` **must remain an even number** (default: `2`). An odd margin (e.g. 1) leaves a half-character row at the top edge, causing the white quiet zone to merge into the dark terminal background and visually cutting off the top border of the finder patterns.

4. **Zero-blocking TUI:**
   - Any external network calls (DNS PTR lookups, ARP discovery, external queries) within the main monitoring loop **must** be asynchronous or non-blocking. The TUI refresh must maintain a smooth, predictable 1.0-second rhythm.
