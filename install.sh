#!/bin/bash

###############################################################################
# Cloudflare WARP Proxy Manager  (fixed)
# - Uses warp-cli in proxy mode (SOCKS5 127.0.0.1:10808)
# - Installs Cloudflare WARP (cloudflare-warp) on Debian/Ubuntu systems
# - Provides menu to:
#     * Install / Reinstall WARP
#     * Connect / Disconnect
#     * Show Status
#     * Test Proxy
#     * Change IP (Quick reconnect)
#     * Change IP (New identity / new registration)
#     * Fix MTU (persist via cron @reboot)
#     * Remove WARP
###############################################################################

set -uo pipefail

# ===================== Colors & Version ======================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
VERSION="3.2"

# ===================== Root Check ===========================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root.${NC}"
    echo -e "${YELLOW}Usage: sudo warp-menu${NC}"
    exit 1
fi

# ===================== Basic Checks =========================================

warp_is_installed() {
    command -v warp-cli &>/dev/null
}

warp_is_connected() {
    warp-cli status 2>/dev/null | grep -iq "Connected"
}

# Detect whether this warp-cli build uses the old ("set-mode") or new
# ("mode") sub-command syntax, so we don't silently fail on either version.
warp_cli_syntax() {
    if warp-cli --help 2>/dev/null | grep -qE '^\s*mode\b'; then
        echo "new"
    else
        echo "old"
    fi
}

warp_set_proxy_mode() {
    local syntax
    syntax=$(warp_cli_syntax)
    if [[ "$syntax" == "new" ]]; then
        warp-cli mode proxy
        warp-cli proxy port 10808
    else
        warp-cli set-mode proxy
        warp-cli set-proxy-port 10808
    fi
}

warp_is_registered() {
    warp-cli registration show 2>/dev/null | grep -qiE "account|device"
}

# ===================== IPv6-broken-network fix ==============================
# IMPORTANT: this NEVER touches system-wide IPv6 (no sysctl disable_ipv6).
# Disabling IPv6 at the OS level can drop your SSH session if the box's
# management/console path relies on IPv6 in any way — we ran into exactly
# that on this host.
#
# LESSON LEARNED THE HARD WAY (confirmed via `journalctl -u warp-svc`):
# `warp-cli mode proxy` (the SOCKS5 listener on 10808 that this whole script
# relies on) is HARD-CODED to only work with the MASQUE tunnel protocol.
# Switching to WireGuard to pin a custom endpoint fails immediately with
# error=InvalidKey("Proxy mode only supports MASQUE") — the daemon then
# reports a misleading "Manual Disconnection". So there is no custom
# endpoint / no WireGuard switch here. The only safe, working fix for a
# host with broken IPv6 is: keep protocol=MASQUE, and route Cloudflare's
# own IPv6 block to "unreachable" so MASQUE's happy-eyeballs logic fails
# that path instantly instead of hanging on it.

# Cloudflare's own IPv6 block. We do NOT touch system-wide IPv6 (that broke
# your SSH session before). Instead we tell the kernel this one range is
# "unreachable" so any attempt fails INSTANTLY instead of hanging/timing
# out, letting MASQUE fall back to IPv4 immediately.
warp_blackhole_cf_ipv6() {
    ip -6 route replace unreachable 2606:4700::/32 2>/dev/null
    ( crontab -l 2>/dev/null | grep -vF '2606:4700::/32' ; \
      echo '@reboot ip -6 route replace unreachable 2606:4700::/32 2>/dev/null' ) | crontab -
}

warp_unblackhole_cf_ipv6() {
    ip -6 route del unreachable 2606:4700::/32 2>/dev/null
    ( crontab -l 2>/dev/null | grep -vF '2606:4700::/32' ) | crontab -
}

# Poll warp-cli status instead of a blind sleep, since the handshake can
# take a variable amount of time.
warp_wait_connected() {
    local timeout="${1:-15}"
    local i
    for ((i = 0; i < timeout; i++)); do
        warp_is_connected && return 0
        sleep 1
    done
    return 1
}

