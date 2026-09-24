#!/usr/bin/env bash
#
# quickshare-hotspot.sh — One-command Quick Share via Linux Wi-Fi hotspot
#
# Creates a temporary Wi-Fi hotspot on this machine, configures the firewall,
# and launches rquickshare or Packet. Any phone with Quick Share support can connect
# and transfer files at full local Wi-Fi speed — no router needed.
#
# Usage:
#   ./quickshare-hotspot.sh              # Auto backend (favours native rquickshare)
#   ./quickshare-hotspot.sh --packet     # Force Packet backend (Rust / GTK4)
#   ./quickshare-hotspot.sh --rquickshare# Force rquickshare backend
#   ./quickshare-hotspot.sh --keep-rules # Keep UFW rules after exit
#
# Press Ctrl+C when done to cleanly restore previous state.

set -uo pipefail
# NOTE: We intentionally do NOT use 'set -e' because many commands in this
# script are expected to fail (nmcli probing, pgrep, etc.) and 'set -e' would
# cause the script to exit silently, triggering cleanup that kills the hotspot.

# ── Configuration ─────────────────────────────────────────────────────────────
HOTSPOT_SSID="QS-Laptop"
HOTSPOT_PASS="quickshare24"        # WPA requires >= 8 chars
HOTSPOT_CON="qs-hotspot"           # NM connection profile name (internal)
HOTSPOT_SUBNET="10.42.0.0/24"     # NM default for shared connections
RQS_BIN="/usr/bin/rquickshare"
BACKEND="auto"                     # "auto" (favours rquickshare), "rquickshare", or "packet"
SELECTED_BACKEND=""
APP_CMD=""
APP_NAME=""
IS_FLATPAK=false
UFW_RULE_COMMENT="qs-hotspot-temp"
TRANSFER_THRESHOLD=100000          # bytes/sec floor for "actively transferring"
IDLE_CONFIRM_TICKS=3               # ticks of low speed before closing a burst
SHOW_QR=true
QR_MARGIN=2                        # QR quiet zone: 2 = balanced & fully framed (17 lines), 4 = large
HAS_UFW=false
ADDED_UFW_RULE=false
HOTSPOT_CREATED=false
WIFI_IFACE=""
PREV_WIFI=""
RQS_PID=""
RQS_LOG=""
CLEANED_UP=false

# ── Argument parsing ─────────────────────────────────────────────────────────
KEEP_RULES=false
FORCE_BAND=""
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-rules)  KEEP_RULES=true; shift ;;
        --2g|--2ghz)   FORCE_BAND="2"; shift ;;
        --5g|--5ghz)   FORCE_BAND="5"; shift ;;
        --rquickshare) BACKEND="rquickshare"; shift ;;
        --packet)      BACKEND="packet"; shift ;;
        --no-qr)       SHOW_QR=false; shift ;;
        --qr-margin)
            if [ -n "${2:-}" ]; then
                QR_MARGIN="$2"
                shift 2
            else
                echo "[ERROR] --qr-margin requires a number (e.g. 1, 2, 4)" >&2
                exit 1
            fi
            ;;
        --qr-margin=*)
            QR_MARGIN="${1#*=}"
            shift
            ;;
        --backend)
            if [ -n "${2:-}" ]; then
                BACKEND="$2"
                shift 2
            else
                echo "[ERROR] --backend requires an argument (auto, rquickshare, packet)" >&2
                exit 1
            fi
            ;;
        --backend=*)
            BACKEND="${1#*=}"
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \{0,1\}//; p }' "$0"
            echo "Options:"
            echo "  --5g, --5ghz         Force 5 GHz band"
            echo "  --2g, --2ghz         Force 2.4 GHz band"
            echo "  --rquickshare        Use rquickshare backend (CachyOS native)"
            echo "  --packet             Use Packet backend (Rust / GTK4)"
            echo "  --backend <name>     Select backend: auto (default), rquickshare, packet"
            echo "  --no-qr              Do not display Wi-Fi QR code"
            echo "  --qr-margin <N>      Set QR margin width (default: 2, balanced)"
            echo "  --keep-rules         Keep UFW rules after exit"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_CYAN="\033[36m"
C_BCYAN="\033[1;36m"
C_GREEN="\033[32m"
C_BGREEN="\033[1;32m"
C_YELLOW="\033[33m"
C_BYELLOW="\033[1;33m"
C_WHITE="\033[37m"
C_BWHITE="\033[1;37m"

