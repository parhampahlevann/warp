#!/bin/bash

###############################################################################
# WARP -> Xray (x-ui) WireGuard Outbound Setup
#
# Why this exists / history:
#   The original approach used Cloudflare's official warp-cli client in
#   "proxy mode" (SOCKS5 on 127.0.0.1:10808) as an outbound for x-ui.
#   On this host that approach hit a hard wall: warp-cli's proxy mode is
#   locked to the MASQUE (QUIC/UDP-443) transport, and QUIC traffic from
#   this network was being actively shaped/dropped a few seconds into every
#   session (confirmed via journalctl: ~20-30% one-way packet loss on the
#   client->edge leg only, despite perfect ICMP ping — a classic sign of
#   protocol-specific traffic shaping, not a real network problem).
#
#   WireGuard (a different protocol/signature) is NOT usable through
#   warp-cli's proxy mode at all (error: "Proxy mode only supports MASQUE").
#
#   The fix: skip warp-cli/warp-svc entirely. Use `wgcf` (unofficial,
#   well-established CLI) to register a free WARP account and obtain raw
#   WireGuard credentials, then add Xray-core's OWN native "wireguard"
#   outbound (no SOCKS5 layer, no warp-svc daemon at all) directly in
#   x-ui's Xray Configuration. This is the standard, well-supported pattern
#   used by most x-ui/3x-ui WARP integrations.
#
# What this script does:
#   1) Installs wgcf (auto-detects latest release + your CPU arch)
#   2) Registers a free WARP account (wgcf register)
#   3) Generates a WireGuard profile (wgcf generate)
#   4) Prints a ready-to-paste Xray "wireguard" outbound JSON block
#   5) (Optional) Does a real, temporary wg-quick test to confirm the
#      credentials actually work end-to-end BEFORE you paste anything into
#      the panel — so you're not debugging blind inside x-ui's textbox.
#
# What this script deliberately does NOT do:
#   - It does not touch x-ui's config/database directly. x-ui (classic
#     vaxilu fork) stores the Xray config as a JSON blob inside its own
#     sqlite DB via the web UI ("Panel Settings" -> "Xray Configuration"),
#     and there is no stable, version-safe way to patch that from a shell
#     script without risking corruption. You paste the generated JSON
#     yourself, which is safer and lets you see exactly what changed.
###############################################################################

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
VERSION="1.0"

WORKDIR="/root/warp-wireguard"
WGCF_BIN="${WORKDIR}/wgcf"
WGCF_ACCOUNT="${WORKDIR}/wgcf-account.toml"
WGCF_PROFILE="${WORKDIR}/wgcf-profile.conf"

# Cloudflare's well-known WARP peer public key (constant across accounts).
CF_PEER_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
CF_ENDPOINT="engage.cloudflareclient.com:2408"

# ===================== Root Check ===========================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root.${NC}"
    echo -e "${YELLOW}Usage: sudo bash warp-xray-setup.sh${NC}"
    exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

# ===================== Helpers ==============================================

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv6" ;;
        i386|i686) echo "386" ;;
        *)
            echo -e "${RED}[ERROR] Unsupported CPU architecture: $(uname -m)${NC}" >&2
            echo ""
            ;;
    esac
}

# Fallback version used only if the GitHub API call fails/rate-limits.
WGCF_FALLBACK_VERSION="2.2.32"

wgcf_is_installed() {
    [[ -x "$WGCF_BIN" ]]
}

# ===================== Install wgcf =========================================

