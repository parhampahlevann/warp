#!/bin/bash
#
# Gost Ip6 Script v2.4.0 (hardened/optimized fork)
# Original by Masoud Gb - Special Thanks Hamid Router
#
# Changes in v2.4.0:
#  - FIXED ws/wss/mwss tunnels doing nothing. These are gost *transports*,
#    not standalone forwarding protocols like tcp/udp - a bare
#    "-L=ws://:port/dest:port" falls back to gost's "auto" handler and never
#    forwards to the embedded destination. Real static forwarding over these
#    transports requires gost's "relay" protocol AND a matching gost process
#    on the far end (relay is a two-sided tunnel: one side "-L"s, the other
#    "-F"s - unlike tcp/udp/grpc, which forward on their own with no partner
#    process needed). This version builds BOTH sides properly:
#      * This machine (dials out): -L=tcp://:port/BACKEND:port  -F=relay+ws://KHAREJ:relay_port
#      * Kharej (accepts):         -L=relay+ws://:relay_port
#    and generates the ready-to-copy unit for the Kharej side, since this
#    script can only install on the machine it's actually running on.
#
# Changes in v2.3.0:
#  - Input validation everywhere (no more "integer expression expected" crashes)
#  - Menu dispatch rewritten as a single case statement (old code had
#    overlapping if/elif blocks that could silently fall through)
#  - Kernel/TCP tuning no longer depends on /etc/rc.local (missing on most
#    modern systemd distros) - uses /etc/sysctl.d instead
#  - BBR + fq qdisc + larger buffers + keepalive tuning applied automatically
#    after every tunnel is created, for speed/stability once connected
#  - systemd units get LimitNOFILE/LimitNPROC raised (needed once you have
#    thousands of forwarded ports/connections, otherwise things fall over
#    under load even though the script "succeeds")
#  - Added ws / wss protocol options: these wrap the tunnel traffic to look
#    like ordinary HTTP(S)/WebSocket traffic, which is much harder for
#    pattern-based DPI to fingerprint as a raw proxy than plain tcp/udp
#  - Status command no longer relies on fragile awk field-counting
#  - Script installs itself to /etc/gost/install.sh on first run so the
#    "gost" alias always works, not just after "Update Script"
#
set -o pipefail

# ---------- colors ----------
C_RESET='\e[0m'; C_GREEN='\e[32m'; C_CYAN='\e[36m'; C_MAGENTA='\e[35m'
C_WHITE='\e[97m'; C_YELLOW='\e[33m'; C_RED='\e[31m'

SELF_PATH="$(readlink -f "$0")"
GOST_DIR="/etc/gost"
SYSCTL_FILE="/etc/sysctl.d/99-gost-tunnel.conf"
LIMITS_FILE="/etc/security/limits.d/99-gost-tunnel.conf"

# ---------- helpers ----------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_GREEN}Please run with root privileges.${C_RESET}"
        exit 1
    fi
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

read_choice() {
    # $1 = prompt, $2 = min, $3 = max -> echoes validated integer
    local prompt="$1" min="$2" max="$3" val
    while true; do
        read -rp "$prompt" val
        if is_number "$val" && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
            echo "$val"; return 0
        fi
        echo -e "${C_RED}Invalid option, try again.${C_RESET}" >&2
    done
}

