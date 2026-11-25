# quickshare-hotspot

A bash wrapper around [rquickshare](https://github.com/Martichou/rquickshare) and [Packet](https://github.com/nozwock/packet) that sets up a temporary 5 GHz Wi-Fi hotspot on Linux for direct peer-to-peer file transfers with Android devices.

## Purpose

Quick Share on Linux typically requires both devices to be connected to the same Wi-Fi network. When no router is available, or when you want a direct link without network congestion, you have to manually configure a hotspot, adjust firewall rules, launch the transfer client, and tear everything down afterward.

This script automates that entire workflow:
1. Spins up a 5 GHz hotspot (channel 149 / 36, 80 MHz width) via NetworkManager.
2. Opens temporary firewall rules if UFW or `firewalld` is active.
3. Generates a compact terminal QR code for fast phone connection.
4. Launches `rquickshare` or `packet` and displays a real-time transfer dashboard (with LNA clipping warning if the phone is too close).
5. On `Ctrl+C`, terminates the backend, removes the hotspot, cleans up firewall rules, and reconnects to your previous Wi-Fi.

## Requirements

- Linux with `NetworkManager` (`nmcli`)
- Wi-Fi card supporting AP mode
- `qrencode` (optional, for QR display)
- Either backend installed:
  - `rquickshare` (available in CachyOS repos or AUR: `r-quick-share`)
  - `packet` (available on AUR: `packet` or Flathub: `io.github.nozwock.Packet`)

## Usage

```bash
chmod +x quickshare-hotspot.sh
./quickshare-hotspot.sh

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
  --rquickshare        Force rquickshare backend
  --packet             Force Packet backend (Rust / GTK4)
  --backend <name>     Select backend: auto (default), rquickshare, packet
  --no-qr              Do not display Wi-Fi QR code
  --qr-margin <N>      Set QR margin width (even integer, default: 2)
  --keep-rules         Keep temporary firewall rules after exit
  -h, --help           Show help
```

## Credits & The Beer Rule

This script is just a wrapper around the actual transfer engines. Full credit goes to the developers who reverse-engineered the protocol:

- Martin André ([@Martichou](https://github.com/Martichou)) for [rquickshare](https://github.com/Martichou/rquickshare)
- [@nozwock](https://github.com/nozwock) for [Packet](https://github.com/nozwock/packet)

If this script saved you time, feel free to buy me a coffee. But buy the authors of `rquickshare` and `Packet` a beer first—they did the actual hard work.

## License

MIT