# ── Preflight checks ────────────────────────────────────────────────────────
preflight() {
    local missing=()
    command -v nmcli >/dev/null 2>&1 || missing+=("nmcli (NetworkManager)")

    case "$BACKEND" in
        auto)
            # Favour rquickshare because it is natively packaged on CachyOS
            if [ -x "$RQS_BIN" ] || command -v rquickshare >/dev/null 2>&1; then
                SELECTED_BACKEND="rquickshare"
                APP_CMD="${RQS_BIN:-rquickshare}"
                APP_NAME="rquickshare"
            elif command -v packet >/dev/null 2>&1; then
                SELECTED_BACKEND="packet"
                APP_CMD="packet"
                APP_NAME="Packet"
            elif command -v flatpak >/dev/null 2>&1 && flatpak info io.github.nozwock.Packet >/dev/null 2>&1; then
                SELECTED_BACKEND="packet"
                APP_CMD="flatpak run io.github.nozwock.Packet"
                APP_NAME="Packet (Flatpak)"
                IS_FLATPAK=true
            else
                missing+=("Quick Share backend: 'rquickshare' (paru -S r-quick-share) or 'packet' (paru -S packet)")
            fi
            ;;
        rquickshare)
            if [ -x "$RQS_BIN" ] || command -v rquickshare >/dev/null 2>&1; then
                SELECTED_BACKEND="rquickshare"
                APP_CMD="${RQS_BIN:-rquickshare}"
                APP_NAME="rquickshare"
            else
                missing+=("rquickshare ($RQS_BIN) - install with 'paru -S r-quick-share'")
            fi
            ;;
        packet)
            if command -v packet >/dev/null 2>&1; then
                SELECTED_BACKEND="packet"
                APP_CMD="packet"
                APP_NAME="Packet"
            elif command -v flatpak >/dev/null 2>&1 && flatpak info io.github.nozwock.Packet >/dev/null 2>&1; then
                SELECTED_BACKEND="packet"
                APP_CMD="flatpak run io.github.nozwock.Packet"
                APP_NAME="Packet (Flatpak)"
                IS_FLATPAK=true
            else
                missing+=("packet - install with 'paru -S packet' or 'flatpak install flathub io.github.nozwock.Packet'")
            fi
            ;;
        *)
            die "Invalid backend '$BACKEND'. Choose 'auto', 'rquickshare', or 'packet'."
            ;;
    esac

    if (( ${#missing[@]} )); then
        echo "[ERROR] Missing required tools:" >&2
        printf "  - %s\n" "${missing[@]}" >&2
        exit 1
    fi

    # Auto-detect Wi-Fi interface via nmcli (reliable), fallback to iw dev
    WIFI_IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
    if [ -z "$WIFI_IFACE" ]; then
        for _try in 1 2 3; do
            WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
            [ -n "$WIFI_IFACE" ] && break
            sleep 1
        done
    fi
    [ -n "$WIFI_IFACE" ] || die "No Wi-Fi interface found"

    # Verify AP mode support via nmcli D-Bus properties first (never flakes), fallback to iw list
    local ap_ok=false
    if [ "$(nmcli -g WIFI-PROPERTIES.AP device show "$WIFI_IFACE" 2>/dev/null)" = "yes" ]; then
        ap_ok=true
    else
        for _try in 1 2 3; do
            if iw list 2>/dev/null | grep -q "\* AP"; then
                ap_ok=true
                break
            fi
            sleep 1
        done
    fi
    [ "$ap_ok" = true ] \
        || die "Wi-Fi adapter ($WIFI_IFACE) does not support AP (hotspot) mode"

    # Detect ufw
    HAS_UFW=false
    if command -v ufw >/dev/null 2>&1; then
        if sudo ufw status 2>/dev/null | head -1 | grep -q "active"; then
            HAS_UFW=true
        fi
    fi

    # Prompt for sudo early if we need it
    if [ "$HAS_UFW" = true ]; then
        sudo -v || die "sudo access required for firewall configuration"
    fi
}

# ── State tracking ───────────────────────────────────────────────────────────
RQS_PID=""
RQS_LOG=""
PREV_WIFI=""
ADDED_UFW_RULE=false
CLEANED_UP=false

# ── Cleanup (runs on Ctrl+C, SIGTERM, or normal exit) ────────────────────────
cleanup() {
    # Unset traps to prevent recursion
    trap - INT TERM EXIT
    [ "$CLEANED_UP" = true ] && exit 0
    CLEANED_UP=true

    # Restore terminal cursor
    tput cnorm 2>/dev/null || true
    echo ""

    info "Shutting down..."

    # 1. Stop backend launched by this script
    if [ -n "$RQS_PID" ] && kill -0 "$RQS_PID" 2>/dev/null; then
        kill "$RQS_PID" 2>/dev/null || true
        wait "$RQS_PID" 2>/dev/null || true
        if [ "$IS_FLATPAK" = true ]; then
            flatpak kill io.github.nozwock.Packet 2>/dev/null || true
        fi
        echo "  - $APP_NAME stopped"
    fi
    # Keep the launch log only if it actually has content worth checking.
    if [ -n "$RQS_LOG" ] && [ -s "$RQS_LOG" ]; then
        echo "  - $APP_NAME log kept at: $RQS_LOG"
    elif [ -n "$RQS_LOG" ]; then
        rm -f "$RQS_LOG" 2>/dev/null || true
    fi
    rm -f "/tmp/.qs_hname.$$" 2>/dev/null || true

    # 2. Tear down hotspot
    if [ "$HOTSPOT_CREATED" = true ]; then
        nmcli con down "$HOTSPOT_CON" >/dev/null 2>&1 || true
        nmcli con delete "$HOTSPOT_CON" >/dev/null 2>&1 || true
        echo "  - Hotspot removed"
    fi

    # 3. Remove temporary UFW rules (unless --keep-rules)
    if [ "$HAS_UFW" = true ] && [ "$KEEP_RULES" = false ]; then
        if [ "$ADDED_UFW_RULE" = true ] && [ -n "$WIFI_IFACE" ]; then
            sudo ufw delete allow in on "$WIFI_IFACE" >/dev/null 2>&1 || true
        fi
        # Clean up legacy rules if any were left behind from older runs
        sudo ufw delete allow from "$HOTSPOT_SUBNET" >/dev/null 2>&1 || true
        sudo ufw delete allow 5353/udp >/dev/null 2>&1 || true
        sudo ufw reload >/dev/null 2>&1 || true
        echo "  - Temporary firewall rules removed"
    fi

    # 4. Reconnect to previous Wi-Fi
    if [ -n "$PREV_WIFI" ]; then
        echo "  - Reconnecting to '$PREV_WIFI'..."
        nmcli con up "$PREV_WIFI" >/dev/null 2>&1 || true
    fi

    if [ "$HOTSPOT_CREATED" = true ]; then
        ok "Cleanup complete."
    fi
    exit 0
}
trap cleanup INT TERM EXIT

# ── Main ─────────────────────────────────────────────────────────────────────

echo "┌──────────────────────────────────────────────────┐"
echo "│  QuickShare Hotspot                              │"
echo "│  High-Speed Direct Wi-Fi for Android Quick Share │"
echo "└──────────────────────────────────────────────────┘"
echo ""

preflight

# 1. Save current Wi-Fi connection name (to restore later)
PREV_WIFI=$(nmcli -t -f NAME,DEVICE con show --active \
    | grep ":${WIFI_IFACE}$" | cut -d: -f1) || true
info "Current Wi-Fi: ${PREV_WIFI:-(none)}"

# 2. Clean up stale hotspot from a previous crashed run
nmcli con down "$HOTSPOT_CON" 2>/dev/null || true
nmcli con delete "$HOTSPOT_CON" 2>/dev/null || true

# 3. Stop any existing backend (it needs to restart to bind the hotspot interface)
if [ "$SELECTED_BACKEND" = "rquickshare" ]; then
    if pgrep -f "rquickshare" >/dev/null 2>&1; then
        info "Stopping existing rquickshare..."
        pkill -f "rquickshare" 2>/dev/null || true
        sleep 2
    fi
elif [ "$SELECTED_BACKEND" = "packet" ]; then
    local_stopped=false
    if pgrep -x "packet" >/dev/null 2>&1; then
        info "Stopping existing Packet..."
        pkill -x "packet" 2>/dev/null || true
        local_stopped=true
    fi
    if command -v flatpak >/dev/null 2>&1 && flatpak ps 2>/dev/null | grep -q "io.github.nozwock.Packet"; then
        info "Stopping running Flatpak Packet..."
        flatpak kill io.github.nozwock.Packet 2>/dev/null || true
        local_stopped=true
    fi
    [ "$local_stopped" = true ] && sleep 2
fi

# Give the interface time to stabilize after cleanup
sleep 1

# 4. Configure firewall (only if ufw is active)
if [ "$HAS_UFW" = true ]; then
    info "Configuring firewall for hotspot on $WIFI_IFACE..."

    # Allow all incoming packets on the hotspot interface.
    # This is required so:
    #   1. DHCP discover (UDP 67 from 0.0.0.0) is NOT blocked by UFW default deny policy
    #   2. DNS (53), mDNS (5353), and rquickshare dynamic transfer ports are allowed
    if ! sudo ufw status | grep -q "${WIFI_IFACE}.*ALLOW"; then
        sudo ufw allow in on "$WIFI_IFACE" comment "$UFW_RULE_COMMENT" >/dev/null
        ADDED_UFW_RULE=true
    fi

    sudo ufw reload >/dev/null
    ok "Firewall ready (traffic on $WIFI_IFACE allowed)"
fi

# 5. Create Wi-Fi hotspot
#    Strategy: use `nmcli connection add` with explicit channel to avoid
#    the "no IR" restriction on most 5 GHz channels (Intel Wi-Fi drivers
#    with self-managed regulatory often block AP on channels 36-140).
#    Channels 149-165 (UNII-3) are typically allowed for AP mode.
#    ipv4.method=shared ensures NetworkManager starts its built-in DHCP
#    server (dnsmasq) so phones can obtain an IP address.
info "Starting Wi-Fi hotspot on $WIFI_IFACE..."
BAND_USED=""

# Configure candidate band/channel attempts
# Note: NetworkManager defaults wifi.channel-width to 0 (auto = 20 MHz safest/smallest),
# which caps throughput at ~15 MB/s. Explicitly setting width=80 enables full 802.11ac/ax
# speed (up to 866-1201 Mbps physical rate -> 60-100+ MB/s real transfer).
HOTSPOT_ATTEMPTS=()
if [ "$FORCE_BAND" = "2" ]; then
    HOTSPOT_ATTEMPTS=("2.4GHz-auto bg 0 0")
elif [ "$FORCE_BAND" = "5" ]; then
    HOTSPOT_ATTEMPTS=(
        "5GHz-ch149-80MHz a 149 80"
        "5GHz-ch149-40MHz a 149 40"
        "5GHz-ch149       a 149 0"
        "5GHz-ch36        a 36  0"
    )
else
    # Default: Try 5GHz on UNII-3 channel 149 with 80MHz width, then 40MHz, 20MHz/auto, then 2.4GHz
    HOTSPOT_ATTEMPTS=(
        "5GHz-ch149-80MHz a 149 80"
        "5GHz-ch149-40MHz a 149 40"
        "5GHz-ch149       a 149 0"
        "2.4GHz-auto      bg 0   0"
    )
fi

for attempt in "${HOTSPOT_ATTEMPTS[@]}"; do
    read -r label band channel width <<< "$attempt"
    info "  Trying $label (band=$band, channel=$channel, width=${width:-auto})..."

    # Remove any leftover from a failed attempt
    nmcli con delete "$HOTSPOT_CON" 2>/dev/null || true

    # Build the connection profile with strict WPA2-RSN/CCMP for mobile compatibility
    add_args=(
        type wifi
        ifname "$WIFI_IFACE"
        con-name "$HOTSPOT_CON"
        autoconnect no
        wifi.mode ap
        wifi.band "$band"
        wifi.ssid "$HOTSPOT_SSID"
        wifi.powersave 2
        wifi-sec.key-mgmt wpa-psk
        wifi-sec.proto rsn
        wifi-sec.pairwise ccmp
        wifi-sec.psk "$HOTSPOT_PASS"
        ipv4.method shared
        ipv4.addresses "10.42.0.1/24"
        ipv6.method ignore
    )
    # Only set channel if non-zero (0 = let NM pick)
    if [ "${channel:-0}" -gt 0 ] 2>/dev/null; then
        add_args+=( wifi.channel "$channel" )
        if [ "${width:-0}" -gt 0 ] 2>/dev/null; then
            add_args+=( wifi.channel-width "$width" )
        fi
    fi

    if nmcli connection add "${add_args[@]}" 2>/dev/null \
       && nmcli connection up "$HOTSPOT_CON" 2>/dev/null; then
        # nmcli can report success even when the driver silently drops back
        # out of AP mode a moment later (seen on some Intel cards under
        # regulatory constraints), so confirm the interface is actually
        # in AP mode before declaring this attempt a success.
        sleep 1
        if iw dev "$WIFI_IFACE" info 2>/dev/null | grep -q "type AP"; then
            HOTSPOT_CREATED=true
            # Turn off Wi-Fi power saving on the interface for maximum burst throughput
            iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true

            act_ch=$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/channel/ {print $2}')
            act_width=$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk -F'width: ' 'NF>1 {split($2, a, ","); print a[1]}')
            case "$band" in
                a)
                    if [ -n "$act_ch" ]; then
                        BAND_USED="5 GHz (ch $act_ch${act_width:+, $act_width})"
                    else
                        BAND_USED="5 GHz (ch $channel)"
                    fi
                    ;;
                bg)
                    if [ -n "$act_ch" ]; then
                        BAND_USED="2.4 GHz (ch $act_ch${act_width:+, $act_width})"
                    else
                        BAND_USED="2.4 GHz"
                    fi
                    ;;
            esac
            break
        else
            info "  ↳ $label reported up but interface isn't in AP mode, trying next..."
            nmcli con down "$HOTSPOT_CON" 2>/dev/null || true
            nmcli con delete "$HOTSPOT_CON" 2>/dev/null || true
        fi
    else
        info "  ↳ $label failed, trying next..."
        nmcli con delete "$HOTSPOT_CON" 2>/dev/null || true
    fi