read_port() {
    # $1 = prompt -> echoes a validated single port number
    local prompt="$1" val
    while true; do
        read -rp "$prompt" val
        if is_number "$val" && [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; then
            echo "$val"; return 0
        fi
        echo -e "${C_RED}Invalid port.${C_RESET}" >&2
    done
}

banner() {
    echo -e "${C_MAGENTA}  ___|              |        _ _|  _ \\   /
 |      _ \\    __|  __|        |  |   |  _ \\
 |   | (   | \\__ \\  |          |  ___/  (   |
\\____|\\___/  ____/ \\__|      ___|_|    \\___/ ${C_RESET}"
    echo -e "${C_CYAN}Created By Masoud Gb  Special Thanks Hamid Router${C_RESET}"
    echo -e "${C_MAGENTA}Gost Ip6 Script v2.4.0 (hardened)${C_RESET}"
}

ensure_self_installed() {
    mkdir -p "$GOST_DIR"
    if [ ! -f "$GOST_DIR/install.sh" ]; then
        cp -f "$SELF_PATH" "$GOST_DIR/install.sh"
        chmod +x "$GOST_DIR/install.sh"
    fi
    if ! grep -q "alias gost=" ~/.bashrc 2>/dev/null; then
        echo "alias gost=\"bash $GOST_DIR/install.sh\"" >> ~/.bashrc
    fi
}

# ---------- kernel / TCP tuning for speed + stability ----------
apply_kernel_tuning() {
    echo -e "${C_GREEN}Applying kernel/TCP tuning for throughput and stability...${C_RESET}"

    local kernel_major kernel_minor bbr_ok=1
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    if [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]; }; then
        bbr_ok=0
        echo -e "${C_YELLOW}Kernel < 4.9, BBR not available - skipping congestion control change.${C_RESET}"
    fi

    {
        echo "net.ipv4.ip_local_port_range = 1024 65535"
        echo "net.core.rmem_max = 67108864"
        echo "net.core.wmem_max = 67108864"
        echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
        echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
        echo "net.core.somaxconn = 65535"
        echo "net.ipv4.tcp_max_syn_backlog = 65535"
        echo "net.ipv4.tcp_syncookies = 1"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_tw_reuse = 1"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        # keepalive: detect and recover dead tunnel connections fast
        echo "net.ipv4.tcp_keepalive_time = 60"
        echo "net.ipv4.tcp_keepalive_intvl = 10"
        echo "net.ipv4.tcp_keepalive_probes = 6"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "fs.file-max = 2097152"
        if [ "$bbr_ok" -eq 1 ]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
    } > "$SYSCTL_FILE"

    sysctl --system > /dev/null 2>&1

    {
        echo "* soft nofile 1048576"
        echo "* hard nofile 1048576"
        echo "* soft nproc 1048576"
        echo "* hard nproc 1048576"
    } > "$LIMITS_FILE"

    echo -e "${C_GREEN}Kernel/TCP tuning applied.${C_RESET}"
}

# ---------- gost install ----------
install_gost() {
    local version_choice="$1"
    apt-get update -qq && apt-get install -y -qq wget nano tar > /dev/null
    if [ "$version_choice" -eq 1 ]; then
        echo -e "${C_GREEN}Installing Gost 2.11.5...${C_RESET}"
        wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz -O /tmp/gost.gz || { echo -e "${C_RED}Download failed.${C_RESET}"; return 1; }
        gunzip -f /tmp/gost.gz
        mv -f /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    else
        echo -e "${C_GREEN}Installing latest Gost 3.x...${C_RESET}"
        local download_url
        download_url=$(curl -s https://api.github.com/repos/go-gost/gost/releases | \
                        grep -oP '"browser_download_url":\s*"\K[^"]+linux_amd64\.tar\.gz' | \
                        head -n 1)
        if [ -z "$download_url" ]; then
            echo -e "${C_RED}Could not resolve latest Gost 3.x download URL.${C_RESET}"
            return 1
        fi
        wget -q -O /tmp/gost.tar.gz "$download_url" || { echo -e "${C_RED}Download failed.${C_RESET}"; return 1; }
        [ -s /tmp/gost.tar.gz ] || { echo -e "${C_RED}Downloaded file is empty.${C_RESET}"; return 1; }
        tar -xzf /tmp/gost.tar.gz -C /usr/local/bin/ gost
        chmod +x /usr/local/bin/gost
    fi
    echo -e "${C_GREEN}Gost installed successfully.${C_RESET}"
}

ensure_gost_installed() {
    if [ ! -x /usr/local/bin/gost ]; then
        echo -e "${C_GREEN}Gost is not installed yet.${C_RESET}"
        echo -e "${C_CYAN}1. ${C_RESET}Gost 2.11.5 (official)"
        echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest)"
        local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
        install_gost "$v" || return 1
    fi
    return 0
}

# ---------- direct raw forward: tcp / udp / grpc ----------
# These protocols forward on their own with no partner gost process needed -
# any plain client connecting to this port is passed straight through to
# destination_ip:port. This is the original, unchanged behavior.
# args: unit_name  destination_ip  ports_csv  protocol
build_direct_tunnel_service() {
    local unit_name="$1" destination_ip="$2" ports_csv="$3" protocol="$4"

    IFS=',' read -ra port_array <<< "$ports_csv"
    local port_count=${#port_array[@]}
    local max_ports_per_unit=4000   # keep ExecStart lines sane and startup fast
    local file_count=$(( (port_count + max_ports_per_unit - 1) / max_ports_per_unit ))

    for ((file_index = 0; file_index < file_count; file_index++)); do
        local this_unit="${unit_name}_${file_index}"
        local exec_start="ExecStart=/usr/local/bin/gost"
        local start=$((file_index * max_ports_per_unit))
        local end=$(( (file_index + 1) * max_ports_per_unit ))
        [ "$end" -gt "$port_count" ] && end=$port_count

        for ((i = start; i < end; i++)); do
            local port="${port_array[i]}"
            exec_start+=" -L=${protocol}://:${port}/[${destination_ip}]:${port}"
        done

        write_gost_unit "$this_unit" "$exec_start"
        systemctl enable "${this_unit}.service" > /dev/null 2>&1
        systemctl daemon-reload
        systemctl restart "${this_unit}.service"
    done

    apply_mss_clamp
    echo -e "${C_GREEN}Tunnel configuration applied (${file_count} service unit(s), scheme: ${protocol}).${C_RESET}"
}

# ---------- ws / wss / mwss client side (this machine dials out to Kharej) ----------
# ws/wss/mwss are transports, not standalone forward protocols - they only
# do real forwarding when combined with gost's "relay" protocol, and relay
# is inherently two-sided: this machine's -L keeps the real (backend)
# destination embedded per-port as usual, and a single shared -F leg carries
# everything to Kharej wrapped in the chosen transport. Kharej must be
# running the matching "-L=relay+<transport>://:relay_port" (see
# print_kharej_companion below) or nothing will come through.
# args: unit_name  kharej_ip  relay_port  backend_ip  ports_csv  protocol
build_relay_client_tunnel_service() {
    local unit_name="$1" kharej_ip="$2" relay_port="$3" backend_ip="$4" ports_csv="$5" protocol="$6"
    local gost_scheme="relay+${protocol}"

    IFS=',' read -ra port_array <<< "$ports_csv"
    local port_count=${#port_array[@]}
    local max_ports_per_unit=4000
    local file_count=$(( (port_count + max_ports_per_unit - 1) / max_ports_per_unit ))

    for ((file_index = 0; file_index < file_count; file_index++)); do
        local this_unit="${unit_name}_${file_index}"
        local exec_start="ExecStart=/usr/local/bin/gost"
        local start=$((file_index * max_ports_per_unit))
        local end=$(( (file_index + 1) * max_ports_per_unit ))
        [ "$end" -gt "$port_count" ] && end=$port_count

        for ((i = start; i < end; i++)); do
            local port="${port_array[i]}"
            exec_start+=" -L=tcp://:${port}/[${backend_ip}]:${port}"
        done
        exec_start+=" -F=${gost_scheme}://${kharej_ip}:${relay_port}"

        write_gost_unit "$this_unit" "$exec_start"
        systemctl enable "${this_unit}.service" > /dev/null 2>&1
        systemctl daemon-reload
        systemctl restart "${this_unit}.service"
    done

    apply_mss_clamp
    echo -e "${C_GREEN}Client tunnel configured (${file_count} service unit(s), transport: ${protocol}).${C_RESET}"
}

# shared systemd unit writer
# args: unit_name  exec_start_line
write_gost_unit() {
    local this_unit="$1" exec_start="$2"
    cat > "/etc/systemd/system/${this_unit}.service" <<EOF
[Unit]
Description=GO Simple Tunnel (${this_unit})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
${exec_start}
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# Prints (and saves to a file) the exact command/unit that must be installed
# ON THE KHAREJ SERVER for a ws/wss/mwss tunnel to actually work. This script
# cannot reach Kharej itself - that install always has to happen there.
# args: kharej_ip  relay_port  protocol
print_kharej_companion() {
    local kharej_ip="$1" relay_port="$2" protocol="$3"
    local gost_scheme="relay+${protocol}"
    local out_file="/root/gost-kharej-companion-${relay_port}.service"

    cat > "$out_file" <<EOF
[Unit]
Description=GO Simple Tunnel (relay endpoint, port ${relay_port})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
ExecStart=/usr/local/bin/gost -L=${gost_scheme}://:${relay_port}
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF

    echo ""
    echo -e "${C_YELLOW}=========================================================${C_RESET}"
    echo -e "${C_YELLOW} ACTION NEEDED ON THE KHAREJ SERVER (${kharej_ip})${C_RESET}"
    echo -e "${C_YELLOW}=========================================================${C_RESET}"
    echo -e "${C_WHITE}This machine now dials out to Kharej, but Kharej needs a${C_RESET}"
    echo -e "${C_WHITE}matching relay listener or nothing will connect. Quick way:${C_RESET}"
    echo ""
    echo -e "${C_CYAN}  gost -L=${gost_scheme}://:${relay_port}${C_RESET}"
    echo ""
    echo -e "${C_WHITE}Or for a persistent systemd service, a ready unit file was${C_RESET}"
    echo -e "${C_WHITE}saved locally at:${C_RESET} ${out_file}"
    echo -e "${C_WHITE}Copy it to Kharej and enable it there, e.g.:${C_RESET}"
    echo -e "${C_CYAN}  scp ${out_file} root@${kharej_ip}:/etc/systemd/system/${C_RESET}"
    echo -e "${C_CYAN}  ssh root@${kharej_ip} 'systemctl daemon-reload && systemctl enable --now $(basename "$out_file" .service)'${C_RESET}"
    echo -e "${C_WHITE}(Kharej needs gost installed too - same install steps as this script.)${C_RESET}"
    echo -e "${C_YELLOW}=========================================================${C_RESET}"
    echo ""
}

# TLS/WebSocket framing adds bytes on top of the real payload; if a packet then
# exceeds path MTU it gets fragmented or silently dropped by routers that block
# fragments - a common cause of "works but unstable/slow" over wss/mwss/grpc.
# Clamping MSS to the actual path MTU avoids this without needing to know the
# exact MTU in advance.
apply_mss_clamp() {
    command -v iptables &>/dev/null || return 0
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        echo -e "${C_GREEN}MSS clamping enabled (reduces fragmentation-related packet loss).${C_RESET}"
    fi
}

prompt_protocol() {
    echo -e "${C_GREEN}Select the protocol:${C_RESET}" >&2
    echo -e "${C_CYAN}1. ${C_RESET}tcp" >&2
    echo -e "${C_CYAN}2. ${C_RESET}udp" >&2
    echo -e "${C_CYAN}3. ${C_RESET}grpc" >&2
    echo -e "${C_CYAN}4. ${C_RESET}ws   (WebSocket - looks like normal HTTP traffic; needs a relay listener on Kharej)" >&2
    echo -e "${C_CYAN}5. ${C_RESET}wss  (WebSocket over TLS - looks like normal HTTPS traffic, hardest to fingerprint, more CPU cost; needs a relay listener on Kharej)" >&2
    echo -e "${C_CYAN}6. ${C_RESET}mwss (multiplexed wss - same stealth as wss, but one TLS handshake shared across many streams: much faster/more stable under real traffic; needs a relay listener on Kharej)" >&2
    local opt
    opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 6)
    case "$opt" in
        1) echo "tcp" ;;
        2) echo "udp" ;;
        3) echo "grpc" ;;
        4) echo "ws" ;;
        6) echo "mwss" ;;
        5) echo "wss" ;;
    esac
}

