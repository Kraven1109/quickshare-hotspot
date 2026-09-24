# QuickShare Hotspot 🚀

> **One-command, high-throughput 5 GHz Wi-Fi hotspot for Android Quick Share on Linux.**

Tired of transferring multi-gigabyte 4K videos or files between Android and Linux through a bottlenecked home router or sluggish Bluetooth?

`quickshare-hotspot` creates a dedicated, ad-hoc **5 GHz (80 MHz)** Wi-Fi hotspot right on your Linux machine, configures firewall rules on the fly, launches your Quick Share backend ([rquickshare](https://github.com/MarkGuan/rquickshare) or [Packet](https://github.com/nozwock/packet)), displays a compact Wi-Fi QR code, and tracks live transfer speeds with a clean terminal dashboard.

When you hit `Ctrl+C`, it tears down the hotspot, cleans up firewall rules, and reconnects you to your previous Wi-Fi network like nothing ever happened.

---

## ✨ Features

- **⚡ Blazing Fast (60–90+ MB/s real-world):** Forces 5 GHz on UNII-3 channel 149 with an 80 MHz channel width (the physical ceiling for Linux client AP mode).
- **📱 Instant QR Pairing:** Generates a compact terminal QR code side-by-side with hotspot credentials. Just open your phone camera and connect.
- **🔄 Multi-Backend Support:**
  - **`rquickshare`** (Native on CachyOS / Arch / AUR)
  - **`Packet`** (GTK4 / libadwaita, native binary or Flatpak)
  - Automatic detection favoring native packages.
- **📊 Real-Time TUI Dashboard:**
  - Live throughput (MB/s / KB/s)
  - Accurate session totals, burst peak speed, and average throughput
  - Device name, Wi-Fi link speed (e.g. 1201 Mbps), and RSSI signal strength
- **🛡️ Clean & Non-Destructive:**
  - Never touches your permanent network configurations
  - Temporary UFW rules automatically removed on exit
  - Automatically reconnects your laptop to your regular Wi-Fi on `Ctrl+C`

---

## 📋 Prerequisites

- **Linux** with `NetworkManager` (`nmcli`)
- A Wi-Fi adapter supporting AP mode (most modern Intel, MediaTek, and Qualcomm cards)
- **`qrencode`** (optional, for displaying the terminal QR code)
- Either of the following Quick Share backends:
  - **`rquickshare`** (Recommended):
    ```bash
    # Arch / CachyOS
    paru -S r-quick-share
    ```
  - **`Packet`**:
    ```bash
    # Arch / AUR
    paru -S packet
    # Or via Flathub
    flatpak install flathub io.github.nozwock.Packet
    ```

---

## 🚀 Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/kraven1109/quickshare-hotspot.git
   cd quickshare-hotspot
   ```

2. Make the script executable:
   ```bash
   chmod +x quickshare-hotspot.sh
   ```

3. Run it:
   ```bash
   ./quickshare-hotspot.sh
   ```

4. **Scan the QR code** on your phone to connect to `QS-Laptop`, then share files via **Quick Share** as usual!

---

## 🛠️ Options & Usage

```bash
Usage:
  ./quickshare-hotspot.sh [options]

Options:
  --5g, --5ghz         Force 5 GHz band (UNII-3 ch 149, 80 MHz)
  --2g, --2ghz         Force 2.4 GHz band (fallback for older devices)
  --rquickshare        Force rquickshare backend
  --packet             Force Packet backend (Rust / GTK4)
  --backend <name>     Select backend: auto (default), rquickshare, packet
  --no-qr              Do not display Wi-Fi QR code (text credentials only)
  --qr-margin <N>      Set QR margin width (default: 2, balanced)
  --keep-rules         Keep temporary UFW rules after exit
  -h, --help           Show help message
```

---

## 🧠 Why 5 GHz 80 MHz? (And not 160 MHz?)

If you're using modern hardware (like an Intel BE200 or AX210), you might wonder: *why not 160 MHz or 6 GHz?*

- **DFS Regulations:** On Linux, client Wi-Fi cards lack Master Radar Detection certification (DFS Master). All DFS channels (52–144) are strictly locked to `NO-IR` (No Initiate Radiation). 160 MHz on 5 GHz requires spanning into DFS channels.
- **UNII-3 (Channel 149):** Is non-DFS and allows SoftAP, but only spans 80 MHz wide.
- **Physical Limit:** 80 MHz at 2x2 MIMO yields a maximum physical PHY rate of 1201 Mbps. After Wi-Fi framing, TCP ACK overhead, and TLS encryption, **80–90+ MB/s (~700 Mbps)** is the real-world physical ceiling.

*(For detailed radio frequency and driver specs, check out [.agent/AGENTS.md](.agent/AGENTS.md)).*

---

## 🙏 Credits & Acknowledgements

This script is merely a glue layer; the real heavy lifting was done by the brilliant developers who reverse-engineered Google's proprietary protocol:

- **Martins Dzervitis ([@MarkGuan](https://github.com/MarkGuan))** — For creating [rquickshare](https://github.com/MarkGuan/rquickshare), the blazing-fast Rust implementation that paved the way for Quick Share on Linux.
- **[@nozwock](https://github.com/nozwock)** — For developing [Packet](https://github.com/nozwock/packet), providing a gorgeous, modern GTK4 / libadwaita Quick Share client.

---

## ☕ The Coffee & Beer Protocol 🍺

If this script saved your sanity and made transferring your 4K drone footage, vacation videos, or massive datasets effortless:

- You can [buy me a coffee](https://github.com/kraven1109)! 😄
- **HOWEVER**, strict developer etiquette dictates: **Before you buy me a coffee, you MUST buy the creators of [rquickshare](https://github.com/MarkGuan/rquickshare) and [Packet](https://github.com/nozwock/packet) a cold beer (or three).** They performed the deep reverse-engineering wizardry; I just wrapped it in Wi-Fi channels and firewall rules!

---

## 📄 License

MIT © [kraven1109](https://github.com/kraven1109) (`tmquangvn@gmail.com`)