done

[ -n "$BAND_USED" ] || die "Failed to create hotspot on any band. Is $WIFI_IFACE blocked or in use?"

# Wait briefly for interface stabilization
sleep 1
ok "Hotspot '$HOTSPOT_SSID' active ($BAND_USED)"

# 6. Show connection credentials (+ QR code if qrencode is available)
WIFI_QR_STRING="WIFI:T:WPA;S:${HOTSPOT_SSID};P:${HOTSPOT_PASS};;"

print_credentials() {
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 80)

    if [ "$SHOW_QR" != true ] || ! command -v qrencode >/dev/null 2>&1; then
        echo ""
        printf "  SSID:      %s\n" "$HOTSPOT_SSID"
        printf "  Password:  %s\n" "$HOTSPOT_PASS"
        printf "  Band:      %s\n" "$BAND_USED"
        return
    fi

    local qr_raw
    qr_raw=$(qrencode -t ANSIUTF8 -m "$QR_MARGIN" "$WIFI_QR_STRING" 2>/dev/null)
    if [ -z "$qr_raw" ]; then
        echo ""
        printf "  SSID:      %s\n" "$HOTSPOT_SSID"
        printf "  Password:  %s\n" "$HOTSPOT_PASS"
        printf "  Band:      %s\n" "$BAND_USED"
        return
    fi

    # Side-by-side display if terminal has enough horizontal room (>= 65 cols)
    if (( term_cols >= 65 )); then
        echo ""
        local info_lines=(
            ""
            "  ${C_BCYAN}Hotspot Credentials${C_RESET}"
            "  ───────────────────"
            "  ${C_BOLD}SSID:${C_RESET}      $HOTSPOT_SSID"
            "  ${C_BOLD}Password:${C_RESET}  $HOTSPOT_PASS"
            "  ${C_BOLD}Band:${C_RESET}      $BAND_USED"
            "  ${C_BOLD}Backend:${C_RESET}   $APP_NAME"
            ""
            "  ${C_DIM}Scan QR to connect Wi-Fi${C_RESET}"
        )
        local i=0
        while IFS= read -r qr_line; do
            local text="${info_lines[$i]:-}"
            printf "  %s  %b\n" "$qr_line" "$text"
            ((i++))
        done <<< "$qr_raw"
    else
        echo ""
        echo "$qr_raw" | sed "s/^/  /"
        echo ""
        printf "  SSID:      %s\n" "$HOTSPOT_SSID"
        printf "  Password:  %s\n" "$HOTSPOT_PASS"
        printf "  Band:      %s\n" "$BAND_USED"
        printf "  Backend:   %s\n" "$APP_NAME"
    fi
}