prompt_ports() {
    local opt ports_out
    opt=$(read_choice $'\e[32mPorts:\n\e[0m\e[36m1. \e[0mManual (comma separated)\n\e[36m2. \e[0mRange\n\e[32mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        read -rp $'\e[36mEnter ports (comma separated): \e[0m' ports_out
        IFS=',' read -ra check_arr <<< "$ports_out"
        for p in "${check_arr[@]}"; do
            if ! is_number "$p" || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                echo -e "${C_RED}Invalid port: $p${C_RESET}" >&2; return 1
            fi
        done
    else
        local range start end
        read -rp $'\e[36mEnter port range (e.g. 2000,2100): \e[0m' range
        IFS=',' read -ra rarr <<< "$range"
        start="${rarr[0]:-}"; end="${rarr[1]:-}"
        if ! is_number "$start" || ! is_number "$end" || [ "$start" -lt 1 ] || [ "$end" -gt 65535 ] || [ "$start" -gt "$end" ]; then
            echo -e "${C_RED}Invalid range.${C_RESET}" >&2; return 1
        fi
        ports_out=$(seq -s, "$start" "$end")
    fi
    echo "$ports_out"
}

action_create_tunnel() {
    local ip_version="$1" destination_ip ports protocol
    read -rp $'\e[97mEnter destination (Kharej) IP: \e[0m' destination_ip
    [ -z "$destination_ip" ] && { echo -e "${C_RED}IP cannot be empty.${C_RESET}"; return; }

    ports=$(prompt_ports) || return
    protocol=$(prompt_protocol)

    echo -e "${C_WHITE}Destination:${C_RESET} $destination_ip  ${C_WHITE}Protocol:${C_RESET} $protocol  ${C_WHITE}Ports:${C_RESET} $(echo "$ports" | cut -c1-40)..."

    ensure_gost_installed || return

    local unit_name="gost_$(echo "$destination_ip" | tr -c 'a-zA-Z0-9' '_')"

    case "$protocol" in
        ws|wss|mwss)
            local backend_ip relay_port
            read -rp $'\e[97mFinal backend IP (press Enter for 127.0.0.1 if the real service runs on Kharej itself): \e[0m' backend_ip
            backend_ip="${backend_ip:-127.0.0.1}"
            relay_port=$(read_port $'\e[97mKharej relay port (a separate control port gost listens on there): \e[0m')

            unit_name="gostc_$(echo "$destination_ip" | tr -c 'a-zA-Z0-9' '_')"
            build_relay_client_tunnel_service "$unit_name" "$destination_ip" "$relay_port" "$backend_ip" "$ports" "$protocol"
            print_kharej_companion "$destination_ip" "$relay_port" "$protocol"
            ;;
        *)
            build_direct_tunnel_service "$unit_name" "$destination_ip" "$ports" "$protocol"
            ;;
    esac

    apply_kernel_tuning
}

action_status() {
    if ! command -v gost &>/dev/null; then
        echo -e "${C_YELLOW}Gost is not installed.${C_RESET}"
        return
    fi
    local found=0
    for svc in /etc/systemd/system/gost_*.service /etc/systemd/system/gostc_*.service; do
        [ -e "$svc" ] || continue
        found=1
        local active dest proto ports mode
        active=$(systemctl is-active "$(basename "$svc")" 2>/dev/null)
        dest=$(grep -oP 'ExecStart=.*?-L=\S+://:\d+/\[\K[^\]]+' "$svc" | head -1)
        proto=$(grep -oP 'ExecStart=.*?-L=\K[a-zA-Z0-9+]+(?=://)' "$svc" | head -1)
        ports=$(grep -oP -- '-L=\S+?://:\K[0-9]+' "$svc" | wc -l)
        if grep -q -- '-F=' "$svc"; then
            mode="client(-F)"
        else
            mode="direct(-L)"
        fi
        echo -e "${C_WHITE}Unit:${C_RESET} $(basename "$svc")  ${C_WHITE}Mode:${C_RESET} $mode  ${C_WHITE}State:${C_RESET} $active  ${C_WHITE}IP:${C_RESET} $dest  ${C_WHITE}Proto:${C_RESET} $proto  ${C_WHITE}Ports:${C_RESET} $ports"
    done
    [ "$found" -eq 0 ] && echo -e "${C_YELLOW}No tunnel services configured.${C_RESET}"
}

action_update_script() {
    read -rp $'\e[32mUpdate script from repo? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    mkdir -p "$GOST_DIR"
    wget -q -O "$GOST_DIR/install.sh" https://github.com/masoudgb/Gost-ip6/raw/main/install.sh
    chmod +x "$GOST_DIR/install.sh"
    echo -e "${C_GREEN}Updated. Restarting...${C_RESET}"
    exec bash "$GOST_DIR/install.sh"
}

action_change_version() {
    echo -e "${C_CYAN}1. ${C_RESET}Gost 2.11.5"
    echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest)"
    local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    install_gost "$v"
    systemctl restart gost_*.service 2>/dev/null
    systemctl restart gostc_*.service 2>/dev/null
}

