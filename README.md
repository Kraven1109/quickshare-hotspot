# quickshare-hotspot

A high-speed 5 GHz (80 MHz) Wi-Fi hotspot wrapper and live TUI dashboard for [Open QuickShare](https://github.com/ignotusbucius/open-quickshare) and [Packet](https://github.com/nozwock/packet) on Linux (also backward-compatible with legacy [rquickshare](https://github.com/Martichou/rquickshare)).

## Why This Wrapper?

- **[Open QuickShare](https://github.com/ignotusbucius/open-quickshare)** implements the full Quick Share stack (BLE + Wi-Fi Direct + automatic hotspot), **but** its built-in hotspot currently hardcodes `band bg` (2.4 GHz, ~5–15 MB/s) and requires manual firewall configuration when UFW is active.
- **[Packet](https://github.com/nozwock/packet)** and legacy **rquickshare** require both devices to share a Wi-Fi LAN.

By pre-creating a dedicated **5 GHz (80 MHz)** hotspot on the laptop, both devices join the same `10.42.0.0/24` LAN and transfer directly over mDNS at **~80–90+ MB/s** — bypassing 2.4 GHz throttling and congested routers.

This script automates the entire workflow:
1. Spins up a 5 GHz hotspot (channel 149 / 36, 80 MHz width) via NetworkManager.
2. Opens temporary firewall rules automatically if UFW or `firewalld` is active.
3. Generates a compact terminal QR code for fast phone connection (with optional `--random-pass`).
4. Launches `Open QuickShare` (or `Packet`) and displays a real-time transfer dashboard (including RSSI and LNA clipping `!close` warnings).
5. On `Ctrl+C`, terminates the backend, removes the hotspot, cleans up firewall rules, and reconnects to your previous Wi-Fi.

## Requirements

- Linux with `NetworkManager` (`nmcli`)
- Wi-Fi card supporting AP mode
- `qrencode` (optional, for QR display)
- Supported backend (at least one installed):
  - **Open QuickShare (Recommended):** AUR `open-quickshare-bin` / `open-quickshare`, `.deb`, `.rpm`, or AppImage
  - **Packet:** AUR `packet` or Flathub `io.github.nozwock.Packet`
  - **rquickshare (Legacy):** still works automatically via `/usr/bin/rquickshare`

## Usage

```bash
chmod +x quickshare-hotspot.sh
./quickshare-hotspot.sh

# Random per-session password (great with QR scanning)
./quickshare-hotspot.sh --random-pass

# Optional: link to PATH for system-wide access
ln -sf "$(pwd)/quickshare-hotspot.sh" ~/.local/bin/quickshare-hotspot
```

### Options

```text
  --5g, --5ghz         Force 5 GHz band (channel 149 / 36, 80 MHz)
  --2g, --2ghz         Force 2.4 GHz band
  --ssid <name>        Custom hotspot SSID (default: QS-Laptop)
  --pass <password>    Custom WPA2 password (>= 8 chars)
  --random-pass        Generate a random per-session WPA2 password
  --open-quickshare    Force Open QuickShare backend (--rquickshare alias)
  --packet             Force Packet backend (Rust / GTK4)
  --backend <name>     Select backend: auto (default), open-quickshare, packet
  --no-qr              Do not display Wi-Fi QR code
  --qr-margin <N>      Set QR margin width (even integer, default: 2)
  --keep-rules         Keep temporary firewall rules after exit
  -h, --help           Show help
```

## Credits & The Beer Rule

This script is just a wrapper around the actual transfer engines. Full credit goes to the developers who reverse-engineered and maintain the protocol:

- [@ignotusbucius](https://github.com/ignotusbucius) for [Open QuickShare](https://github.com/ignotusbucius/open-quickshare) (full BLE + Wi-Fi Direct Quick Share for Linux)
- Martin André ([@Martichou](https://github.com/Martichou)) for the original [rquickshare](https://github.com/Martichou/rquickshare)
- [@nozwock](https://github.com/nozwock) for [Packet](https://github.com/nozwock/packet)

If this script saved you time, feel free to buy me a coffee. But buy the authors of `Open QuickShare`, `rquickshare`, and `Packet` a beer first—they did the actual hard work.

## License

MIT