print_credentials

# 7. Launch Quick Share backend
#    stdout/stderr go to a temp log instead of /dev/null so a silent
#    launch failure is still diagnosable afterward.
echo ""
info "Starting $APP_NAME (backend: $SELECTED_BACKEND)..."
RQS_LOG=$(mktemp -t "quickshare-${SELECTED_BACKEND}.XXXXXX.log")
if [ "$IS_FLATPAK" = true ]; then
    flatpak run io.github.nozwock.Packet >"$RQS_LOG" 2>&1 &
    RQS_PID=$!
else
    "$APP_CMD" >"$RQS_LOG" 2>&1 &
    RQS_PID=$!
fi
sleep 2

if ! kill -0 "$RQS_PID" 2>/dev/null; then
    echo "[WARN] $APP_NAME may have failed to start. Continuing anyway..."
    echo "  You can start it manually: $APP_CMD &"
    [ -s "$RQS_LOG" ] && echo "  Launch log: $RQS_LOG"
    RQS_PID=""
else
    ok "$APP_NAME running (PID $RQS_PID)"
fi

# 8. Live dashboard: bandwidth, client, session duration
echo ""
tput civis 2>/dev/null || true

fmt_bytes() {
    local b=$1
    if (( b >= 1073741824 )); then
        local g=$(( b / 1073741824 ))
        local rem=$(( (b % 1073741824) * 10 / 1073741824 ))
        echo "${g}.${rem} GB"
    elif (( b >= 1048576 )); then
        local m=$(( b / 1048576 ))
        local rem=$(( (b % 1048576) * 10 / 1048576 ))
        echo "${m}.${rem} MB"
    elif (( b >= 1024 )); then
        local k=$(( b / 1024 ))
        local rem=$(( (b % 1024) * 10 / 1024 ))
        echo "${k}.${rem} KB"
    else
        echo "${b} B"
    fi
}