action_auto_restart() {
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        local hours; read -rp $'\e[97mRestart interval in hours: \e[0m' hours
        is_number "$hours" || { echo -e "${C_RED}Invalid number.${C_RESET}"; return; }
        cat > /usr/bin/gost_auto_restart.sh <<'EOF'
#!/bin/bash
systemctl daemon-reload
systemctl restart gost_*.service 2>/dev/null
systemctl restart gostc_*.service 2>/dev/null
EOF
        chmod +x /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh; echo "0 */$hours * * * /usr/bin/gost_auto_restart.sh") | crontab -
        echo -e "${C_GREEN}Auto restart scheduled every $hours hour(s).${C_RESET}"
    else
        rm -f /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Auto restart disabled.${C_RESET}"
    fi
}

action_auto_clear_cache() {
    echo -e "${C_YELLOW}Note: dropping page cache does not speed up an already-running tunnel and can briefly hurt performance right after it runs; only useful on memory-starved boxes.${C_RESET}"
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        local days; read -rp $'\e[97mInterval in days: \e[0m' days
        is_number "$days" || { echo -e "${C_RED}Invalid number.${C_RESET}"; return; }
        (crontab -l 2>/dev/null | grep -v drop_caches; echo "0 0 */$days * * sync; echo 3 > /proc/sys/vm/drop_caches") | crontab -
        echo -e "${C_GREEN}Scheduled.${C_RESET}"
    else
        (crontab -l 2>/dev/null | grep -v drop_caches) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Disabled.${C_RESET}"
    fi
}