install_wgcf() {
    local arch
    arch=$(detect_arch)
    if [[ -z "$arch" ]]; then
        return 1
    fi

    echo -e "${CYAN}[*] Detecting latest wgcf release...${NC}"
    local tag=""
    tag=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":\s*"v?([^"]+)".*/\1/')

    if [[ -z "$tag" ]]; then
        echo -e "${YELLOW}[!] Could not reach GitHub API (rate limit or network). Falling back to v${WGCF_FALLBACK_VERSION}.${NC}"
        tag="$WGCF_FALLBACK_VERSION"
    else
        echo -e "${GREEN}[✓] Latest wgcf version: v${tag}${NC}"
    fi

    local asset="wgcf_${tag}_linux_${arch}"
    local url="https://github.com/ViRb3/wgcf/releases/download/v${tag}/${asset}"

    echo -e "${CYAN}[*] Downloading ${asset}...${NC}"
    if ! curl -fsSL "$url" -o "$WGCF_BIN"; then
        echo -e "${RED}[ERROR] Download failed from: ${url}${NC}"
        echo -e "${YELLOW}[>] Check available assets manually: https://github.com/ViRb3/wgcf/releases${NC}"
        return 1
    fi

    chmod +x "$WGCF_BIN"
    echo -e "${GREEN}[✓] wgcf installed at ${WGCF_BIN}${NC}"
    "$WGCF_BIN" --version 2>/dev/null || true
}

# ===================== Register + Generate ===================================

wgcf_do_register() {
    if ! wgcf_is_installed; then
        echo -e "${RED}[ERROR] wgcf is not installed yet. Run option 1 first.${NC}"
        return 1
    fi
    if [[ -f "$WGCF_ACCOUNT" ]]; then
        echo -e "${YELLOW}[INFO] An account already exists at ${WGCF_ACCOUNT}.${NC}"
        read -rp "Register a brand new account instead? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
        rm -f "$WGCF_ACCOUNT"
    fi
    echo -e "${CYAN}[*] Registering a new free WARP account...${NC}"
    (cd "$WORKDIR" && "$WGCF_BIN" register --accept-tos)
}

wgcf_do_generate() {
    if ! wgcf_is_installed; then
        echo -e "${RED}[ERROR] wgcf is not installed yet. Run option 1 first.${NC}"
        return 1
    fi
    if [[ ! -f "$WGCF_ACCOUNT" ]]; then
        echo -e "${RED}[ERROR] No account found. Run option 2 (register) first.${NC}"
        return 1
    fi
    echo -e "${CYAN}[*] Generating WireGuard profile...${NC}"
    (cd "$WORKDIR" && "$WGCF_BIN" generate)
    if [[ -f "$WGCF_PROFILE" ]]; then
        echo -e "${GREEN}[✓] Profile written to ${WGCF_PROFILE}${NC}"
    else
        echo -e "${RED}[ERROR] Profile generation failed.${NC}"
        return 1
    fi
}

# ===================== Parse profile & emit Xray JSON ========================

# Extracts a field from the WireGuard profile (simple, no external deps).
profile_get() {
    local key="$1"
    grep -m1 "^${key} = " "$WGCF_PROFILE" | sed -E "s/^${key} = //"
}

show_xray_outbound() {
    if [[ ! -f "$WGCF_PROFILE" ]]; then
        echo -e "${RED}[ERROR] No profile found at ${WGCF_PROFILE}. Run option 3 (generate) first.${NC}"
        return 1
    fi

    local private_key addresses dns
    private_key=$(profile_get "PrivateKey")
    addresses=$(profile_get "Address")
    dns=$(profile_get "DNS")

    if [[ -z "$private_key" || -z "$addresses" ]]; then
        echo -e "${RED}[ERROR] Could not parse PrivateKey/Address from ${WGCF_PROFILE}.${NC}"
        echo -e "${YELLOW}[>] Raw file contents:${NC}"
        cat "$WGCF_PROFILE"
        return 1
    fi

    # Split "172.16.0.2/32, 2606:xxxx::2/128" into a JSON array of two strings.
    local addr_json
    addr_json=$(echo "$addresses" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | \
        awk '{printf "%s\"%s\"", (NR>1?",":""), $0}')

    echo -e "${CYAN}=====================================================================${NC}"
    echo -e "${GREEN}Paste this as a NEW OUTBOUND inside x-ui's Xray Configuration JSON${NC}"
    echo -e "${GREEN}(inside the top-level \"outbounds\": [ ... ] array, alongside your${NC}"
    echo -e "${GREEN}existing \"freedom\"/\"blackhole\" outbounds — do not replace the array,${NC}"
    echo -e "${GREEN}just add this object to it):${NC}"
    echo -e "${CYAN}=====================================================================${NC}"
    cat <<EOF
{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${private_key}",
    "address": [${addr_json}],
    "peers": [
      {
        "publicKey": "${CF_PEER_PUBKEY}",
        "endpoint": "${CF_ENDPOINT}",
        "allowedIPs": ["0.0.0.0/0", "::/0"]
      }
    ],
    "mtu": 1280,
    "kernelMode": false
  }
}
EOF
    echo -e "${CYAN}=====================================================================${NC}"
    echo -e "${YELLOW}[>] Then add a routing rule so your chosen inbound uses it, e.g.:${NC}"
    cat <<'EOF'
{
  "type": "field",
  "inboundTag": ["YOUR-INBOUND-TAG-HERE"],
  "outboundTag": "warp-out"
}
EOF
    echo -e "${CYAN}=====================================================================${NC}"
    echo -e "${YELLOW}[>] Send me your current Xray Configuration JSON and I'll merge these${NC}"
    echo -e "${YELLOW}    in for you precisely instead of doing it by hand.${NC}"
}

# ===================== Optional: real end-to-end test =======================
# This does NOT touch x-ui. It brings up a throwaway wg-quick interface using
# the generated profile, tests connectivity through it, then tears it back
# down — so you know the credentials work before touching the panel at all.

wg_test_connection() {
    if [[ ! -f "$WGCF_PROFILE" ]]; then
        echo -e "${RED}[ERROR] No profile found. Run option 3 (generate) first.${NC}"
        return 1
    fi

    if ! command -v wg-quick &>/dev/null; then
        echo -e "${CYAN}[*] Installing wireguard-tools...${NC}"
        apt-get update && apt-get install -y wireguard-tools resolvconf 2>/dev/null || \
        apt-get install -y wireguard-tools 2>/dev/null
    fi

    local test_conf="/etc/wireguard/wgcf-test.conf"
    cp "$WGCF_PROFILE" "$test_conf"

    echo -e "${CYAN}[*] Bringing up a temporary WireGuard interface (wgcf-test)...${NC}"
    if ! wg-quick up wgcf-test 2>&1; then
        echo -e "${RED}[!] Failed to bring up the interface. See the error above.${NC}"
        rm -f "$test_conf"
        return 1
    fi

    sleep 2
    echo -e "${CYAN}[*] Testing connectivity through the tunnel...${NC}"
    local ip
    ip=$(curl -s --max-time 8 --interface wgcf-test https://api4.ipify.org 2>/dev/null)

    if [[ -n "$ip" ]]; then
        echo -e "${GREEN}[✓] Success! Exit IP through WARP WireGuard tunnel: ${ip}${NC}"
        echo -e "${GREEN}[✓] Your wgcf credentials are valid and working. Safe to paste into x-ui.${NC}"
    else
        echo -e "${RED}[!] Tunnel came up but no response through it — check firewall/MTU.${NC}"
    fi

    echo -e "${CYAN}[*] Tearing down the test interface (does not affect x-ui)...${NC}"
    wg-quick down wgcf-test 2>/dev/null
    rm -f "$test_conf"
}

show_profile() {
    if [[ ! -f "$WGCF_PROFILE" ]]; then
        echo -e "${RED}[ERROR] No profile found. Run option 3 (generate) first.${NC}"
        return 1
    fi
    echo -e "${CYAN}===== ${WGCF_PROFILE} =====${NC}"
    cat "$WGCF_PROFILE"
}

wgcf_status() {
    if ! wgcf_is_installed; then
        echo -e "${RED}[ERROR] wgcf is not installed yet.${NC}"
        return 1
    fi
    if [[ ! -f "$WGCF_ACCOUNT" ]]; then
        echo -e "${YELLOW}[INFO] No account registered yet.${NC}"
        return 0
    fi
    (cd "$WORKDIR" && "$WGCF_BIN" status)
}

# ===================== Menu UI ==============================================

draw_menu() {
    clear
    echo "=================================================================="
    echo "        WARP -> Xray (x-ui) WireGuard Outbound Setup v$VERSION"
    echo "=================================================================="
    local wgcf_state="NOT INSTALLED"
    local wgcf_color=$YELLOW
    if wgcf_is_installed; then
        wgcf_state="INSTALLED"
        wgcf_color=$GREEN
    fi
    local account_state="NOT REGISTERED"
    local account_color=$YELLOW
    [[ -f "$WGCF_ACCOUNT" ]] && { account_state="REGISTERED"; account_color=$GREEN; }
    local profile_state="NOT GENERATED"
    local profile_color=$YELLOW
    [[ -f "$WGCF_PROFILE" ]] && { profile_state="GENERATED"; profile_color=$GREEN; }

    echo -e "wgcf binary : ${wgcf_color}${wgcf_state}${NC}"
    echo -e "WARP account: ${account_color}${account_state}${NC}"
    echo -e "WG profile  : ${profile_color}${profile_state}${NC}"
    echo "------------------------------------------------------------------"
    echo -e "${YELLOW}OPTIONS:${NC}"
    echo "  1) Install / update wgcf"
    echo "  2) Register a free WARP account"
    echo "  3) Generate WireGuard profile"
    echo "  4) Show ready-to-paste Xray outbound JSON"
    echo "  5) Show raw wgcf-profile.conf"
    echo "  6) Test the WireGuard tunnel directly (does not touch x-ui)"
    echo "  7) Show wgcf account status"
    echo "  8) Run steps 1-4 in one go (quick setup)"
    echo "  0) Exit"
    echo "=================================================================="
    echo -ne "${YELLOW}Select an option [0-8]: ${NC}"
}

main_menu() {
    while true; do
        draw_menu
        read -r choice
        case "$choice" in
            1) install_wgcf ;;
            2) wgcf_do_register ;;
            3) wgcf_do_generate ;;
            4) show_xray_outbound ;;
            5) show_profile ;;
            6) wg_test_connection ;;
            7) wgcf_status ;;
            8)
                install_wgcf && wgcf_do_register && wgcf_do_generate && show_xray_outbound
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option. Please choose 0-8.${NC}"
                ;;
        esac
        if [[ "$choice" != "0" ]]; then
            echo
            echo -e "${YELLOW}Press Enter to return to the menu...${NC}"
            read -r
        fi
    done
}

main_menu