fmt_duration() {
    local s=$1
    printf "%02d:%02d:%02d" $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
}

fmt_duration_short() {
    local ms=$1
    if (( ms < 60000 )); then
        local sec=$(( ms / 1000 ))
        local tenths=$(( (ms % 1000) / 100 ))
        echo "${sec}.${tenths}s"
    else
        local sec=$(( ms / 1000 ))
        printf "%dm %02ds" $(( sec / 60 )) $(( sec % 60 ))
    fi
}


RX_STAT="/sys/class/net/$WIFI_IFACE/statistics/rx_bytes"
TX_STAT="/sys/class/net/$WIFI_IFACE/statistics/tx_bytes"

init_rx=0
init_tx=0
read -r init_rx < "$RX_STAT" 2>/dev/null || init_rx=0
read -r init_tx < "$TX_STAT" 2>/dev/null || init_tx=0
prev_rx=$init_rx
prev_tx=$init_tx
prev_time=$(date +%s%N)
start_time=$(date +%s)

# Peaks and active averages are tracked per-direction
rx_peak=0
tx_peak=0
session_rx_avg=0
session_tx_avg=0
burst_rx_avg=0
burst_tx_avg=0
active_rx_ns=0
active_tx_ns=0
burst_rx=0
burst_tx=0
burst_rx_peak=0
burst_tx_peak=0
burst_start_time=0
transfer_active=false
idle_ticks=0

# Client identity tracking
station_mac=""
client_ip=""
client_display=""
cached_hname=""

# Dashboard in-place rendering engine:
# Tracks the exact number of lines currently drawn on screen (prev_drawn_lines).
# To update: moves up by prev_drawn_lines, clears down to bottom (\033[J), and redraws.
# When a transfer completes: log_permanent erases the dashboard, prints the completed
# log into terminal scrollback, and leaves the new dashboard to draw cleanly below it.
prev_drawn_lines=0