action_install_bbr() {
    apply_kernel_tuning
    echo -e "${C_CYAN}Optional: also run teddysun/across bbr.sh for alternate congestion-control algorithms (bbrplus/etc)? (y/n)${C_RESET}"
    read -rp "> " ans
    if [ "$ans" == "y" ]; then
        wget -qN --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh && chmod +x bbr.sh && bash bbr.sh
    fi
}

action_uninstall() {
    read -rp $'\e[91mWarning\e[33m: this removes Gost and all tunnel data. Continue? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    rm -f /usr/bin/gost_auto_restart.sh
    (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh | grep -v drop_caches) | crontab - 2>/dev/null
    systemctl stop gost_*.service 2>/dev/null
    systemctl stop gostc_*.service 2>/dev/null
    systemctl disable gost_*.service 2>/dev/null
    systemctl disable gostc_*.service 2>/dev/null
    rm -f /etc/systemd/system/gost_*.service
    rm -f /etc/systemd/system/gostc_*.service
    rm -f /root/gost-kharej-companion-*.service
    rm -f /usr/local/bin/gost
    rm -rf "$GOST_DIR"
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    systemctl daemon-reload
    echo -e "${C_GREEN}Gost uninstalled.${C_RESET}"
}

main_menu() {
    banner
    echo -e "${C_CYAN}1. ${C_RESET}Gost Tunnel By IP4"
    echo -e "${C_CYAN}2. ${C_RESET}Gost Tunnel By IP6"
    echo -e "${C_CYAN}3. ${C_RESET}Gost Status"
    echo -e "${C_CYAN}4. ${C_RESET}Update Script"
    echo -e "${C_CYAN}5. ${C_RESET}Change Gost Version"
    echo -e "${C_CYAN}6. ${C_RESET}Auto Restart Gost"
    echo -e "${C_CYAN}7. ${C_RESET}Auto Clear Cache"
    echo -e "${C_CYAN}8. ${C_RESET}Apply Speed/Stability Tuning (BBR + TCP tuning)"
    echo -e "${C_CYAN}9. ${C_RESET}Uninstall"
    echo -e "${C_CYAN}10. ${C_RESET}Exit"

    local choice; choice=$(read_choice $'\e[97mYour choice: \e[0m' 1 10)
    case "$choice" in
        1) action_create_tunnel 4 ;;
        2) action_create_tunnel 6 ;;
        3) action_status ;;
        4) action_update_script ;;
        5) action_change_version ;;
        6) action_auto_restart ;;
        7) action_auto_clear_cache ;;
        8) action_install_bbr ;;
        9) action_uninstall ;;
        10) echo -e "${C_GREEN}Bye.${C_RESET}"; exit 0 ;;
    esac
}

# ---------- entry point ----------
require_root
ensure_self_installed
main_menu