warp_fix_ipv6_issue() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}[*] Blackholing Cloudflare's IPv6 range only (route-level, safe, persists on reboot)...${NC}"
    warp_blackhole_cf_ipv6

    echo -e "${CYAN}[*] Clearing any custom endpoint (not supported in proxy mode) and forcing protocol=MASQUE...${NC}"
    warp_disconnect >/dev/null 2>&1
    warp-cli tunnel endpoint reset >/dev/null 2>&1
    warp-cli tunnel protocol set MASQUE

    warp_set_proxy_mode
    warp-cli connect

    if warp_wait_connected 15; then
        local ip
        ip=$(curl -4 -s --max-time 5 --socks5-hostname 127.0.0.1:10808 https://ifconfig.me 2>/dev/null)
        echo -e "${GREEN}[✓] Connected. Exit IP: ${ip:-N/A}${NC}"
        echo -e "${GREEN}[✓] Cloudflare's IPv6 route is now blackholed, so future reconnects won't stall on it.${NC}"
    else
        echo -e "${RED}[!] Still not connected after 15s.${NC}"
        echo -e "${YELLOW}[>] Run: journalctl -u warp-svc --no-pager -n 40   and check the last ERROR line.${NC}"
        return 1
    fi
}

warp_reset_endpoint() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi
    echo -e "${YELLOW}[*] Resetting to Cloudflare's defaults (protocol=MASQUE, no custom endpoint, IPv6 route restored)...${NC}"
    warp_disconnect >/dev/null 2>&1
    warp-cli tunnel endpoint reset >/dev/null 2>&1
    warp-cli tunnel protocol set MASQUE
    warp_unblackhole_cf_ipv6
    warp_set_proxy_mode
    warp-cli connect
    warp_wait_connected 15 >/dev/null 2>&1
    warp_status
}

# ===================== Service Helpers ======================================

ensure_warp_service() {
    if command -v systemctl &>/dev/null; then
        systemctl enable --now warp-svc 2>/dev/null || systemctl restart warp-svc 2>/dev/null
    elif command -v service &>/dev/null; then
        service warp-svc start 2>/dev/null || service warp-svc restart 2>/dev/null
    fi
    sleep 1
}

# ===================== IP / Proxy Helper ====================================

get_warp_ip() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""

    ip=$(curl -4 -s --max-time 5 --socks5-hostname "${proxy_ip}:${proxy_port}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')

    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -s --max-time 5 --socks5-hostname "${proxy_ip}:${proxy_port}" https://ifconfig.me 2>/dev/null)
    fi

    echo "$ip"
}

# ===================== MTU Fix ==============================================

warp_fix_mtu() {
    echo -e "${CYAN}[*] Setting MTU 1350 on all non-loopback interfaces...${NC}"
    local iface
    for iface in $(ls /sys/class/net | grep -v '^lo$'); do
        ip link set dev "$iface" mtu 1350 2>/dev/null \
            && echo -e "  ${GREEN}✓${NC} $iface -> mtu 1350" \
            || echo -e "  ${YELLOW}![skip]${NC} $iface"
    done

    # Persist across reboot via cron, without duplicating the entry
    local cron_line='@reboot for iface in $(ls /sys/class/net | grep -v "^lo$"); do ip link set dev "$iface" mtu 1350; done'
    ( crontab -l 2>/dev/null | grep -vF 'mtu 1350' ; echo "$cron_line" ) | crontab -
    echo -e "${GREEN}[✓] MTU fix applied and persisted via @reboot cron job.${NC}"
}

# ===================== Core Actions =========================================