render_dashboard() {
    local -a lines=("$@")
    if (( prev_drawn_lines > 0 )); then
        printf '\033[%dA\033[J' "$prev_drawn_lines"
    fi
    printf '%s\n' "${lines[@]}"
    prev_drawn_lines=${#lines[@]}
}

log_permanent() {
    local msg="$1"
    if (( prev_drawn_lines > 0 )); then
        printf '\033[%dA\033[J' "$prev_drawn_lines"
    fi
    printf '%s\n' "$msg"
    prev_drawn_lines=0
}

while true; do
    if [ -n "$RQS_PID" ] && ! kill -0 "$RQS_PID" 2>/dev/null; then
        log_permanent "[INFO] $APP_NAME has stopped."
        break
    fi

    curr_time=$(date +%s%N)
    curr_rx=0
    curr_tx=0
    read -r curr_rx < "$RX_STAT" 2>/dev/null || curr_rx=0
    read -r curr_tx < "$TX_STAT" 2>/dev/null || curr_tx=0

    dt_ns=$(( curr_time - prev_time ))
    [ "$dt_ns" -le 0 ] && dt_ns=1000000000

    rx_diff=$(( curr_rx > prev_rx ? curr_rx - prev_rx : 0 ))
    tx_diff=$(( curr_tx > prev_tx ? curr_tx - prev_tx : 0 ))
    prev_rx=$curr_rx
    prev_tx=$curr_tx
    prev_time=$curr_time

    rx_speed=$(( rx_diff * 1000000000 / dt_ns ))
    tx_speed=$(( tx_diff * 1000000000 / dt_ns ))
    total_rx=$(( curr_rx >= init_rx ? curr_rx - init_rx : 0 ))
    total_tx=$(( curr_tx >= init_tx ? curr_tx - init_tx : 0 ))

    # Transfer state machine & per-direction peak and average tracking
    if (( rx_speed >= TRANSFER_THRESHOLD || tx_speed >= TRANSFER_THRESHOLD )); then
        if [ "$transfer_active" = false ]; then
            transfer_active=true
            burst_start_time=$(( curr_time - dt_ns ))
            burst_rx=0
            burst_tx=0
            burst_rx_peak=0
            burst_tx_peak=0
        fi
        idle_ticks=0
        burst_rx=$(( burst_rx + rx_diff ))
        burst_tx=$(( burst_tx + tx_diff ))
        (( rx_speed > burst_rx_peak )) && burst_rx_peak=$rx_speed
        (( tx_speed > burst_tx_peak )) && burst_tx_peak=$tx_speed
        (( rx_speed > rx_peak )) && rx_peak=$rx_speed
        (( tx_speed > tx_peak )) && tx_peak=$tx_speed

        if (( rx_speed >= TRANSFER_THRESHOLD )); then
            active_rx_ns=$(( active_rx_ns + dt_ns ))
            active_rx_ms=$(( active_rx_ns / 1000000 ))
            session_rx_avg=$(( total_rx * 1000 / (active_rx_ms > 0 ? active_rx_ms : 1) ))
            burst_duration_ns=$(( curr_time - burst_start_time ))
            burst_duration_ms=$(( burst_duration_ns / 1000000 ))
            burst_rx_avg=$(( burst_rx * 1000 / (burst_duration_ms > 0 ? burst_duration_ms : 1) ))
        fi
        if (( tx_speed >= TRANSFER_THRESHOLD )); then
            active_tx_ns=$(( active_tx_ns + dt_ns ))
            active_tx_ms=$(( active_tx_ns / 1000000 ))
            session_tx_avg=$(( total_tx * 1000 / (active_tx_ms > 0 ? active_tx_ms : 1) ))
            burst_duration_ns=$(( curr_time - burst_start_time ))
            burst_duration_ms=$(( burst_duration_ns / 1000000 ))
            burst_tx_avg=$(( burst_tx * 1000 / (burst_duration_ms > 0 ? burst_duration_ms : 1) ))
        fi
    elif [ "$transfer_active" = true ]; then
        burst_rx=$(( burst_rx + rx_diff ))
        burst_tx=$(( burst_tx + tx_diff ))
        idle_ticks=$(( idle_ticks + 1 ))
        if (( idle_ticks >= IDLE_CONFIRM_TICKS )); then
            transfer_active=false
            idle_ticks=0
            burst_duration_ns=$(( curr_time - burst_start_time ))
            actual_burst_ns=$(( burst_duration_ns - IDLE_CONFIRM_TICKS * dt_ns ))
            [ "$actual_burst_ns" -le 100000000 ] && actual_burst_ns=100000000
            burst_ms=$(( actual_burst_ns / 1000000 ))

            burst_rx_avg=$(( burst_rx * 1000 / (burst_ms > 0 ? burst_ms : 1) ))
            burst_tx_avg=$(( burst_tx * 1000 / (burst_ms > 0 ? burst_ms : 1) ))

            if (( burst_rx + burst_tx > 0 )); then
                comp_parts=()
                if (( burst_rx > 0 )); then
                    comp_parts+=( "$(printf "↓ %s (avg %s/s · peak %s/s)" "$(fmt_bytes "$burst_rx")" "$(fmt_bytes "$burst_rx_avg")" "$(fmt_bytes "$burst_rx_peak")")" )
                fi
                if (( burst_tx > 0 )); then
                    comp_parts+=( "$(printf "↑ %s (avg %s/s · peak %s/s)" "$(fmt_bytes "$burst_tx")" "$(fmt_bytes "$burst_tx_avg")" "$(fmt_bytes "$burst_tx_peak")")" )
                fi
                log_permanent "$(printf "[+] Transfer completed in %s: %s" "$(fmt_duration_short "$burst_ms")" "${comp_parts[*]}")"
            fi
            burst_rx=0
            burst_tx=0
            burst_rx_peak=0
            burst_tx_peak=0
        fi
    fi

    # Client detection:
    # 1. Cheap check for connected Wi-Fi station MAC + real-time link bitrate & signal
    station_info=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null | awk '
        /Station/ { mac=$2 }
        /signal:/ { sig=$2 }
        /rx bitrate:/ { rx_br=$3 }
        /tx bitrate:/ { tx_br=$3 }
        END {
            br = (rx_br != "" ? rx_br : tx_br)
            sub(/\..*/, "", br)
            if (mac != "") print mac, (br != "" ? br : "-"), (sig != "" ? sig : "-")
        }')

    new_station_mac=""
    link_rate="-"
    link_sig="-"
    if [ -n "$station_info" ]; then
        read -r new_station_mac link_rate link_sig <<< "$station_info"
    fi

    if [ -z "$new_station_mac" ]; then
        station_mac=""
        client_ip=""
        client_display=""
        cached_hname=""
        icon="${C_BYELLOW}○${C_RESET}"
        client_line="Waiting for phone..."
    else
        # Station MAC associated
        if [ "$new_station_mac" != "$station_mac" ]; then
            station_mac="$new_station_mac"
            client_ip=""
            client_display=""
            cached_hname=""
        fi

        # If IP not yet determined, retry lookups across sources until DHCP/ARP populates
        if [ -z "$client_ip" ]; then
            # Check ARP table by MAC
            client_ip=$(awk -v mac="$station_mac" 'tolower($4)==tolower(mac) {print $1; exit}' /proc/net/arp 2>/dev/null)

            # Check ARP table for any 10.42.* address on hotspot interface
            [ -z "$client_ip" ] && client_ip=$(awk -v iface="$WIFI_IFACE" '$6==iface && $1 ~ /^10\.42\./ && $4 != "00:00:00:00:00:00" {print $1; exit}' /proc/net/arp 2>/dev/null)

            # Check active TCP sockets to rquickshare (peer IP in column 5)
            [ -z "$client_ip" ] && client_ip=$(ss -tn dst 10.42.0.0/24 2>/dev/null | awk 'NR>1 {split($5, a, ":"); if (a[1] != "") print a[1]; exit}')

            # Check IP neighbor cache
            [ -z "$client_ip" ] && client_ip=$(ip neigh show dev "$WIFI_IFACE" 2>/dev/null | awk '$1 ~ /^10\.42\./ && !/FAILED|INCOMPLETE/ {print $1; exit}')

            if [ -n "$client_ip" ]; then
                client_display="$client_ip"
                # Resolve hostname asynchronously in background so loop never blocks
                (
                    hname=$(host -W 1 "$client_ip" 10.42.0.1 2>/dev/null | awk '/pointer/ {sub(/\.$/, "", $NF); print $NF; exit}')
                    if [ -n "$hname" ] && [ "$hname" != "$client_ip" ]; then
                        [ ${#hname} -gt 25 ] && hname="${hname:0:22}..."
                        echo "$hname" > "/tmp/.qs_hname.$$"
                    fi
                ) &
            fi
        fi

        # Check if background hostname resolution completed
        if [ -n "$client_ip" ] && [ -f "/tmp/.qs_hname.$$" ]; then
            read -r cached_hname < "/tmp/.qs_hname.$$" 2>/dev/null || true
            rm -f "/tmp/.qs_hname.$$" 2>/dev/null || true
            if [ -n "$cached_hname" ]; then
                client_display="$client_ip ($cached_hname)"
            fi
        fi

        if [ -n "$client_display" ]; then
            icon="${C_BGREEN}●${C_RESET}"
            dev_name="${cached_hname:-$client_ip}"
            [ ${#dev_name} -gt 22 ] && dev_name="${dev_name:0:19}..."
            if [ -n "$link_rate" ] && [ "$link_rate" != "-" ]; then
                client_line="$dev_name · Link: ${link_rate} Mbps (${link_sig}dBm)"
            else
                client_line="$client_display"
            fi
        else
            icon="${C_BYELLOW}◐${C_RESET}"
            client_line="Connecting..."
        fi
    fi

    elapsed=$(( $(date +%s) - start_time ))

    # Prepare Session Totals fields
    if (( total_rx > 0 )); then
        s_rx_tot="$(fmt_bytes "$total_rx")"
        if (( session_rx_avg > 0 )); then
            s_rx_avg="$(fmt_bytes "$session_rx_avg")/s"
        else
            s_rx_avg="-"
        fi
        s_rx_peak="$(fmt_bytes "$rx_peak")/s"
    else
        s_rx_tot="0 B"
        s_rx_avg="-"
        s_rx_peak="-"
    fi

    if (( total_tx > 0 )); then
        s_tx_tot="$(fmt_bytes "$total_tx")"
        if (( session_tx_avg > 0 )); then
            s_tx_avg="$(fmt_bytes "$session_tx_avg")/s"
        else
            s_tx_avg="-"
        fi
        s_tx_peak="$(fmt_bytes "$tx_peak")/s"
    else
        s_tx_tot="0 B"
        s_tx_avg="-"
        s_tx_peak="-"
    fi

    # Prepare Live Transfer fields
    if [ "$transfer_active" = true ]; then
        l_rx_spd="$(fmt_bytes "$rx_speed")/s"
        l_rx_avg="$(fmt_bytes "$burst_rx_avg")/s"
        l_rx_peak="$(fmt_bytes "$burst_rx_peak")/s"
        l_tx_spd="$(fmt_bytes "$tx_speed")/s"
        l_tx_avg="$(fmt_bytes "$burst_tx_avg")/s"
        l_tx_peak="$(fmt_bytes "$burst_tx_peak")/s"
    else
        l_rx_spd="-"
        l_rx_avg="-"
        l_rx_peak="-"
        l_tx_spd="-"
        l_tx_avg="-"
        l_tx_peak="-"
    fi

    # Top border dynamic dashes (always exactly 78 characters total)
    pad_top=$(( 53 - 2 - ${#BAND_USED} ))
    [ "$pad_top" -lt 2 ] && pad_top=2
    printf -v dashes_top "%*s" "$pad_top" ""
    dashes_top="${dashes_top// /─}"

    # Live Transfer section tag dynamic dashes
    if [ "$transfer_active" = true ]; then
        tag_text="[Active]"
        tag_col="${C_BOLD}${C_BGREEN}${tag_text}${C_RESET}"
    else
        tag_text="[Idle]"
        tag_col="${C_DIM}${tag_text}${C_RESET}"
    fi
    pad_tag=$(( 53 - ${#tag_text} ))
    printf -v dashes_tag "%*s" "$pad_tag" ""
    dashes_tag="${dashes_tag// /─}"

    client_line="${client_line:0:48}"

    dash=(
        "$(printf "${C_DIM}╭─${C_RESET} %b ${C_DIM}%s${C_RESET} %b ${C_DIM}─╮${C_RESET}" "${C_BOLD}${C_BCYAN}QUICK SHARE HOTSPOT${C_RESET}" "$dashes_top" "${C_BWHITE}${BAND_USED}${C_RESET}")"
        "$(printf "${C_DIM}│${C_RESET} ${C_DIM}Status:${C_RESET} %b ${C_BWHITE}%-48s${C_RESET} ${C_DIM}Uptime:${C_RESET} ${C_CYAN}%8s${C_RESET} ${C_DIM}│${C_RESET}" "$icon" "$client_line" "$(fmt_duration "$elapsed")")"
        "$(printf "${C_DIM}├─${C_RESET} %b ${C_DIM}───────────────────────────────────────────────────────────┤${C_RESET}" "${C_BOLD}${C_BWHITE}SESSION TOTALS${C_RESET}")"
        "$(printf "${C_DIM}│${C_RESET}   %b ${C_BWHITE}%9s${C_RESET}   ${C_DIM}│  Avg:${C_RESET} ${C_BCYAN}%10s${C_RESET}   ${C_DIM}│  Peak:${C_RESET} ${C_BCYAN}%10s${C_RESET}         ${C_DIM}│${C_RESET}" "${C_BCYAN}↓ Download:${C_RESET}" "$s_rx_tot" "$s_rx_avg" "$s_rx_peak")"
        "$(printf "${C_DIM}│${C_RESET}   %b ${C_BWHITE}%9s${C_RESET}   ${C_DIM}│  Avg:${C_RESET} ${C_BGREEN}%10s${C_RESET}   ${C_DIM}│  Peak:${C_RESET} ${C_BGREEN}%10s${C_RESET}         ${C_DIM}│${C_RESET}" "${C_BGREEN}↑ Upload:${C_RESET}  " "$s_tx_tot" "$s_tx_avg" "$s_tx_peak")"
        "$(printf "${C_DIM}├─${C_RESET} %b ${C_DIM}%s${C_RESET} %b ${C_DIM}─────┤${C_RESET}" "${C_BOLD}${C_BWHITE}LIVE TRANSFER${C_RESET}" "$dashes_tag" "$tag_col")"
    )

    if [ "$transfer_active" = true ]; then
        dash+=(
            "$(printf "${C_DIM}│${C_RESET}   %b ${C_BCYAN}%9s${C_RESET}   ${C_DIM}│  Avg:${C_RESET} ${C_BCYAN}%10s${C_RESET}   ${C_DIM}│  Peak:${C_RESET} ${C_BCYAN}%10s${C_RESET}         ${C_DIM}│${C_RESET}" "${C_BCYAN}↓ Speed:${C_RESET}   " "$l_rx_spd" "$l_rx_avg" "$l_rx_peak")"
            "$(printf "${C_DIM}│${C_RESET}   %b ${C_BGREEN}%9s${C_RESET}   ${C_DIM}│  Avg:${C_RESET} ${C_BGREEN}%10s${C_RESET}   ${C_DIM}│  Peak:${C_RESET} ${C_BGREEN}%10s${C_RESET}         ${C_DIM}│${C_RESET}" "${C_GREEN}↑ Speed:${C_RESET}   " "$l_tx_spd" "$l_tx_avg" "$l_tx_peak")"
        )
    else
        dash+=(
            "$(printf "${C_DIM}│   ↓ Speed:    %9s   │  Avg: %10s   │  Peak: %10s         │${C_RESET}" "$l_rx_spd" "$l_rx_avg" "$l_rx_peak")"
            "$(printf "${C_DIM}│   ↑ Speed:    %9s   │  Avg: %10s   │  Peak: %10s         │${C_RESET}" "$l_tx_spd" "$l_tx_avg" "$l_tx_peak")"
        )
    fi

    dash+=(
        "$(printf "${C_DIM}╰─────────────────────────────────────────────────────── [Ctrl+C to stop] ───╯${C_RESET}")"
    )

    render_dashboard "${dash[@]}"

    sleep 0.5
done