warp_install() {
    if warp_is_installed; then
        echo -e "${GREEN}[INFO] Cloudflare WARP is already installed.${NC}"
        read -rp "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${CYAN}[+] Installing Cloudflare WARP (warp-cli)...${NC}"

    # Install prerequisites FIRST so lsb_release actually exists before we call it
    if ! apt-get update; then
        echo -e "${RED}[ERROR] apt-get update failed. Check your network/apt sources.${NC}"
        return 1
    fi
    if ! apt-get install -y curl gpg lsb-release apt-transport-https ca-certificates; then
        echo -e "${RED}[ERROR] Failed to install prerequisites.${NC}"
        return 1
    fi

    # Determine distribution codename, whitelist-style (safer than blacklisting)
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    case "$codename" in
        focal|jammy)
            : # natively supported by Cloudflare's repo, keep as-is
            ;;
        *)
            echo -e "${YELLOW}[INFO] '$codename' has no official Cloudflare repo yet; falling back to 'jammy' packages.${NC}"
            codename="jammy"
            ;;
    esac

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    if [[ ! -s /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg ]]; then
        echo -e "${RED}[ERROR] Failed to fetch/import Cloudflare GPG key.${NC}"
        return 1
    fi

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    if ! apt-get update; then
        echo -e "${RED}[ERROR] apt-get update failed after adding Cloudflare repo.${NC}"
        return 1
    fi
    if ! apt-get install -y cloudflare-warp; then
        echo -e "${RED}[ERROR] Failed to install cloudflare-warp package.${NC}"
        return 1
    fi

    ensure_warp_service
    echo -e "${GREEN}[✓] Cloudflare WARP installed successfully.${NC}"

    warp_fix_mtu

    echo -e "${CYAN}[*] Verifying tunnel connectivity (auto-selects an IPv4 endpoint if needed)...${NC}"
    warp_connect
    if ! warp_is_connected; then
        echo -e "${YELLOW}[!] Default connect failed or unstable, retrying with IPv4 pinning...${NC}"
        warp_fix_ipv6_issue
    fi
}

warp_connect() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service
    echo -e "${BLUE}[*] Connecting to Cloudflare WARP...${NC}"

    if ! warp_is_registered; then
        echo -e "${YELLOW}[INFO] Creating new WARP account registration...${NC}"
        warp-cli registration new
        sleep 1
    fi

    warp_set_proxy_mode
    warp-cli connect
    sleep 3

    if warp_is_connected; then
        echo -e "${GREEN}[✓] Connected to WARP successfully.${NC}"
    else
        echo -e "${RED}[!] Failed to connect to WARP. Run option 4 for details.${NC}"
    fi
}

warp_disconnect() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi
    echo -e "${YELLOW}[*] Disconnecting WARP...${NC}"
    warp-cli disconnect 2>/dev/null || true
    sleep 1
}

warp_status() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}===== WARP Status =====${NC}"
    warp-cli status

    if warp_is_connected; then
        local ip
        ip=$(get_warp_ip)
        [[ -n "$ip" ]] && echo -e "${GREEN}Proxy IP (via WARP): $ip${NC}"
    fi
}

warp_test_proxy() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    echo -e "${CYAN}[*] Testing SOCKS5 proxy 127.0.0.1:10808 ...${NC}"

    if ! warp_is_connected; then
        echo -e "${RED}[ERROR] WARP is not connected. Please connect first.${NC}"
        return 1
    fi

    local ip
    ip=$(get_warp_ip)
    if [[ -n "$ip" ]]; then
        echo -e "${GREEN}[✓] Proxy is working. Outgoing IP: $ip${NC}"
        if curl -s --max-time 5 --socks5-hostname 127.0.0.1:10808 https://www.cloudflare.com &>/dev/null; then
            echo -e "${GREEN}[✓] Internet connectivity via WARP is OK.${NC}"
        else
            echo -e "${YELLOW}[!] Connectivity test failed (Cloudflare site not reachable).${NC}"
        fi
    else
        echo -e "${RED}[!] Failed to detect outgoing IP. Proxy test failed.${NC}"
    fi
}

warp_remove() {
    echo -e "${RED}[WARNING] This will remove Cloudflare WARP from your system.${NC}"
    read -rp "Are you sure you want to continue? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if warp_is_installed; then
        warp_disconnect
    fi

    apt-get remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt-get autoremove -y

    echo -e "${GREEN}[✓] Cloudflare WARP has been removed.${NC}"
}

# ===================== Cloudflare IP Change Options ==========================

warp_change_ip_quick() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] WARP is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}[*] Changing Cloudflare IP (quick reconnect)...${NC}"
    local old_ip new_ip
    old_ip=$(get_warp_ip)
    echo -e "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"

    for attempt in {1..3}; do
        echo -e "Attempt ${attempt}/3 ..."
        warp_disconnect
        warp-cli connect
        sleep 3

        new_ip=$(get_warp_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}[✓] IP changed successfully! New IP: $new_ip${NC}"
            return 0
        fi
        sleep 2
    done

    echo -e "${YELLOW}[!] IP did not change after quick reconnect attempts.${NC}"
    echo -e "${YELLOW}[>] Try 'Change IP (New Identity)' for a stronger change.${NC}"
    return 2
}

warp_change_ip_new_identity() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] WARP is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}[*] Creating a NEW Cloudflare WARP identity (new registration)...${NC}"
    local old_ip new_ip
    old_ip=$(get_warp_ip)
    echo -e "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"

    warp_disconnect

    echo -e "${YELLOW}[*] Deleting current WARP registration (if any)...${NC}"
    warp-cli registration delete 2>/dev/null || \
    warp-cli registration new --force 2>/dev/null || \
    echo -e "${YELLOW}[!] Could not fully delete old registration (continuing).${NC}"

    sleep 2

    echo -e "${CYAN}[*] Registering a brand new WARP account...${NC}"
    warp-cli registration new
    warp_set_proxy_mode
    warp-cli connect
    sleep 4

    new_ip=$(get_warp_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}[✓] New identity created successfully! New IP: $new_ip${NC}"
        else
            echo -e "${YELLOW}[!] New identity created, but IP appears the same. Try again later.${NC}"
        fi
    else
        echo -e "${RED}[!] Failed to obtain new IP address after registration.${NC}"
    fi
}

# ===================== Menu UI ==============================================

draw_menu() {
    clear
    echo "=================================================================="
    echo "                Cloudflare WARP Proxy Manager v$VERSION"
    echo "                        by Parham Pahlevan"
    echo "=================================================================="

    local status="NOT INSTALLED"
    local status_color=$YELLOW
    local ip="N/A"

    if warp_is_installed; then
        if warp_is_connected; then
            status="CONNECTED"
            status_color=$GREEN
            ip=$(get_warp_ip || echo "N/A")
        else
            status="DISCONNECTED"
            status_color=$RED
        fi
    fi

    echo -e "Status       : ${status_color}$status${NC}"
    echo -e "Proxy        : 127.0.0.1:10808 (SOCKS5)"
    echo -e "IP (via WARP): ${GREEN}$ip${NC}"
    echo "------------------------------------------------------------------"
    echo -e "${YELLOW}OPTIONS:${NC}"
    echo "  1) Install / Reinstall Cloudflare WARP"
    echo "  2) Connect WARP"
    echo "  3) Disconnect WARP"
    echo "  4) Show Status"
    echo "  5) Test Proxy Connection"
    echo "  6) Change IP (Quick Reconnect)"
    echo "  7) Change IP (New Identity / New Registration)"
    echo "  8) Remove Cloudflare WARP"
    echo "  9) Fix MTU (1350) + persist on reboot"
    echo " 10) Fix broken-IPv6 issue (blackhole Cloudflare IPv6, keep MASQUE)"
    echo " 11) Reset tunnel endpoint to Cloudflare default"
    echo "  0) Exit"
    echo "=================================================================="
    echo -ne "${YELLOW}Select an option [0-11]: ${NC}"
}

main_menu() {
    while true; do
        draw_menu
        read -r choice

        case "$choice" in
            1) warp_install ;;
            2) warp_connect ;;
            3) warp_disconnect ;;
            4) warp_status ;;
            5) warp_test_proxy ;;
            6) warp_change_ip_quick ;;
            7) warp_change_ip_new_identity ;;
            8) warp_remove ;;
            9) warp_fix_mtu ;;
            10) warp_fix_ipv6_issue ;;
            11) warp_reset_endpoint ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option. Please choose 0-11.${NC}"
                ;;
        esac

        if [[ "$choice" != "0" ]]; then
            echo
            echo -e "${YELLOW}Press Enter to return to the menu...${NC}"
            read -r
        fi
    done
}

# ===================== Start Program ========================================

main_menu
