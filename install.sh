#!/usr/bin/env bash
# =============================================================================
#  aestun.sh — one file: installer + manager + live monitor + zapret + build + port-forward.
#
#    sudo ./aestun.sh                # management menu (default)
#    sudo ./aestun.sh install        # interactive installer (run on each server)
#    ./aestun.sh build [amd64|arm64] # cross-compile a static binary (dev machine)
#    ./aestun.sh zap-rule {add|del|rearm}   # NFQUEUE helper, invoked by systemd
#    ./aestun.sh fwd-rule {add|del}         # DNAT/forwarding helper, invoked by systemd
# =============================================================================
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${LIB_DIR}/$(basename "${BASH_SOURCE[0]}")"
MGR_DST="/usr/local/sbin/aestun-mgr"

# ----------------------------------------------------------------- paths / consts
BIN_DST="/usr/local/bin/aestun"
CONF_DIR="/etc/aestun"
CONF="${CONF_DIR}/config.json"
SERVICE="/etc/systemd/system/aestun.service"
STATS="/run/aestun/stats.json"
DPI_LOG="/var/log/aestun/dpi.jsonl"
SYSCTL_FILE="/etc/sysctl.d/99-aestun.conf"
BBR_MODCONF="/etc/modules-load.d/aestun-bbr.conf"
ZAPRET_DIR="/opt/zapret"
ZAP_BIN="${ZAPRET_DIR}/nfq/nfqws"
ZAP_SERVICE="/etc/systemd/system/aestun-zapret.service"
ZAP_RULES="/etc/aestun/zapret-rules.sh"
FWD_SERVICE="/etc/systemd/system/aestun-fwd.service"
WATCHDOG_SERVICE="/etc/systemd/system/aestun-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/aestun-watchdog.timer"
WATCHDOG_STATE="/run/aestun/watchdog.last"
CORE_REPO_ZIP="https://github.com/3aeidkhalili/AES-256-GCM-anti-DPI/archive/refs/heads/main.zip"

# ---------------------------------------------------------------- defaults (PSK & port)
DEFAULT_PSK_PLACEHOLDER="gDfGvhlFAwaNB72O8/CrtbG6g6JnQjmJCIeSFtPRxMg="
DEFAULT_PSK="${AESTUN_PSK:-$DEFAULT_PSK_PLACEHOLDER}"
DEFAULT_PORT="${AESTUN_PORT:-2087}"

# ------------------------------------------------------------------------- colors
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; W=$'\e[97m'; D=$'\e[2m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; C=""; W=""; D=""; BOLD=""; N=""
fi

msg()   { printf '%s\n' "${G}[OK]${N} $*"; }
warn()  { printf '%s\n' "${Y}[!]${N} $*"; }
err()   { printf '%s\n' "${R}[X]${N} $*" >&2; }
hdr()   { printf '\n%s\n' "${BOLD}${C}:: $* ::${N}"; }
pause() { printf '\n%s' "${D}Press Enter to continue...${N}"; read -r _ || true; }

confirm() { local a; printf '%s [y/N]: ' "$1"; read -r a || return 1; [[ "$a" =~ ^[yY]$ ]]; }

need_root() { if [[ $EUID -ne 0 ]]; then err "Please run as root (sudo)."; exit 1; fi; }

sync_mgr_bin() {
  local s_real m_real
  s_real="$(realpath "$SELF" 2>/dev/null || echo "$SELF")"
  m_real="$(realpath "$MGR_DST" 2>/dev/null || echo "$MGR_DST")"
  if [[ "$s_real" != "$m_real" ]]; then
    install -m 0755 "$SELF" "$MGR_DST" 2>/dev/null || true
  fi
}

svc_active() {
  local s
  s="$(systemctl is-active "$1" 2>/dev/null | head -1)"
  printf '%s' "${s:-inactive}"
}

ask() {
  local p="$1" d="${2-}" a
  if [[ -n "$d" ]]; then
    printf '%s%s%s [%s%s%s]: ' "$W" "$p" "$N" "$C" "$d" "$N" >&2
  else
    printf '%s%s%s: ' "$W" "$p" "$N" >&2
  fi
  if ! read -r a; then printf '%s' "$d"; return 1; fi
  printf '%s' "${a:-$d}"
}

ask_req() {
  local v
  while true; do
    if ! v="$(ask "$1" "${2-}")"; then
      err "No input (EOF/non-interactive stdin)."
      return 1
    fi
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    err "Value required."
  done
}

ask_yn() {
  local p="$1" d="${2:-Y}" a hint
  [[ "$d" == Y ]] && hint="Y/n" || hint="y/N"
  printf '%s%s%s [%s]: ' "$W" "$p" "$N" "$hint" >&2
  if ! read -r a; then return 1; fi
  a="${a:-$d}"
  [[ "$a" =~ ^[yY]$ ]]
}

ask_choice() {
  local prompt="$1" d="$2"; shift 2
  local -a opts=("$@")
  printf '%s%s%s\n' "$W" "$prompt" "$N" >&2
  local i=1 o
  for o in "${opts[@]}"; do
    if [[ "$o" == "$d" ]]; then
      printf '  %s%d%s) %-20s %s(default)%s\n' "$C" "$i" "$N" "$o" "$D" "$N" >&2
    else
      printf '  %s%d%s) %s\n' "$C" "$i" "$N" "$o" >&2
    fi
    i=$(( i + 1 ))
  done
  local a
  printf '%sSelect%s: ' "$W" "$N" >&2
  if ! read -r a; then printf '%s' "$d"; return 1; fi
  if [[ -z "$a" ]]; then printf '%s' "$d"; return 0; fi
  if [[ "$a" =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#opts[@]} )); then
    printf '%s' "${opts[$((a-1))]}"; return 0
  fi
  for o in "${opts[@]}"; do
    [[ "$o" == "$a" ]] && { printf '%s' "$o"; return 0; }
  done
  printf '%s\n' "${Y}  (invalid choice — using default: ${d})${N}" >&2
  printf '%s' "$d"
  return 0
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
looks_like_bare_port() { [[ "$1" =~ ^[0-9]+$ ]]; }

# --------------------------------------------------------- IPv4 / IPv6 helpers
strip_brackets() {
  local s="${1:-}"
  s="${s#\[}"
  s="${s%\]}"
  printf '%s' "$s"
}

is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  local s
  s="$(strip_brackets "${1:-}")"
  [[ "$s" == *:* ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$s" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    sys.exit(0 if ip.version == 6 else 1)
except Exception:
    sys.exit(1)
PY
    return $?
  fi
  [[ "$s" =~ ^[0-9a-fA-F:]+$ ]]
}

# Given a raw input (IPv4, IPv6, [IPv6], [IPv6]:port, IPv4:port, or domain), extract clean host
normalize_host_input() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if [[ "$raw" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ^\[([^\]]+)\]$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if is_ipv6 "$raw"; then
    printf '%s' "$raw"
    return 0
  fi
  # If it has a single colon (e.g. domain:port or ipv4:port), strip the port part
  if [[ "$raw" == *:* && "${raw#*:}" != *:* ]]; then
    printf '%s' "${raw%:*}"
    return 0
  fi
  printf '%s' "$raw"
}

# Format host and port for Go net.Dial / config.json ("1.2.3.4:2087" or "[2001:db8::1]:2087")
format_peer_endpoint() {
  local h p
  h="$(strip_brackets "$1")"
  p="$2"
  if is_ipv6 "$h"; then
    printf '[%s]:%s' "$h" "$p"
  else
    printf '%s:%s' "$h" "$p"
  fi
}

# Extract host (without brackets) from peer ("1.2.3.4:2087" or "[2001:db8::1]:2087")
peer_extract_host() {
  local peer="${1:-}"
  if [[ "$peer" =~ ^\[([^\]]+)\]:[0-9]+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$(strip_brackets "${peer%:*}")"
  fi
}

# Extract port from peer
peer_extract_port() {
  local peer="${1:-}"
  printf '%s' "${peer##*:}"
}

detect_public_ips() {
  local v4="" v6=""
  v4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  v6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  [[ -n "$v4" ]] && printf '  This server IPv4 : %s%s%s\n' "$G" "$v4" "$N"
  [[ -n "$v6" ]] && printf '  This server IPv6 : %s%s%s\n' "$G" "$v6" "$N"
}

ask_int() {
  local p="$1" d="$2" v
  v="$(ask "$p" "$d")" || v="$d"
  if is_uint "$v"; then
    printf '%s' "$v"
  else
    printf '%s\n' "${Y}  (not a number — using ${d})${N}" >&2
    printf '%s' "$d"
  fi
}

# ------------------------------------------------------------------- architecture
arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             echo unknown ;;
  esac
}

zapret_platform() {
  case "$(uname -m)" in
    x86_64|amd64)  echo linux-x86_64 ;;
    aarch64|arm64) echo linux-arm64 ;;
    *)             echo "" ;;
  esac
}

# ----------------------------------------------------------------- read JSON safely
json_get() {
  local f="$1" k="$2"
  [[ -f "$f" ]] || { echo ""; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$k" '.[$k] | select(. != null)' "$f" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$f" "$k" <<'PY' 2>/dev/null
import json,sys
try:
    with open(sys.argv[1]) as fp:
        d=json.load(fp)
    v=d.get(sys.argv[2],None)
    if isinstance(v, bool):
        print("true" if v else "false")
    elif v is not None:
        print(v)
except Exception:
    pass
PY
  else
    grep -oE "\"$k\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9.]+|true|false)" "$f" \
      | head -1 | sed -E "s/^\"$k\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"\$//"
  fi
}

human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB PB",u," "); i=1;
    while(b>=1024 && i<6){b/=1024;i++}
    printf (i==1?"%d %s":"%.2f %s"), b, u[i]
  }'
}

fmt_dur() {
  local s=${1:-0} d h m
  d=$(( s/86400 )); s=$(( s%86400 )); h=$(( s/3600 )); s=$(( s%3600 )); m=$(( s/60 ))
  local out=""
  (( d>0 )) && out+="${d}d "
  (( h>0 )) && out+="${h}h "
  out+="${m}m"
  echo "$out"
}

# --------------------------------------------------------------------- dependencies & clock sync
ensure_deps() {
  local miss=()
  command -v ip >/dev/null 2>&1 || miss+=(iproute2)
  command -v ss >/dev/null 2>&1 || miss+=(iproute2)
  command -v ping >/dev/null 2>&1 || miss+=(iputils-ping)
  command -v iptables >/dev/null 2>&1 || miss+=(iptables)
  command -v python3 >/dev/null 2>&1 || miss+=(python3)
  command -v jq >/dev/null 2>&1 || miss+=(jq)
  command -v conntrack >/dev/null 2>&1 || miss+=(conntrack)
  command -v curl >/dev/null 2>&1 || miss+=(curl)
  if ((${#miss[@]})); then
    warn "Installing prerequisites: ${miss[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${miss[@]}" >/dev/null 2>&1 || warn "Some packages could not be auto-installed: ${miss[*]}"
  fi
}

sync_clock_http() {
  timedatectl set-ntp true >/dev/null 2>&1 || true
  command -v curl >/dev/null 2>&1 || return 0
  local hdr_date="" url
  for url in "http://connectivitycheck.gstatic.com/generate_204" "https://www.google.com" "https://1.1.1.1"; do
    hdr_date="$(curl -fsSI --max-time 3 "$url" 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^Date:/ {sub(/^Date:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}')"
    [[ -n "$hdr_date" ]] && break
  done
  if [[ -n "$hdr_date" ]]; then
    local remote_ts local_ts diff
    remote_ts="$(date -u -d "$hdr_date" +%s 2>/dev/null || echo 0)"
    local_ts="$(date -u +%s)"
    if (( remote_ts > 1700000000 )); then
      diff=$(( remote_ts - local_ts ))
      (( diff < 0 )) && diff=$(( -diff ))
      if (( diff >= 2 )); then
        date -u -s "$hdr_date" >/dev/null 2>&1 || true
      fi
    fi
  fi
}

check_build_deps() {
  if [[ ! -d "${LIB_DIR}/vendor" ]]; then
    warn "vendor/ is absent — Go build will fetch modules from proxy."
  fi
}

fetch_core() {
  hdr "Fetching tunnel core from upstream"
  export DEBIAN_FRONTEND=noninteractive
  command -v unzip >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y unzip >/dev/null 2>&1 || true; }
  command -v unzip >/dev/null 2>&1 || { err "unzip is required and could not be installed."; return 1; }
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl >/dev/null 2>&1 || true
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
    err "Neither curl nor wget is available."; return 1; }

  local tmp; tmp="$(mktemp -d)"
  local zipf="${tmp}/core.zip"

  msg "Downloading: ${CORE_REPO_ZIP}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$CORE_REPO_ZIP" -o "$zipf"
  else
    wget -q "$CORE_REPO_ZIP" -O "$zipf"
  fi
  [[ -s "$zipf" ]] || { err "Download failed or produced an empty file."; rm -rf "$tmp"; return 1; }

  unzip -q "$zipf" -d "$tmp/x" || { err "unzip failed on the downloaded archive."; rm -rf "$tmp"; return 1; }

  local src; src="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$src" ]] || { err "Unexpected archive layout."; rm -rf "$tmp"; return 1; }

  local f base copied=0
  for f in "$src"/*; do
    base="$(basename "$f")"
    [[ "$base" == "aestun.sh" ]] && continue
    if [[ -e "$f" ]]; then
      cp -rf "$f" "${LIB_DIR}/${base}"
      copied=$(( copied + 1 ))
    fi
  done
  rm -rf "$tmp"

  if (( copied > 0 )); then
    chmod +x "${LIB_DIR}/aestun-linux-amd64" "${LIB_DIR}/aestun-linux-arm64" 2>/dev/null || true
    msg "Core fetched into ${LIB_DIR} (${copied} item(s))."
    return 0
  fi
  err "Nothing usable found in the downloaded archive."
  return 1
}

# ---------------------------------------------------------------------- install bin
ensure_binary() {
  local tag; tag="$(arch_tag)"
  if [[ "$tag" == "unknown" ]]; then
    err "Unsupported CPU architecture: $(uname -m). Only amd64/arm64 are supported."
    return 1
  fi
  local pre="${LIB_DIR}/aestun-linux-${tag}"
  if [[ -f "$pre" ]]; then
    install -m 0755 "$pre" "$BIN_DST"
    msg "Installed prebuilt binary: $BIN_DST (${tag})"
    return 0
  fi
  if command -v go >/dev/null 2>&1 && [[ -f "${LIB_DIR}/main.go" ]]; then
    warn "No prebuilt binary found; building from source with Go..."
    check_build_deps
    ( cd "$LIB_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$tag" go build -trimpath -ldflags "-s -w" -o "$BIN_DST" . )
    [[ -f "$BIN_DST" ]] && { msg "Built and installed."; return 0; }
  fi
  warn "No local binary or source found next to $(basename "$SELF") — fetching automatically."
  fetch_core || return 1
  if [[ -f "$pre" ]]; then
    install -m 0755 "$pre" "$BIN_DST"
    msg "Installed prebuilt binary: $BIN_DST (${tag})"
    return 0
  fi
  if command -v go >/dev/null 2>&1 && [[ -f "${LIB_DIR}/main.go" ]]; then
    check_build_deps
    ( cd "$LIB_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$tag" go build -trimpath -ldflags "-s -w" -o "$BIN_DST" . )
    [[ -f "$BIN_DST" ]] && { msg "Built and installed."; return 0; }
  fi
  err "No suitable binary (aestun-linux-${tag}) found and Go is unavailable."
  return 1
}

auto_bootstrap() {
  local tag; tag="$(arch_tag)"
  [[ "$tag" == "unknown" ]] && return 0
  [[ -f "${LIB_DIR}/aestun-linux-${tag}" || -f "${LIB_DIR}/main.go" || -x "$BIN_DST" ]] && return 0
  hdr "First run — fetching the tunnel core (one-time)"
  fetch_core || warn "Auto-fetch failed; you can retry with: $0 fetch-core"
}

# ------------------------------------------------------------------ systemd service
write_service() {
  cat > "$SERVICE" <<EOF
[Unit]
Description=aestun - AES-256-GCM obfuscated server-to-server tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BIN_DST} -config ${CONF}
ExecStartPost=-${MGR_DST} fwd-rule add
ExecStopPost=-${MGR_DST} fwd-rule del
Restart=always
RestartSec=2
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN
RuntimeDirectory=aestun
LogsDirectory=aestun

[Install]
WantedBy=multi-user.target
EOF
}

# ------------------------------------------------------------------- write config
# Note: "listen": ":PORT" binds dual-stack (both IPv4 and IPv6) on Linux
write_config() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF" <<EOF
{
  "role": "${CFG_ROLE}",
  "key": "${CFG_KEY}",
  "cipher": "${CFG_CIPHER:-aes-gcm}",
  "listen": ":${CFG_LISTEN_PORT}",
  "peer": "${CFG_PEER}",
  "transport": "${CFG_TRANSPORT:-udp}",
  "obfs": "${CFG_OBFS:-quic}",
  "sni": "${CFG_SNI:-www.play.google.com}",
  "tun_name": "${CFG_TUN:-tun0}",
  "local_ip": "${CFG_LOCAL_IP}",
  "peer_ip": "${CFG_PEER_IP}",
  "mtu": ${CFG_MTU:-1280},
  "txqueuelen": ${CFG_TXQ:-1000},
  "rcvbuf": ${CFG_BUF:-8388608},
  "sndbuf": ${CFG_BUF:-8388608},
  "pad_max": ${CFG_PAD:-64},
  "rekey_interval": ${CFG_REKEY:-3600},
  "keepalive": ${CFG_KA:-25},
  "manage_ip": true,
  "stats_path": "${STATS}",
  "dpi_log": {
    "enabled": ${CFG_DPI:-true},
    "path": "${DPI_LOG}",
    "probe": ${CFG_DPI_PROBE:-true}
  },
  "desync": { "enabled": ${CFG_DESYNC:-true}, "repeats": ${CFG_DESYNC_REP:-4}, "autottl": true, "delta": -1, "badsum": ${CFG_DESYNC_BADSUM:-false} },
  "junk":   { "enabled": ${CFG_JUNK:-true}, "count": ${CFG_JUNK_COUNT:-8}, "min_ms": 5, "max_ms": 50 },
  "hop":    { "enabled": ${CFG_HOP:-true}, "ports": [${CFG_HOP_PORTS:-443, 8443, 2053, 2083, 2087, 2096}], "interval": ${CFG_HOP_INT:-30} },
  "split":  { "enabled": ${CFG_SPLIT:-false}, "frag_pos": 24 },
  "forwards": ${CFG_FWD_JSON:-[]}
}
EOF
  chmod 600 "$CONF"
  msg "Config written: $CONF"
}

open_firewall() {
  local port="$1" proto="${2:-udp}"
  is_port "$port" || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
      || ip6tables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
}

close_firewall() {
  local port="$1" proto="${2:-udp}"
  is_port "$port" || return 0
  command -v ufw >/dev/null 2>&1 && ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
  command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
  command -v ip6tables >/dev/null 2>&1 && ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
}

port_is_bound() {
  local port="$1" proto="${2:-udp}"
  command -v ss >/dev/null 2>&1 || return 1
  if [[ "$proto" == "udp" ]]; then
    ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
  else
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
  fi
}

fw_rule_present() {
  local port="$1" proto="${2:-udp}"
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
}

# =============================================================================
#  Network optimization (Ubuntu sysctl tuning for IPv4 + IPv6 tunnel)
# =============================================================================
apply_network_opt() {
  local cc="${1:-bbr}" buf="${2:-16777216}" fwd="${3:-1}"

  if [[ "$cc" == "bbr" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr > "$BBR_MODCONF"
  fi

  cat > "$SYSCTL_FILE" <<EOF
# Managed by aestun installer — network optimization for IPv4 & IPv6 tunnel.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}

net.core.rmem_max = ${buf}
net.core.wmem_max = ${buf}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096

net.ipv4.tcp_rmem = 4096 1048576 ${buf}
net.ipv4.tcp_wmem = 4096 65536 ${buf}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.ip_forward = ${fwd}
net.ipv6.conf.all.forwarding = ${fwd}
net.ipv6.conf.default.forwarding = ${fwd}
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.bindv6only = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_checksum = 0
net.netfilter.nf_conntrack_tcp_be_liberal = 1
EOF

  sysctl --system >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward="${fwd}" >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding="${fwd}" >/dev/null 2>&1 || true
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1 || true
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1 || true
  local active; active="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [[ "$active" == "$cc" ]]; then
    msg "Network optimization applied (congestion=${active}, buf=$(human "$buf"), ip_forward=${fwd})."
  else
    warn "Optimization applied, but congestion control is '${active}' (requested '${cc}')."
  fi
}

remove_network_opt() {
  rm -f "$SYSCTL_FILE" "$BBR_MODCONF"
  sysctl --system >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
  msg "Network optimization removed and runtime values reset to defaults (cubic/pfifo_fast)."
}

ensure_sock_buf_ceiling() {
  local want="${1:-16777216}" cur
  cur="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  (( cur < want )) && { sysctl -w net.core.rmem_max="$want" >/dev/null 2>&1 || true; }
  cur="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
  (( cur < want )) && { sysctl -w net.core.wmem_max="$want" >/dev/null 2>&1 || true; }
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/98-aestun-bufmin.conf <<EOF
net.core.rmem_max = ${want}
net.core.wmem_max = ${want}
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.bindv6only = 0
EOF
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
}

ensure_loose_rp_filter() {
  local tun="${1:-tun0}" f
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1 || true
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1 || true
  for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [[ -w "$f" ]] && echo 0 > "$f" 2>/dev/null || true
  done
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/97-aestun-rpfilter.conf <<EOF
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${tun}.rp_filter = 0
net.netfilter.nf_conntrack_checksum = 0
net.netfilter.nf_conntrack_tcp_be_liberal = 1
EOF
}

# Explicitly ensure tun0 interface, IPv4 (10.8.0.1 <-> 10.8.0.2), IPv6 (fd00:aest:1::1 <-> fd00:aest:1::2), and kernel routes are UP
ensure_tun_network() {
  [[ -f "$CONF" ]] || return 0
  local tun role local_ip peer_ip mtu txq i local_ip6 peer_ip6
  tun="$(json_get "$CONF" tun_name)"; tun="${tun:-tun0}"
  role="$(json_get "$CONF" role)"
  local_ip="$(json_get "$CONF" local_ip)"
  peer_ip="$(json_get "$CONF" peer_ip)"
  mtu="$(json_get "$CONF" mtu)"; mtu="${mtu:-1280}"
  txq="$(json_get "$CONF" txqueuelen)"; txq="${txq:-1000}"

  if [[ "$role" == "b" ]]; then
    local_ip6="fd00:aest:1::2/64"
    peer_ip6="fd00:aest:1::1"
  else
    local_ip6="fd00:aest:1::1/64"
    peer_ip6="fd00:aest:1::2"
  fi

  for i in {1..15}; do
    ip link show "$tun" >/dev/null 2>&1 && break
    sleep 0.2
  done

  if ip link show "$tun" >/dev/null 2>&1; then
    sysctl -w "net.ipv6.conf.${tun}.disable_ipv6=0" >/dev/null 2>&1 || true
    ip link set dev "$tun" up mtu "$mtu" txqueuelen "$txq" 2>/dev/null || true
    if [[ -n "$local_ip" ]]; then
      ip -4 addr add "$local_ip" dev "$tun" 2>/dev/null || true
    fi
    if [[ -n "$peer_ip" ]]; then
      ip -4 route replace "${peer_ip}/32" dev "$tun" scope link 2>/dev/null || true
      ip -4 route replace 10.8.0.0/24 dev "$tun" 2>/dev/null || true
    fi
    ip -6 addr add "$local_ip6" dev "$tun" 2>/dev/null || true
    ip -6 route replace "${peer_ip6}/128" dev "$tun" 2>/dev/null || true
    ip -6 route replace fd00:aest:1::/64 dev "$tun" 2>/dev/null || true
    [[ -w "/proc/sys/net/ipv4/conf/${tun}/rp_filter" ]] && echo 0 > "/proc/sys/net/ipv4/conf/${tun}/rp_filter" 2>/dev/null || true
  fi
}

show_network_opt() {
  hdr "Current network settings"
  local keys=(
    net.ipv4.tcp_congestion_control
    net.core.default_qdisc
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_fastopen
    net.ipv4.ip_forward
    net.ipv6.conf.all.forwarding
    net.ipv4.conf.all.rp_filter
  )
  local k v
  for k in "${keys[@]}"; do
    v="$(sysctl -n "$k" 2>/dev/null || echo '-')"
    printf '  %-38s = %s%s%s\n' "$k" "$W" "$v" "$N"
  done
  printf '  available congestion controls        = %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '-')"
  if [[ -f "$SYSCTL_FILE" ]]; then
    msg "aestun tuning file present: $SYSCTL_FILE"
  else
    warn "aestun tuning not installed."
  fi
}

# =============================================================================
#  Port forwarding & tunnel firewall rules (IPv4 & IPv6)
# =============================================================================
fwd_list_from_conf() {
  [[ -f "$CONF" ]] || return 0
  python3 - "$CONF" <<'PY' 2>/dev/null
import json,sys
try:
    with open(sys.argv[1]) as fp:
        c=json.load(fp)
    for f in c.get("forwards",[]) or []:
        p=f.get("port","")
        tp=f.get("target_port",p)
        pr=f.get("proto","tcp")
        if p:
            print(f"{p} {tp} {pr}")
except Exception:
    pass
PY
}

fwd_flush_all() {
  local ipt table chain rest
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    for table in nat filter mangle; do
      for chain in PREROUTING POSTROUTING INPUT OUTPUT FORWARD; do
        while IFS= read -r rest; do
          [[ -n "$rest" ]] || continue
          # shellcheck disable=SC2086
          "$ipt" -t "$table" -D "$chain" $rest 2>/dev/null || true
        done < <("$ipt" -t "$table" -S "$chain" 2>/dev/null \
                   | sed -n "s/^-A ${chain} //p" \
                   | grep -F -- '--comment aestun-fwd')
      done
    done
  done
}

fwd_apply() {
  [[ -f "$CONF" ]] || return 0
  command -v iptables >/dev/null 2>&1 || ensure_deps
  sync_clock_http

  local peer_ip tun listen lport transport peer peer_host peer_v4="" peer_v6=""
  peer_ip="$(json_get "$CONF" peer_ip)"
  tun="$(json_get "$CONF" tun_name)"; tun="${tun:-tun0}"
  listen="$(json_get "$CONF" listen)"; lport="${listen##*:}"
  transport="$(json_get "$CONF" transport)"; transport="${transport:-udp}"
  peer="$(json_get "$CONF" peer)"
  peer_host="$(peer_extract_host "$peer")"

  if [[ -n "$peer_host" ]]; then
    if is_ipv4 "$peer_host"; then
      peer_v4="$peer_host"
    elif is_ipv6 "$peer_host"; then
      peer_v6="$peer_host"
    elif command -v getent >/dev/null 2>&1; then
      peer_v4="$(getent ahostsv4 "$peer_host" 2>/dev/null | awk '{print $1; exit}')"
      peer_v6="$(getent ahostsv6 "$peer_host" 2>/dev/null | awk '{print $1; exit}')"
    fi
  fi

  ensure_loose_rp_filter "$tun"
  ensure_tun_network
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true

  fwd_flush_all

  # 1. Bypass any UFW / host firewall drops on tun0 (both IPv4 10.8.0.0/24 and IPv6 fd00:aest:1::/64)
  iptables -I INPUT 1 -i "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  iptables -I OUTPUT 1 -o "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  iptables -I INPUT 1 -s 10.8.0.0/24 -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  iptables -I OUTPUT 1 -d 10.8.0.0/24 -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD 1 -i "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD 1 -o "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  iptables -t nat -I POSTROUTING 1 -s 10.8.0.0/24 -o "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT 1 -i "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I OUTPUT 1 -o "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT 1 -s fd00:aest:1::/64 -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I OUTPUT 1 -d fd00:aest:1::/64 -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I FORWARD 1 -i "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I FORWARD 1 -o "$tun" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT 1 -p ipv6-icmp -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I OUTPUT 1 -p ipv6-icmp -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  fi

  # 2. Clamp TCP MSS to PMTU on both directions of the tunnel (IPv4 and IPv6)
  iptables -t mangle -I FORWARD 1 -o "$tun" -p tcp -m tcp --tcp-flags SYN,RST SYN \
    -m comment --comment aestun-fwd -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -I FORWARD 1 -i "$tun" -p tcp -m tcp --tcp-flags SYN,RST SYN \
    -m comment --comment aestun-fwd -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t mangle -I FORWARD 1 -o "$tun" -p tcp -m tcp --tcp-flags SYN,RST SYN \
      -m comment --comment aestun-fwd -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t mangle -I FORWARD 1 -i "$tun" -p tcp -m tcp --tcp-flags SYN,RST SYN \
      -m comment --comment aestun-fwd -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  fi

  # 3. Unconditionally allow all carrier packets from/to the peer server IP (IPv4 & IPv6)
  if [[ -n "$peer_v4" ]]; then
    iptables -I INPUT 1 -s "$peer_v4" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    iptables -I OUTPUT 1 -d "$peer_v4" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  fi
  if [[ -n "$peer_v6" ]] && command -v ip6tables >/dev/null 2>&1; then
    ip6tables -I INPUT 1 -s "$peer_v6" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    ip6tables -I OUTPUT 1 -d "$peer_v6" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
  fi

  # 4. Open main carrier listen port & all hop ports (both IPv4 and IPv6)
  if [[ -n "$lport" ]]; then
    open_firewall "$lport" udp
    open_firewall "$lport" tcp
    iptables -I INPUT 1 -p udp --dport "$lport" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p tcp --dport "$lport" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
      ip6tables -I INPUT 1 -p udp --dport "$lport" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
      ip6tables -I INPUT 1 -p tcp --dport "$lport" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
    fi
  fi

  if [[ -f "$CONF" ]] && command -v python3 >/dev/null 2>&1; then
    local hop_ports p
    hop_ports="$(python3 - "$CONF" <<'PY' 2>/dev/null
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    h=c.get("hop",{})
    if isinstance(h,dict) and h.get("enabled"):
        print(" ".join(str(x) for x in h.get("ports",[])))
except Exception:
    pass
PY
)"
    for p in $hop_ports; do
      open_firewall "$p" udp
      open_firewall "$p" tcp
      iptables -I INPUT 1 -p udp --dport "$p" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
      command -v ip6tables >/dev/null 2>&1 && ip6tables -I INPUT 1 -p udp --dport "$p" -m comment --comment aestun-fwd -j ACCEPT 2>/dev/null || true
      if [[ -n "$lport" && "$p" != "$lport" ]]; then
        if [[ -n "$peer_v4" ]]; then
          iptables -t nat -I PREROUTING 1 ! -i "$tun" -s "$peer_v4" -p udp --dport "$p" \
            -m comment --comment aestun-fwd -j REDIRECT --to-ports "$lport" 2>/dev/null || true
        else
          iptables -t nat -I PREROUTING 1 ! -i "$tun" -p udp --dport "$p" \
            -m comment --comment aestun-fwd -j REDIRECT --to-ports "$lport" 2>/dev/null || true
        fi
        if command -v ip6tables >/dev/null 2>&1; then
          if [[ -n "$peer_v6" ]]; then
            ip6tables -t nat -I PREROUTING 1 ! -i "$tun" -s "$peer_v6" -p udp --dport "$p" \
              -m comment --comment aestun-fwd -j REDIRECT --to-ports "$lport" 2>/dev/null || true
          else
            ip6tables -t nat -I PREROUTING 1 ! -i "$tun" -p udp --dport "$p" \
              -m comment --comment aestun-fwd -j REDIRECT --to-ports "$lport" 2>/dev/null || true
          fi
        fi
      fi
    done
  fi

  [[ -n "$peer_ip" ]] || { warn "fwd_apply: peer_ip missing from config, skipping DNAT."; return 1; }

  # 5. Apply user port forwards
  local rows; rows="$(fwd_list_from_conf)"
  local port tport proto n=0
  while read -r port tport proto; do
    [[ -z "$port" ]] && continue
    tport="${tport:-$port}"
    proto="${proto:-tcp}"
    local protos=("$proto")
    [[ "$proto" == "both" ]] && protos=(tcp udp)
    local pr
    for pr in "${protos[@]}"; do
      [[ "$port" == "$lport" && "$pr" == "$transport" ]] && continue
      if [[ -n "$peer_v4" ]]; then
        iptables -t nat -A PREROUTING ! -i "$tun" ! -s "$peer_v4" ! -d 10.8.0.0/24 -p "$pr" --dport "$port" \
          -m comment --comment aestun-fwd \
          -j DNAT --to-destination "${peer_ip}:${tport}"
      else
        iptables -t nat -A PREROUTING ! -i "$tun" ! -d 10.8.0.0/24 -p "$pr" --dport "$port" \
          -m comment --comment aestun-fwd \
          -j DNAT --to-destination "${peer_ip}:${tport}"
      fi
      iptables -t nat -A POSTROUTING -o "$tun" -p "$pr" --dport "$tport" -d "$peer_ip" \
        -m comment --comment aestun-fwd \
        -j MASQUERADE
      open_firewall "$port" "$pr"
      n=$(( n + 1 ))
    done
  done <<< "$rows"

  if (( n > 0 )); then
    msg "Applied ${n} port-forward rule(s) over ${tun} -> ${peer_ip}."
  fi
  return 0
}

fwd_rule() {
  case "${1:-}" in
    add) fwd_apply ;;
    del) fwd_flush_all; return 0 ;;
    *) echo "usage: $0 fwd-rule {add|del}" >&2; return 1 ;;
  esac
}

fwd_add() {
  local port="$1" tport="$2" proto="$3"
  python3 - "$CONF" "$port" "$tport" "$proto" <<'PY'
import json,sys
p,port,tport,proto=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),sys.argv[4]
with open(p) as fp:
    c=json.load(fp)
protos = ["tcp","udp"] if proto == "both" else [proto]
fw=[f for f in (c.get("forwards",[]) or []) if not (f.get("port")==port and f.get("proto") in protos)]
for pr in protos:
    fw.append({"port":port,"target_port":tport,"proto":pr})
c["forwards"]=fw
with open(p,"w") as fp:
    json.dump(c,fp,indent=2)
PY
  chmod 600 "$CONF"
}

fwd_remove() {
  local port="$1" proto="$2"
  python3 - "$CONF" "$port" "$proto" <<'PY'
import json,sys
p,port,proto=sys.argv[1],int(sys.argv[2]),sys.argv[3]
with open(p) as fp:
    c=json.load(fp)
protos = ["tcp","udp"] if proto == "both" else [proto]
c["forwards"]=[f for f in (c.get("forwards",[]) or []) if not (f.get("port")==port and f.get("proto") in protos)]
with open(p,"w") as fp:
    json.dump(c,fp,indent=2)
PY
  chmod 600 "$CONF"
}

fwd_prompt_ports_simple() {
  local def="${1:-}" prompt csv port
  if [[ -n "$def" ]]; then
    prompt="Port(s) to forward — comma separated, e.g. 1080,443 (type 'none' to disable)"
  else
    prompt="Port(s) to forward — comma separated, e.g. 1080,443 (Enter = none)"
  fi
  csv="$(ask "$prompt" "$def")" || return 0
  [[ -z "$csv" || "$csv" == "none" || "$csv" == "-" ]] && return 0
  local -a sp
  IFS=',' read -ra sp <<< "$(printf '%s' "$csv" | tr -d ' ')"
  for port in "${sp[@]}"; do
    [[ -z "$port" ]] && continue
    if ! is_port "$port"; then
      warn "  skipping invalid port: $port"
      continue
    fi
    printf '%s %s tcp\n' "$port" "$port"
    printf '%s %s udp\n' "$port" "$port"
  done
}

fwd_wizard_collect() {
  local items=() port tport proto existing_csv=""
  if [[ -f "$CONF" ]]; then
    existing_csv="$(fwd_list_from_conf | awk '!seen[$1]++ {printf "%s%s", sep, $1; sep=","}')"
  fi
  printf '\n%sPort forwarding%s — ports entered here are exposed on THIS (Iran) server and\n' "$BOLD" "$N"
  printf 'transparently forwarded (TCP + UDP) through the tunnel to the foreign server.\n'
  while read -r port tport proto; do
    [[ -z "$port" ]] && continue
    items+=("{\"port\":${port},\"target_port\":${tport},\"proto\":\"${proto}\"}")
    msg "  queued: ${port}/${proto} -> foreign:${tport}"
  done < <(fwd_prompt_ports_simple "$existing_csv")
  if (( ${#items[@]} == 0 )); then
    CFG_FWD_JSON="[]"
  else
    local IFS=,
    CFG_FWD_JSON="[${items[*]}]"
  fi
}

fwd_menu() {
  while true; do
    clear
    hdr "Port Forwarding (DNAT + MASQUERADE)"
    if [[ ! -f "$CONF" ]]; then warn "Set up the tunnel first."; pause; return; fi
    local role; role="$(json_get "$CONF" role)"
    [[ "$role" == "a" ]] || printf '%sNote: forwarding is normally configured on the Iran (role a) server.%s\n\n' "$Y" "$N"
    printf 'Current forwards:\n'
    local rows; rows="$(fwd_list_from_conf)"
    if [[ -z "$rows" ]]; then
      printf '  (none)\n'
    else
      printf '  %-8s %-8s %-6s\n' "PORT" "TARGET" "PROTO"
      printf '%s\n' "$rows" | awk '{printf "  %-8s %-8s %-6s\n",$1,$2,$3}'
    fi
    cat <<EOF

  ${C}1${N}) Add forward(s)
  ${C}2${N}) Remove forward(s)
  ${C}3${N}) Re-apply rules now
  ${C}0${N}) Back
EOF
    local c; c="$(ask 'Select' '0')" || return
    case "$c" in
      1)
        local ports_csv proto port n=0
        ports_csv="$(ask "Public port(s) to forward — comma separated (e.g. 443,2083)" "")"
        proto="$(ask_choice "Protocol" "both" "both" "tcp" "udp")"
        local -a add_ports
        IFS=',' read -ra add_ports <<< "$(printf '%s' "$ports_csv" | tr -d ' ')"
        for port in "${add_ports[@]}"; do
          [[ -z "$port" ]] && continue
          if ! is_port "$port"; then warn "  skipping invalid port: $port"; continue; fi
          fwd_add "$port" "$port" "$proto"
          n=$(( n + 1 ))
        done
        if (( n > 0 )); then
          fwd_apply
          msg "${n} port(s) added and applied."
        else
          err "No valid ports entered."
        fi
        pause ;;
      2)
        local ports_csv proto port
        ports_csv="$(ask "Public port(s) to remove — comma separated" "")"
        proto="$(ask_choice "Protocol to remove" "both" "both" "tcp" "udp")"
        local -a rm_ports
        IFS=',' read -ra rm_ports <<< "$(printf '%s' "$ports_csv" | tr -d ' ')"
        for port in "${rm_ports[@]}"; do
          is_port "$port" || continue
          fwd_remove "$port" "$proto"
          if [[ "$proto" == "both" ]]; then
            close_firewall "$port" tcp
            close_firewall "$port" udp
          else
            close_firewall "$port" "$proto"
          fi
        done
        fwd_apply
        msg "Forward(s) removed."
        pause ;;
      3) fwd_apply; pause ;;
      0) return ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Streamlined Interactive Setup (Protocol prompt + IPv4/IPv6 support + Auto-Y defaults)
# =============================================================================
interactive_setup() {
  hdr "aestun Tunnel Setup (IPv4 & IPv6)"
  sync_mgr_bin
  ensure_deps
  sync_clock_http
  ensure_binary || { pause; return 1; }

  printf '\n'
  detect_public_ips

  # 1. Server Role
  printf '\n%sWhich side is THIS server?%s\n' "$BOLD" "$N"
  printf '  %s1%s) Iran server    (inside / behind DPI)  -> role a, tunnel IP 10.8.0.1\n' "$C" "$N"
  printf '  %s2%s) Foreign server (outside / exit)       -> role b, tunnel IP 10.8.0.2\n' "$C" "$N"
  local sel; sel="$(ask "Select" "1")" || return 1
  if [[ "$sel" == "2" ]]; then
    CFG_ROLE="b"; CFG_LOCAL_IP="10.8.0.2/24"; CFG_PEER_IP="10.8.0.1"
  else
    CFG_ROLE="a"; CFG_LOCAL_IP="10.8.0.1/24"; CFG_PEER_IP="10.8.0.2"
  fi

  # 2. Connection Protocol (1 = tcp, 2 = udp)
  printf '\n%sConnection protocol (must match on BOTH servers):%s\n' "$BOLD" "$N"
  printf '  %s1%s) tcp\n' "$C" "$N"
  printf '  %s2%s) udp\n' "$C" "$N"
  local proto_sel; proto_sel="$(ask "Select" "1")" || return 1
  if [[ "$proto_sel" == "2" || "${proto_sel,,}" == "udp" ]]; then
    CFG_TRANSPORT="udp"
  else
    CFG_TRANSPORT="tcp"
  fi

  # 3. Shared Key (automatic)
  local existing=""
  [[ -f "$CONF" ]] && existing="$(json_get "$CONF" key)"
  if [[ -n "$existing" ]]; then
    CFG_KEY="$existing"
  else
    CFG_KEY="$DEFAULT_PSK"
  fi

  # 4. Fixed identical Cipher & Obfuscation on both ends
  CFG_CIPHER="aes-gcm"
  CFG_OBFS="quic"
  CFG_SNI="www.play.google.com"
  CFG_LISTEN_PORT="$DEFAULT_PORT"
  is_port "$CFG_LISTEN_PORT" || CFG_LISTEN_PORT=2087

  # 5. Remote Server Public IP (supports IPv4, IPv6, or domain)
  printf '\n'
  local raw_host phost
  while true; do
    raw_host="$(ask_req "Public IPv4 / IPv6 / domain of the OTHER server")" || return 1
    phost="$(normalize_host_input "$raw_host")"
    if looks_like_bare_port "$phost" || [[ -z "$phost" ]]; then
      err "  '$raw_host' looks like a port number. Enter the OTHER server's IPv4, IPv6, or domain."
      continue
    fi
    break
  done
  CFG_PEER="$(format_peer_endpoint "$phost" "$CFG_LISTEN_PORT")"
  if is_ipv6 "$phost"; then
    msg "Remote endpoint configured over IPv6: ${CFG_PEER} (${CFG_TRANSPORT})"
  else
    msg "Remote endpoint configured over IPv4/Host: ${CFG_PEER} (${CFG_TRANSPORT})"
  fi

  # 6. Automatic Tunnel Parameters, DPI Logging & Anti-DPI Hardening (All set to Y/default automatically)
  CFG_TUN="tun0"
  CFG_MTU=1280
  CFG_TXQ=1000
  CFG_PAD=64
  CFG_REKEY=3600
  CFG_KA=25
  CFG_BUF=8388608

  CFG_DPI=true
  CFG_DPI_PROBE=true

  CFG_DESYNC=true
  CFG_DESYNC_REP=4
  CFG_DESYNC_BADSUM=false
  CFG_SPLIT=false
  CFG_JUNK=true
  CFG_JUNK_COUNT=8
  CFG_HOP=true
  CFG_HOP_PORTS="443, 8443, 2053, 2083, 2087, 2096"
  CFG_HOP_INT=30

  printf '\n'
  msg "Tunnel endpoints : ${CFG_LOCAL_IP%/*} <-> ${CFG_PEER_IP} (${CFG_TUN}, MTU ${CFG_MTU}, proto=${CFG_TRANSPORT})"
  msg "Tunnel parameters: txq=${CFG_TXQ}, pad=${CFG_PAD}, rekey=${CFG_REKEY}s, keepalive=${CFG_KA}s, buf=${CFG_BUF}"
  msg "DPI & probe log  : enabled=Y, round-trip probes=Y"
  msg "Anti-DPI modules : desync=Y, junk=Y, port-hop=Y (${CFG_HOP_PORTS})"

  # 7. Port Forwarding (asked only on Iran server)
  CFG_FWD_JSON="[]"
  if [[ "$CFG_ROLE" == "a" ]]; then
    fwd_wizard_collect
  fi

  write_config
  ensure_sock_buf_ceiling 16777216
  ensure_loose_rp_filter "$CFG_TUN"
  write_service
  systemctl daemon-reload

  # 8. Apply Ubuntu Network Optimization & IP Forwarding (IPv4 + IPv6) automatically (no prompts)
  apply_network_opt "bbr" "16777216" "1"

  # 9. Start service, apply firewall & tunnel interface routing, enable watchdog
  systemctl enable --now aestun >/dev/null 2>&1 || true
  systemctl restart aestun >/dev/null 2>&1 && msg "Service enabled and started."
  fwd_apply
  write_watchdog_units

  printf '\n'
  msg "Done on the ${CFG_ROLE^^} side (${CFG_LOCAL_IP%/*} -> ${CFG_PEER_IP})."
  printf '\n'; hdr "Quick self-check on THIS side"
  sleep 2
  diag_report || true
  return 0
}

# ------------------------------------------------------------------ service control
svc() { systemctl "$1" aestun && msg "service: $1 done." || err "operation '$1' failed."; }

service_menu() {
  while true; do
    clear
    local st; st="$(svc_active aestun)"
    hdr "Service Management (state: ${st})"
    cat <<EOF

  ${C}1${N}) Start service
  ${C}2${N}) Stop service
  ${C}3${N}) Restart service
  ${C}4${N}) Enable at boot
  ${C}5${N}) Disable at boot
  ${C}6${N}) Full systemd status
  ${C}0${N}) Back
EOF
    local __c; __c="$(ask 'Select' '0')" || return
    case "$__c" in
      1) svc start; fwd_apply; pause ;;
      2) svc stop; pause ;;
      3) svc restart; fwd_apply; pause ;;
      4) svc enable; pause ;;
      5) svc disable; pause ;;
      6) systemctl --no-pager status aestun | head -n 25; pause ;;
      0) return ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------- live monitor
monitor() {
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; pause; return; }
  local iface; iface="$(json_get "$CONF" tun_name)"; iface="${iface:-tun0}"
  local prev_tx=0 prev_rx=0 first=1 prev_epoch
  prev_epoch="$(date +%s)"
  while true; do
    local now_tx now_rx txp rxp af rd up peer lastrx nowu rekey
    now_tx="$(json_get "$STATS" tx_bytes)";  now_rx="$(json_get "$STATS" rx_bytes)"
    txp="$(json_get "$STATS" tx_packets)";   rxp="$(json_get "$STATS" rx_packets)"
    af="$(json_get "$STATS" auth_fail)";     rd="$(json_get "$STATS" replay_drop)"
    up="$(json_get "$STATS" uptime_seconds)"; peer="$(json_get "$STATS" peer)"
    lastrx="$(json_get "$STATS" last_rx_unix)"; nowu="$(json_get "$STATS" now_unix)"
    rekey="$(json_get "$STATS" rekey_interval)"
    : "${now_tx:=0}" "${now_rx:=0}" "${txp:=0}" "${rxp:=0}" "${af:=0}" "${rd:=0}" "${up:=0}" "${lastrx:=0}" "${nowu:=0}" "${rekey:=0}"

    local now_epoch el dtx=0 drx=0
    now_epoch="$(date +%s)"; el=$(( now_epoch - prev_epoch )); (( el < 1 )) && el=1
    if [[ $first -eq 0 ]]; then
      dtx=$(( (now_tx - prev_tx) / el ))
      drx=$(( (now_rx - prev_rx) / el ))
    fi
    (( dtx < 0 )) && dtx=0; (( drx < 0 )) && drx=0
    prev_tx=$now_tx; prev_rx=$now_rx; prev_epoch=$now_epoch; first=0

    local svc_state; svc_state="$(svc_active aestun)"
    local svc_c="$R"; [[ "$svc_state" == active ]] && svc_c="$G"

    local link="down" link_c="$R"
    if ip link show "$iface" >/dev/null 2>&1; then
      if ip link show "$iface" 2>/dev/null | grep -q "state UP\|UNKNOWN"; then link="up"; link_c="$G"; fi
    fi

    local age="-" age_c="$Y"
    if [[ "$lastrx" -gt 0 ]]; then
      age=$(( now_epoch - lastrx ))
      (( age < 0 )) && age=0
      (( age <= 15 )) && age_c="$G"
      age="${age}s"
    fi

    local rk="static"; [[ "$rekey" -gt 0 ]] && rk="every ${rekey}s"

    clear
    printf '%s\n' "${BOLD}${C}+-- aestun live monitor -------------------------------+${N}"
    printf '  service  : %s%-8s%s   interface %s: %s%s%s\n' "$svc_c" "$svc_state" "$N" "$iface" "$link_c" "$link" "$N"
    printf '  uptime   : %-12s last RX: %s%s%s ago\n' "$(fmt_dur "$up")" "$age_c" "$age" "$N"
    printf '  peer     : %s%s%s\n' "$W" "${peer:--}" "$N"
    printf '%s\n' "${C}+-- traffic -------------------------------------------+${N}"
    printf '  TX : %s%12s%s  (%s%s%s/s)  packets: %s\n' "$W" "$(human "$now_tx")" "$N" "$G" "$(human "$dtx")" "$N" "$txp"
    printf '  RX : %s%12s%s  (%s%s%s/s)  packets: %s\n' "$W" "$(human "$now_rx")" "$N" "$G" "$(human "$drx")" "$N" "$rxp"
    printf '%s\n' "${C}+-- security ------------------------------------------+${N}"
    printf '  auth failures (auth_fail) : %s%s%s\n' "$Y" "$af" "$N"
    printf '  replay drops              : %s%s%s\n' "$Y" "$rd" "$N"
    printf '  key rotation              : %s\n' "$rk"

    local dpi probes scans inj repl ttla loss rtt bh ciph
    dpi="$(json_get "$STATS" dpi_enabled)"
    if [[ "$dpi" == "true" ]]; then
      probes="$(json_get "$STATS" dpi_probes)"; scans="$(json_get "$STATS" dpi_scans)"
      inj="$(json_get "$STATS" dpi_injections)"; repl="$(json_get "$STATS" dpi_replays)"
      ttla="$(json_get "$STATS" dpi_ttl_anomalies)"; loss="$(json_get "$STATS" loss_pct)"
      rtt="$(json_get "$STATS" rtt_ms)"; bh="$(json_get "$STATS" dpi_blackholed_now)"
      : "${probes:=0}" "${scans:=0}" "${inj:=0}" "${repl:=0}" "${ttla:=0}" "${loss:=-}" "${rtt:=-}"
      local pc="$G"
      (( probes > 0 || repl > 0 || inj > 0 || ttla > 0 )) 2>/dev/null && pc="$R"
      printf '%s\n' "${C}+-- DPI observer --------------------------------------+${N}"
      printf '  active probes / replays   : %s%s%s / %s%s%s\n' "$pc" "$probes" "$N" "$pc" "$repl" "$N"
      printf '  injections / TTL anomalies: %s%s%s / %s%s%s\n' "$pc" "$inj" "$N" "$pc" "$ttla" "$N"
      printf '  background scanning       : %s\n' "$scans"
      printf '  path loss / RTT           : %s%%  /  %s ms\n' "$loss" "$rtt"
      if [[ "$bh" == "true" ]]; then
        printf '  %scarrier looks BLOCKED — sending, nothing coming back%s\n' "$R" "$N"
      fi
    fi
    ciph="$(json_get "$STATS" cipher)"
    [[ -n "$ciph" ]] && printf '%s\n' "${D}  cipher: ${ciph}${N}"
    printf '%s\n' "${C}+------------------------------------------------------+${N}"
    printf '%s\n' "${D}refresh every 2s — press q to quit${N}"

    local key=""
    read -r -t 2 -n 1 key || true
    [[ "${key:-}" == "q" ]] && break
  done
}

# ------------------------------------------------------------------- connectivity
diag_report() {
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; return 1; }
  fwd_apply >/dev/null 2>&1 || true

  local transport port peer host peer_ip tun listen ok=1
  transport="$(json_get "$CONF" transport)"; transport="${transport:-udp}"
  listen="$(json_get "$CONF" listen)"; port="${listen##*:}"
  peer="$(json_get "$CONF" peer)"
  host="$(peer_extract_host "$peer")"
  peer_ip="$(json_get "$CONF" peer_ip)"
  tun="$(json_get "$CONF" tun_name)"; tun="${tun:-tun0}"

  local svc_state; svc_state="$(svc_active aestun)"
  if [[ "$svc_state" == "active" ]]; then
    msg "service: active"
  else
    err "service: ${svc_state} — check: journalctl -u aestun -n 50"
    ok=0
  fi

  local wd_state; wd_state="$(svc_active aestun-watchdog.timer)"
  if [[ "$wd_state" == "active" ]]; then
    msg "watchdog: active"
  else
    warn "watchdog: ${wd_state} — run setup (option 1) to enable"
  fi

  if ip link show "$tun" >/dev/null 2>&1; then
    if ip link show "$tun" 2>/dev/null | grep -q "state UP\|UNKNOWN"; then
      msg "interface ${tun}: up ($(ip -4 -o addr show dev "$tun" 2>/dev/null | awk '{print $4}' | head -1))"
    else
      err "interface ${tun}: exists but is DOWN"; ok=0
    fi
  else
    err "interface ${tun}: does not exist yet"; ok=0
  fi

  if [[ -n "$port" ]]; then
    if port_is_bound "$port" "$transport"; then
      msg "carrier port ${port}/${transport}: listening locally (IPv4/IPv6)"
    else
      err "carrier port ${port}/${transport}: nothing is listening locally"; ok=0
    fi
    if fw_rule_present "$port" "$transport"; then
      msg "local firewall: ${port}/${transport} allowed (iptables/ip6tables)"
    else
      open_firewall "$port" "$transport"
      msg "local firewall: ${port}/${transport} rule added"
    fi
  fi

  if [[ -n "$host" ]] && is_ipv6 "$host"; then
    printf '\nChecking IPv6 carrier reachability (%s)...\n' "$host"
    if ping -6 -c 2 -W 2 "$host" >/dev/null 2>&1; then
      msg "IPv6 carrier host ${host} is reachable."
    else
      warn "No ICMPv6 ping reply from ${host} (may just have ICMPv6 filtered)."
    fi
  fi

  if [[ -n "$peer_ip" ]]; then
    printf '\nPinging %s%s%s (peer tunnel IP)...\n\n' "$W" "$peer_ip" "$N"
    if ping -c 4 -W 2 "$peer_ip"; then
      printf '\n'; msg "tunnel link is healthy — ${peer_ip} replies."
    else
      printf '\n'; err "no reply from ${peer_ip} yet (make sure the OTHER server is also installed and running with the same protocol '${transport}')."
      ok=0
    fi
  else
    err "peer_ip not set in config."; ok=0
  fi

  if (( ok == 0 )); then
    return 1
  fi
  printf '\n'; msg "Everything checks out on this side."
  return 0
}

test_conn() {
  clear
  hdr "Connectivity Test & Diagnostics"
  diag_report || true
  pause
}

show_logs() {
  clear
  hdr "Live Logs (Ctrl+C to return)"
  journalctl -u aestun -f --no-hostname 2>/dev/null || journalctl -u aestun -n 50 --no-pager
}

edit_config() {
  [[ -f "$CONF" ]] || { err "No config present."; pause; return; }
  "${EDITOR:-nano}" "$CONF"
  if confirm "Restart the service and re-apply forwarding rules?"; then
    systemctl restart aestun && msg "Service restarted."
    fwd_apply
  fi
  pause
}

do_keygen() {
  ensure_binary || { pause; return; }
  clear
  hdr "Generate New Shared Key"
  local k; k="$("$BIN_DST" keygen)"
  printf '\nShared key (use the SAME key on both servers):\n\n   %s%s%s\n\n' "$BOLD" "$k" "$N"
  pause
}

show_config() {
  clear
  hdr "Current Configuration ($CONF)"
  if [[ -f "$CONF" ]]; then
    sed -E 's/("key"[[:space:]]*:[[:space:]]*")[^"]+(")/\1********\2/' "$CONF"
  else
    warn "Not configured yet."
  fi
  pause
}

# ----------------------------------------------------------- network optimization
netopt_menu() {
  while true; do
    clear
    hdr "Network Optimization"
    cat <<EOF

  ${C}1${N}) Show current settings
  ${C}2${N}) Apply / re-apply tuning (BBR + 16MB buffers + IP forwarding)
  ${C}3${N}) Remove tuning
  ${C}0${N}) Back
EOF
    local __c; __c="$(ask 'Select' '0')" || return
    case "$__c" in
      1) show_network_opt; pause ;;
      2) apply_network_opt "bbr" "16777216" "1"; pause ;;
      3) remove_network_opt; pause ;;
      0) return ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  zapret module (DPI desync on the tunnel carrier packets — IPv4 & IPv6)
# =============================================================================
zap_installed() { [[ -x "$ZAP_BIN" ]]; }

zap_install() {
  hdr "Install zapret (builds nfqws from source)"
  ensure_deps
  export DEBIAN_FRONTEND=noninteractive
  msg "Installing build dependencies..."
  apt-get update -y >/dev/null 2>&1 || true
  if ! apt-get install -y git iptables build-essential zlib1g-dev \
        libnetfilter-queue-dev libnfnetlink-dev libmnl-dev libcap-dev >/dev/null 2>&1; then
    err "Failed to install build dependencies (apt)."; pause; return
  fi

  if [[ -d "$ZAPRET_DIR/.git" ]]; then
    warn "Repo present; updating..."
    ( cd "$ZAPRET_DIR" && git pull --ff-only ) >/dev/null 2>&1 || warn "git pull failed (continuing)."
  else
    msg "Cloning zapret..."
    git clone --depth 1 https://github.com/bol-van/zapret "$ZAPRET_DIR" \
      || { err "git clone failed."; pause; return; }
  fi

  msg "Building nfqws..."
  if make -C "$ZAPRET_DIR/nfq" nfqws >/tmp/nfqws-build.log 2>&1 && zap_installed; then
    msg "zapret ready: ${ZAP_BIN}"
    "$ZAP_BIN" --version 2>/dev/null | head -1 || true
  else
    err "Build failed. Last lines of /tmp/nfqws-build.log:"
    tail -8 /tmp/nfqws-build.log
  fi
  pause
}

zap_enable() {
  hdr "Enable zapret on the tunnel port"
  zap_installed || { err "Install zapret first (option 1)."; pause; return; }
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; pause; return; }

  local peer host port qnum=200 transport desync
  peer="$(json_get "$CONF" peer)"
  host="$(peer_extract_host "$peer")"
  port="$(peer_extract_port "$peer")"
  [[ -z "$port" || -z "$host" ]] && { err "Could not read peer host/port from config."; pause; return; }
  transport="$(json_get "$CONF" transport)"; transport="${transport:-udp}"

  desync="--filter-tcp=${port} --dpi-desync=multisplit --dpi-desync-split-pos=1,4,8"
  desync+=" --new --dpi-desync=fake --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n8 --dpi-desync-repeats=2 --dpi-desync-fooling=badsum"
  printf 'Carrier = %s%s / %s:%s%s\n' "$W" "$transport" "$host" "$port" "$N"

  ensure_deps
  zap_rule del 2>/dev/null || true
  sync_mgr_bin

  cat > "$ZAP_SERVICE" <<EOF
[Unit]
Description=aestun-zapret - DPI desync (nfqws) for the tunnel carrier
After=network-online.target
Wants=network-online.target
Before=aestun.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=${MGR_DST} zap-rule add
ExecStart=${ZAP_BIN} --qnum=${qnum} ${desync}
ExecStartPost=-${MGR_DST} zap-rule rearm
ExecStopPost=-${MGR_DST} zap-rule del
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable aestun-zapret >/dev/null 2>&1
  systemctl restart aestun-zapret >/dev/null 2>&1 && msg "zapret enabled (${transport}/${port} desync via nfqws)."
  sleep 3
  local fired; fired="$(awk -v q="$qnum" '$1==q {print $8}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null)"
  if [[ -n "$fired" && "$fired" -gt 0 ]]; then
    msg "Desync fired on ${fired} carrier packet(s)."
  else
    warn "Queue armed (waiting for new carrier flow packets)."
  fi
  pause
}

zap_disable() {
  systemctl disable --now aestun-zapret >/dev/null 2>&1 || true
  zap_rule del 2>/dev/null || true
  msg "zapret disabled."
  pause
}

zap_status() {
  hdr "zapret Status"
  if zap_installed; then msg "installed: yes (${ZAPRET_DIR})"; else warn "installed: no"; fi
  systemctl --no-pager status aestun-zapret 2>/dev/null | head -n 12 || warn "zapret service not active."
  printf '\niptables/ip6tables rules (mangle/OUTPUT):\n'
  iptables -t mangle -S OUTPUT 2>/dev/null | grep NFQUEUE || true
  command -v ip6tables >/dev/null 2>&1 && ip6tables -t mangle -S OUTPUT 2>/dev/null | grep NFQUEUE || true
  pause
}

zap_remove() {
  systemctl disable --now aestun-zapret >/dev/null 2>&1 || true
  zap_rule del 2>/dev/null || true
  rm -f "$ZAP_SERVICE" "$ZAP_RULES"
  systemctl daemon-reload
  confirm "Also delete ${ZAPRET_DIR}?" && rm -rf "$ZAPRET_DIR"
  msg "zapret removed."
  pause
}

zapret_menu() {
  while true; do
    clear
    local ins="no"; zap_installed && ins="yes"
    local act; act="$(svc_active aestun-zapret)"
    hdr "Zapret Module (installed: ${ins} | service: ${act})"
    cat <<EOF

  ${C}1${N}) Install / update zapret
  ${C}2${N}) Enable on tunnel port
  ${C}3${N}) Disable zapret
  ${C}4${N}) Status & queue health
  ${C}5${N}) Remove completely
  ${C}0${N}) Back
EOF
    local __c; __c="$(ask 'Select' '0')" || return
    case "$__c" in
      1) zap_install ;;
      2) zap_enable ;;
      3) zap_disable ;;
      4) zap_status ;;
      5) zap_remove ;;
      0) return ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------- uninstall
uninstall_all() {
  clear
  hdr "Uninstall Tunnel"
  if ! confirm "Remove EVERYTHING aestun installed (service, binary, config, zapret, network tuning)?"; then
    warn "Cancelled — nothing was removed."
    pause
    return
  fi
  local port; port="$(json_get "$CONF" listen)"; port="${port##*:}"
  local iface; iface="$(json_get "$CONF" tun_name)"; iface="${iface:-tun0}"
  fwd_rule del 2>/dev/null || true
  systemctl disable --now aestun >/dev/null 2>&1 || true
  systemctl disable --now aestun-watchdog.timer >/dev/null 2>&1 || true
  zap_rule del 2>/dev/null || true
  systemctl disable --now aestun-zapret >/dev/null 2>&1 || true
  rm -f "$SERVICE" "$ZAP_SERVICE" "$ZAP_RULES" "$FWD_SERVICE" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$BIN_DST"
  systemctl daemon-reload
  ip link del "$iface" 2>/dev/null || true
  if [[ -n "$port" ]]; then
    close_firewall "$port" udp
    close_firewall "$port" tcp
  fi
  remove_network_opt
  rm -f /etc/sysctl.d/98-aestun-bufmin.conf /etc/sysctl.d/97-aestun-rpfilter.conf
  sysctl --system >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR" "$ZAPRET_DIR"
  msg "Everything removed."
  pause
}

# =============================================================================
#  DPI / probe log
# =============================================================================
dpi_enabled_in_cfg() {
  [[ -f "$CONF" ]] || return 1
  python3 - "$CONF" <<'PY' 2>/dev/null
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    d=c.get("dpi_log",{"enabled":True})
    sys.exit(0 if d.get("enabled",True) else 1)
except Exception:
    sys.exit(1)
PY
}

dpi_log_path() {
  local p
  p="$(sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" 2>/dev/null | tail -1)"
  printf '%s' "${p:-$DPI_LOG}"
}

dpi_set_enabled() {
  local want="$1" lp
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; return 1; }
  lp="$(dpi_log_path)"
  python3 - "$CONF" "$want" "$lp" <<'PY'
import json,sys
p,want,lp=sys.argv[1],sys.argv[2]=="true",sys.argv[3]
with open(p) as fp:
    c=json.load(fp)
d=c.setdefault("dpi_log",{"path":lp,"probe":True})
d["enabled"]=want
with open(p,"w") as fp:
    json.dump(c,fp,indent=2)
PY
  chmod 600 "$CONF"
  msg "dpi_log.enabled = $want"
  if ask_yn "Restart aestun now to apply" "Y"; then
    systemctl restart aestun && msg "restarted."
    fwd_apply
  fi
}

dpi_menu() {
  while true; do
    clear
    local state="off" sc="$R" lp sz
    dpi_enabled_in_cfg && { state="on"; sc="$G"; }
    lp="$(dpi_log_path)"
    sz="-"; [[ -f "$lp" ]] && sz="$(du -h "$lp" 2>/dev/null | cut -f1)"
    hdr "DPI & Probe Log (state: ${sc}${state}${N}${BOLD}${C} | size: ${sz})"
    cat <<EOF

  ${C}1${N}) Report — last 24 hours
  ${C}2${N}) Report — last 7 days
  ${C}3${N}) Live tail (high/warn findings)
  ${C}4${N}) Raw log tail
  ${C}5${N}) Self-test probe detector
  ${C}6${N}) Toggle enable / disable
  ${C}7${N}) Clear log files
  ${C}0${N}) Back
EOF
    local c; c="$(ask 'Select' '0')" || return
    case "$c" in
      1) clear; "$BIN_DST" dpi-report -log "$lp" -hours 24 2>&1 | ${PAGER:-less} -R ;;
      2) clear; "$BIN_DST" dpi-report -log "$lp" -hours 168 2>&1 | ${PAGER:-less} -R ;;
      3) clear
         printf '%s\n' "${D}streaming findings — Ctrl-C to stop${N}"
         journalctl -u aestun -f -o cat 2>/dev/null | grep --line-buffered '\[dpi\]' || true ;;
      4) clear; tail -f "$lp" || true ;;
      5) dpi_selftest ;;
      6) if dpi_enabled_in_cfg; then dpi_set_enabled false; else dpi_set_enabled true; fi; pause ;;
      7) if confirm "Delete $lp and its rotated copies?"; then
           rm -f "$lp" "$lp".[0-9]; msg "Cleared."
         fi; pause ;;
      0) return ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

dpi_selftest() {
  clear
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; pause; return; }
  local port lp
  port="$(json_get "$CONF" listen)"; port="${port##*:}"
  lp="$(dpi_log_path)"
  hdr "DPI Observer Self-Test"
  printf 'Sending local test probes to 127.0.0.1:%s...\n' "$port"
  "$BIN_DST" probe -target "127.0.0.1:${port}" -mode quic -sni www.google.com -count 3 || true
  "$BIN_DST" probe -target "127.0.0.1:${port}" -mode junk -count 25 -size 200 || true

  local flush=65
  printf 'Waiting %ss for observer aggregation flush' "$flush"
  for _ in $(seq 1 $flush); do printf '.'; sleep 1; done
  printf '\n\n'
  "$BIN_DST" dpi-report -log "$lp" -hours 1
  pause
}

# =============================================================================
#  Anti-DPI hardening menu (desync / junk / port-hop / split)
# =============================================================================
antidpi_state() {
  [[ -f "$CONF" ]] || { printf 'no-config'; return; }
  python3 - "$CONF" 2>/dev/null <<'PY' || printf 'parse-error'
import json,sys
with open(sys.argv[1]) as fp:
    c=json.load(fp)
def st(k):
    v=c.get(k,{})
    return "on" if isinstance(v,dict) and v.get("enabled") else "off"
print("desync=%s junk=%s hop=%s split=%s"%(st("desync"),st("junk"),st("hop"),st("split")))
PY
}

antidpi_set() {
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; return 1; }
  python3 - "$CONF" "$1" "$2" <<'PY'
import json,sys
p,mod,want=sys.argv[1],sys.argv[2],sys.argv[3]=="true"
with open(p) as fp:
    c=json.load(fp)
c.setdefault(mod,{})["enabled"]=want
d=c[mod]
if mod=="desync": d.setdefault("repeats",4); d.setdefault("autottl",True); d.setdefault("delta",-1); d.setdefault("badsum",False)
if mod=="junk":   d.setdefault("count",8); d.setdefault("min_ms",5); d.setdefault("max_ms",50)
if mod=="hop":    d.setdefault("ports",[443,8443,2053,2083,2087,2096]); d.setdefault("interval",30)
if mod=="split":  d.setdefault("frag_pos",24)
with open(p,"w") as fp:
    json.dump(c,fp,indent=2)
PY
  chmod 600 "$CONF"
}

antidpi_set_hop_ports() {
  local hp transport
  transport="$(json_get "$CONF" transport)"; transport="${transport:-udp}"
  hp="$(ask "Port set (comma separated, IDENTICAL on BOTH servers)" "443,8443,2053,2083,2087,2096")"
  hp="$(printf '%s' "$hp" | tr -d ' ')"
  python3 - "$CONF" "$hp" <<'PY'
import json,sys
p,ports=sys.argv[1],[int(x) for x in sys.argv[2].split(',') if x.strip().isdigit()]
with open(p) as fp:
    c=json.load(fp)
c.setdefault("hop",{})["ports"]=ports or [443,8443,2053,2083,2087,2096]
with open(p,"w") as fp:
    json.dump(c,fp,indent=2)
PY
  chmod 600 "$CONF"
  local p
  for p in ${hp//,/ }; do open_firewall "$p" "$transport"; done
  msg "Hop ports configured and opened in local firewall (IPv4 & IPv6)."
}

antidpi_menu() {
  while true; do
    clear
    local state; state="$(antidpi_state)"
    hdr "Anti-DPI Hardening (${state})"
    cat <<EOF

  ${C}1${N}) Toggle desync (fake QUIC injector)
  ${C}2${N}) Toggle junk (flow-start cover packets)
  ${C}3${N}) Toggle port hopping (keyed port rotation)
  ${C}4${N}) Toggle split (IP-fragment fakes)
  ${C}5${N}) Configure port-hopping ports
  ${C}0${N}) Back
EOF
    local c; c="$(ask 'Select' '0')" || return
    case "$c" in
      1) if [[ "$state" == *desync=on* ]]; then antidpi_set desync false; else antidpi_set desync true; fi ;;
      2) if [[ "$state" == *junk=on* ]]; then antidpi_set junk false; else antidpi_set junk true; fi ;;
      3) if [[ "$state" == *hop=on* ]]; then
           antidpi_set hop false
         else
           antidpi_set hop true
           antidpi_set_hop_ports
         fi ;;
      4) if [[ "$state" == *split=on* ]]; then antidpi_set split false; else antidpi_set split true; fi ;;
      5) antidpi_set_hop_ports; pause ;;
      0)
        systemctl restart aestun >/dev/null 2>&1 || true
        fwd_apply >/dev/null 2>&1 || true
        return ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Auto-test
# =============================================================================
autotest() {
  clear; hdr "Auto-Test Methods & Protocols"
  [[ -f "$CONF" ]] || { err "Set up the tunnel first."; pause; return; }
  local role; role="$(json_get "$CONF" role)"
  [[ "$role" == "a" ]] || { err "Run auto-test from the role 'a' (Iran) server."; pause; return; }
  ensure_deps
  command -v sshpass >/dev/null 2>&1 || apt-get install -y sshpass >/dev/null 2>&1 || true
  command -v sshpass >/dev/null 2>&1 || { err "sshpass is required (apt-get install sshpass)."; pause; return; }

  local peer host; peer="$(json_get "$CONF" peer)"
  host="$(peer_extract_host "$peer")"
  printf '\n%sThis tests multiple anti-DPI profiles across BOTH servers (~5-6 minutes).%s\n\n' "$Y" "$N"
  local fuser fhost fpass
  fhost="$(ask 'Foreign (role b) SSH host (IPv4 or IPv6)' "$host")" || return
  fhost="$(strip_brackets "$fhost")"
  fuser="$(ask 'Foreign SSH user' 'root')" || return
  printf '%sForeign SSH password%s (hidden): ' "$W" "$N"; read -rs fpass; printf '\n'
  [[ -n "$fpass" ]] || { err "No password provided."; pause; return; }

  local pwf; pwf="$(mktemp)"; chmod 600 "$pwf"; printf '%s' "$fpass" > "$pwf"; unset fpass
  local RSSH="sshpass -f $pwf ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${fuser}@${fhost}"
  if ! $RSSH 'echo ok' >/dev/null 2>&1; then
    err "SSH connection to foreign server failed."
    shred -u "$pwf" 2>/dev/null || rm -f "$pwf"
    pause; return
  fi
  msg "SSH to foreign server OK."

  local RCONF="/etc/aestun/config.json"
  cp -a "$CONF" "${CONF}.autotest.bak"
  $RSSH "cp -a $RCONF ${RCONF}.autotest.bak" >/dev/null 2>&1
  local peer_ip; peer_ip="$(json_get "$CONF" peer_ip)"; peer_ip="${peer_ip:-10.8.0.2}"

  local variants=(
    "baseline|{}"
    "desync+junk+hop|{\"transport\":\"udp\",\"obfs\":\"quic\",\"desync\":{\"enabled\":true,\"repeats\":4},\"junk\":{\"enabled\":true},\"hop\":{\"enabled\":true,\"ports\":[443,8443,2053,2083,2087,2096],\"interval\":30}}"
    "desync+split+junk|{\"transport\":\"udp\",\"obfs\":\"quic\",\"desync\":{\"enabled\":true,\"repeats\":6},\"split\":{\"enabled\":true},\"junk\":{\"enabled\":true}}"
    "port-hop|{\"transport\":\"udp\",\"obfs\":\"quic\",\"hop\":{\"enabled\":true,\"ports\":[443,8443,2053,2083,2087,2096],\"interval\":20}}"
    "tcp+tls|{\"transport\":\"tcp\",\"obfs\":\"quic\",\"junk\":{\"enabled\":true}}"
    "tcp+tls+rotate|{\"transport\":\"tcp\",\"obfs\":\"quic\",\"junk\":{\"enabled\":true},\"tcp_rotate\":{\"enabled\":true,\"interval_sec\":15}}"
  )

  local best_name="" best_loss=100 best_rate="-" best_score=-1000000 best_over="{}"
  local RESULTFILE; RESULTFILE="$(mktemp)"
  printf '%-18s %6s %8s %8s  %s\n' "VARIANT" "LOSS%" "PING_ms" "Mbit/s" "NOTE" | tee "$RESULTFILE"
  printf '%s\n' "--------------------------------------------------------------" | tee -a "$RESULTFILE"

  local v name over
  for v in "${variants[@]}"; do
    name="${v%%|*}"; over="${v#*|}"
    autotest_merge "${CONF}.autotest.bak" "$over" "$CONF"
    $RSSH "$(autotest_merge_remote_cmd "${RCONF}.autotest.bak" "$over" "$RCONF")" >/dev/null 2>&1
    printf '%s testing %-20s%s ' "$D" "$name" "$N"
    $RSSH 'systemctl restart aestun' >/dev/null 2>&1
    systemctl restart aestun >/dev/null 2>&1
    fwd_apply >/dev/null 2>&1 || true
    local up=0 r1 r2 i
    for i in 1 2 3 4 5 6 7 8; do
      r1="$(json_get "$STATS" rx_packets)"; sleep 2; r2="$(json_get "$STATS" rx_packets)"
      [[ "${r2:-0}" -gt "${r1:-0}" ]] && { up=1; break; }
    done
    local loss pingms rate transport throttled=0
    transport="$(json_get "$CONF" transport)"; transport="${transport:-udp}"
    if [[ "$up" == 1 ]]; then
      rate="-"; local r_start="-" r_end="-"
      if command -v iperf3 >/dev/null 2>&1 && $RSSH "command -v iperf3 >/dev/null 2>&1"; then
        $RSSH "pkill -x iperf3 2>/dev/null; (iperf3 -s -B $peer_ip -D 2>/dev/null || true)" >/dev/null 2>&1
        sleep 1
        local ivals; ivals="$(iperf3 -c "$peer_ip" -b 60M -t 24 -i 12 -O 1 2>/dev/null \
          | awk '/sec/ && /bits\/sec/ && !/sender|receiver/{for(i=1;i<=NF;i++)if($i ~ /bits\/sec/){v=$(i-1); if($i=="Gbits/sec")v=v*1000; print v}}')"
        r_start="$(printf '%s\n' "$ivals" | head -1)"; r_end="$(printf '%s\n' "$ivals" | tail -1)"
        rate="${r_end:--}"
        if [[ "$r_start" =~ ^[0-9.]+$ && "$r_end" =~ ^[0-9.]+$ ]]; then
          awk "BEGIN{exit !($r_start>20 && $r_end < $r_start*0.5)}" && throttled=1
        fi
      fi
      local pout; pout="$(ping -c 40 -i 0.5 -W 2 "$peer_ip" 2>/dev/null || true)"
      loss="$(printf '%s' "$pout" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' | head -1)"
      pingms="$(printf '%s' "$pout" | sed -nE 's#.*= [0-9.]+/([0-9.]+)/.*#\1#p' | head -1)"
      awk "BEGIN{exit !(${loss:-100} >= 25)}" && throttled=1
    else
      loss="100"; pingms="-"; rate="0"; throttled=1
    fi
    : "${loss:=100}" "${pingms:=-}" "${rate:=-}"
    local tag=""; [[ "$throttled" == 1 ]] && tag="THROTTLED"
    printf '%-18s %6s %8s %8s  %s\n' "$name" "$loss" "$pingms" "$rate" "$tag" | tee -a "$RESULTFILE"
    local score
    if [[ "$throttled" == 1 ]]; then
      score=-100000
    else
      score="$(awk -v r="$rate" -v l="$loss" -v t="$transport" 'BEGIN{
        rr=(r ~ /^[0-9.]+$/)?r:0; ll=(l ~ /^[0-9.]+$/)?l:100;
        printf "%.2f", rr - ll*5 + (t=="udp"?40:0)}')"
    fi
    awk "BEGIN{exit !($score > $best_score)}" && {
      best_score="$score"; best_name="$name"; best_loss="$loss"; best_rate="$rate"; best_over="$over"
    }
  done

  $RSSH 'pkill -x iperf3 2>/dev/null' >/dev/null 2>&1 || true
  echo
  hdr "Auto-Test Results"
  cat "$RESULTFILE"
  echo
  if [[ -n "$best_name" ]]; then
    msg "Best variant: ${BOLD}${best_name}${N} (loss ${best_loss}%, ~${best_rate} Mbit/s)"
    if ask_yn "Apply '${best_name}' to BOTH servers now" "Y"; then
      autotest_merge "${CONF}.autotest.bak" "$best_over" "$CONF"
      $RSSH "$(autotest_merge_remote_cmd "${RCONF}.autotest.bak" "$best_over" "$RCONF")" >/dev/null 2>&1
      chmod 600 "$CONF"; $RSSH "chmod 600 $RCONF" >/dev/null 2>&1
      $RSSH 'systemctl restart aestun' >/dev/null 2>&1
      systemctl restart aestun >/dev/null 2>&1
      fwd_apply
      msg "Applied '${best_name}' on both servers."
    else
      cp "${CONF}.autotest.bak" "$CONF"; $RSSH "cp ${RCONF}.autotest.bak $RCONF" >/dev/null 2>&1
      $RSSH 'systemctl restart aestun' >/dev/null 2>&1; systemctl restart aestun >/dev/null 2>&1
      fwd_apply
      warn "Reverted to pre-test configuration."
    fi
  else
    err "No variant succeeded; reverting."
    cp "${CONF}.autotest.bak" "$CONF"; $RSSH "cp ${RCONF}.autotest.bak $RCONF" >/dev/null 2>&1
    $RSSH 'systemctl restart aestun' >/dev/null 2>&1; systemctl restart aestun >/dev/null 2>&1
    fwd_apply
  fi
  shred -u "$pwf" 2>/dev/null || rm -f "$pwf"
  rm -f "${CONF}.try" "${CONF}.best" "$RESULTFILE"
  pause
}

autotest_merge() {
  python3 - "$1" "$2" > "$3" <<'PY'
import json,sys
with open(sys.argv[1]) as fp:
    c=json.load(fp)
o=json.loads(sys.argv[2])
def m(a,b):
    for k,v in b.items():
        a[k]=m(a[k],v) if isinstance(v,dict) and isinstance(a.get(k),dict) else v
    return a
for blk in ("desync","junk","hop","split","tcp_rotate"):
    c.setdefault(blk,{})["enabled"]=False
c["transport"]="udp"; c["obfs"]="quic"
m(c,o)
json.dump(c,sys.stdout,indent=2)
PY
}

autotest_merge_remote_cmd() {
  local py; py=$(cat <<'PY'
import json,sys,base64
base,ovr,out=sys.argv[1],base64.b64decode(sys.argv[2]).decode(),sys.argv[3]
with open(base) as fp:
    c=json.load(fp)
o=json.loads(ovr)
def m(a,b):
    for k,v in b.items():
        a[k]=m(a[k],v) if isinstance(v,dict) and isinstance(a.get(k),dict) else v
    return a
for blk in ("desync","junk","hop","split","tcp_rotate"):
    c.setdefault(blk,{})["enabled"]=False
c["transport"]="udp"; c["obfs"]="quic"
m(c,o)
with open(out,"w") as fp:
    json.dump(c,fp,indent=2)
PY
)
  local ovr_b64; ovr_b64="$(printf '%s' "$2" | base64 -w0)"
  printf "python3 -c %q %q %q %q" "$py" "$1" "$ovr_b64" "$3"
}

# =============================================================================
#  Clean Vertical Main Menu (All 15 options preserved)
# =============================================================================
status_panel() {
  local st role peer wd lip pip trn
  st="$(svc_active aestun)"
  wd="$(svc_active aestun-watchdog.timer)"
  local st_c="$R"; [[ "$st" == active ]] && st_c="$G"
  local wd_c="$Y"; [[ "$wd" == active ]] && wd_c="$G"
  if [[ -f "$CONF" ]]; then
    role="$(json_get "$CONF" role)"
    peer="$(json_get "$CONF" peer)"
    lip="$(json_get "$CONF" local_ip)"
    pip="$(json_get "$CONF" peer_ip)"
    trn="$(json_get "$CONF" transport)"
  fi
  printf '  Service  : %s%-10s%s  Watchdog : %s%s%s\n' "$st_c" "$st" "$N" "$wd_c" "$wd" "$N"
  printf '  Role     : %-10s  Arch     : %s\n' "${role:-unconfigured}" "$(arch_tag)"
  printf '  Tunnel   : %-10s  Peer IP  : %s\n' "${lip:--}" "${pip:--}"
  printf '  Remote   : %s (%s)\n' "${peer:--}" "${trn:-udp}"
}

main_menu() {
  while true; do
    clear
    printf '%s\n' "${BOLD}${C}====================================================${N}"
    printf '%s\n' "${BOLD}${W}         AESTUN — ANTI-DPI TUNNEL MANAGER           ${N}"
    printf '%s\n' "${BOLD}${C}====================================================${N}"
    status_panel
    cat <<EOF
${C}----------------------------------------------------${N}
  ${BOLD}Core & Monitoring${N}
  ${C} 1${N}) Setup / Reconfigure Tunnel
  ${C} 2${N}) Live Monitoring Dashboard
  ${C} 3${N}) Service Management
  ${C} 4${N}) Connectivity Test & Diagnostics
  ${C} 5${N}) Live Logs

  ${BOLD}Configuration & Keys${N}
  ${C} 6${N}) Show Config
  ${C} 7${N}) Edit Config
  ${C} 8${N}) Generate New Key
  ${C} 9${N}) Network Optimization (BBR / Sysctl)

  ${BOLD}Anti-DPI & Forwarding${N}
  ${C}10${N}) DPI / Probe Log
  ${C}11${N}) Anti-DPI Hardening (Desync / Junk / Hop / Split)
  ${C}12${N}) Auto-Test Methods
  ${C}13${N}) Port Forwarding (DNAT / MASQUERADE)
  ${C}14${N}) Zapret Module (NFQUEUE Bypass)

  ${BOLD}System${N}
  ${C}15${N}) Uninstall Tunnel
  ${C} 0${N}) Exit
${C}----------------------------------------------------${N}
EOF
    local __c; __c="$(ask 'Select option' '0')" || { clear; exit 0; }
    case "$__c" in
      1)  interactive_setup; pause ;;
      2)  monitor ;;
      3)  service_menu ;;
      4)  test_conn ;;
      5)  show_logs ;;
      6)  show_config ;;
      7)  edit_config ;;
      8)  do_keygen ;;
      9)  netopt_menu ;;
      10) dpi_menu ;;
      11) antidpi_menu ;;
      12) autotest ;;
      13) fwd_menu ;;
      14) zapret_menu ;;
      15) uninstall_all ;;
      0)  clear; exit 0 ;;
      *)  warn "Invalid option"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  zap-rule — NFQUEUE plumbing for the tunnel carrier (IPv4 & IPv6)
# =============================================================================
zap_rule() {
  local peer host port qnum=200 ipt="iptables"
  peer="$(json_get "$CONF" peer)"
  host="$(peer_extract_host "$peer")"
  port="$(peer_extract_port "$peer")"
  [[ -n "$host" && -n "$port" ]] || { echo "zap-rule: cannot read peer from $CONF" >&2; return 1; }

  if is_ipv6 "$host"; then
    ipt="ip6tables"
  fi

  local target=(-j NFQUEUE --queue-num "$qnum" --queue-bypass)
  _zap_match() {
    printf '%s ' -d "$host" -p "$1" --dport "$port" \
      -m connbytes --connbytes-dir both --connbytes-mode packets --connbytes 1:8
  }

  local pr
  case "${1:-}" in
    add)
      for pr in tcp udp; do
        # shellcheck disable=SC2046
        "$ipt" -t mangle -C OUTPUT $(_zap_match "$pr") "${target[@]}" 2>/dev/null \
          || "$ipt" -t mangle -A OUTPUT $(_zap_match "$pr") "${target[@]}"
      done ;;
    del)
      for pr in tcp udp; do
        # shellcheck disable=SC2046
        iptables -t mangle -D OUTPUT $(_zap_match "$pr") "${target[@]}" 2>/dev/null || true
        # shellcheck disable=SC2046
        command -v ip6tables >/dev/null 2>&1 && ip6tables -t mangle -D OUTPUT $(_zap_match "$pr") "${target[@]}" 2>/dev/null || true
      done ;;
    rearm)
      command -v conntrack >/dev/null 2>&1 || return 0
      local i
      for i in $(seq 1 50); do
        awk -v q="$qnum" '$1==q {f=1} END{exit !f}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null && break
        sleep 0.1
      done
      for pr in tcp udp; do
        conntrack -D -p "$pr" -s "$host" --dport "$port" >/dev/null 2>&1 || true
        conntrack -D -p "$pr" -d "$host" --dport "$port" >/dev/null 2>&1 || true
      done
      return 0 ;;
    *) echo "usage: $0 zap-rule {add|del|rearm}" >&2; return 1 ;;
  esac
}

# =============================================================================
#  Watchdog — self-heals a silently-wedged tunnel
# =============================================================================
write_watchdog_units() {
  cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=aestun watchdog - restart the tunnel if it goes silent
After=aestun.service

[Service]
Type=oneshot
ExecStart=${MGR_DST} watchdog-check
EOF

  cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Run the aestun watchdog periodically

[Timer]
OnBootSec=60s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now aestun-watchdog.timer >/dev/null 2>&1 || true
}

watchdog_check() {
  [[ -f "$CONF" ]] || return 0
  if [[ "$(svc_active aestun)" != "active" ]]; then
    systemctl restart aestun >/dev/null 2>&1 || true
    fwd_apply >/dev/null 2>&1 || true
    return 0
  fi

  ensure_tun_network

  local peer_ip
  peer_ip="$(json_get "$CONF" peer_ip)"
  if [[ -n "$peer_ip" ]] && ping -c 2 -W 2 "$peer_ip" >/dev/null 2>&1; then
    return 0
  fi

  local ka lastrx real_now age thresh
  ka="$(json_get "$CONF" keepalive)"; ka="${ka:-25}"
  lastrx="$(json_get "$STATS" last_rx_unix)"
  real_now="$(date +%s)"
  : "${lastrx:=0}"

  if [[ "$lastrx" -gt 0 ]]; then
    age=$(( real_now - lastrx ))
  else
    age=999
  fi
  thresh=$(( ka * 2 )); (( thresh < 60 )) && thresh=60
  (( age < thresh )) && return 0

  mkdir -p "$(dirname "$WATCHDOG_STATE")"
  local last_restart=0
  [[ -f "$WATCHDOG_STATE" ]] && last_restart="$(cat "$WATCHDOG_STATE" 2>/dev/null || echo 0)"
  (( real_now - last_restart < 90 )) && return 0

  logger -t aestun-watchdog "no reply from ${peer_ip:-peer} for ${age}s — syncing clock, refreshing rules, restarting aestun" 2>/dev/null || true
  echo "$real_now" > "$WATCHDOG_STATE"
  sync_clock_http
  systemctl restart aestun >/dev/null 2>&1 || true
  fwd_apply >/dev/null 2>&1 || true
}

# =============================================================================
#  build — cross-compile a static Linux binary
# =============================================================================
do_build() {
  local arch="${1:-amd64}" mode="${2:-plain}"
  command -v go >/dev/null 2>&1 || { err "Go is not installed."; return 1; }
  check_build_deps
  local out="aestun-linux-${arch}"

  if [[ "$mode" == "obfuscate" || "$mode" == "garble" ]]; then
    if ! command -v garble >/dev/null 2>&1; then
      warn "garble not found; installing..."
      go install mvdan.cc/garble@latest >/dev/null 2>&1 || go install github.com/burrowers/garble@latest >/dev/null 2>&1
      command -v garble >/dev/null 2>&1 || export PATH="$PATH:$(go env GOPATH)/bin"
    fi
    if command -v garble >/dev/null 2>&1; then
      out="aestun-linux-${arch}-obf"
      ( cd "$LIB_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
          garble -tiny -literals build -trimpath -o "$out" . ) \
        && msg "built (obfuscated): ${out}" \
        && return 0
      err "garble build failed; falling back to plain build."
    else
      err "could not obtain garble; doing a plain build instead."
    fi
  fi

  local tags=()
  if [[ "$mode" == "pprof" ]]; then
    tags=(-tags pprof); out="${out}-pprof"
  fi
  ( cd "$LIB_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build "${tags[@]}" -trimpath -ldflags "-s -w" -o "$out" . ) \
    && msg "built: ${out}" \
    && printf '   copy to a server:  scp %s root@SERVER:/usr/local/bin/aestun\n' "$out"
}

# =============================================================================
#  upgrade
# =============================================================================
do_upgrade() {
  need_root
  [[ -f "$CONF" ]] || { err "Nothing to upgrade: $CONF does not exist. Run 'install' first."; exit 1; }
  hdr "aestun Upgrade"

  local stamp bak
  stamp="$(date +%Y%m%d-%H%M%S)"
  bak="/root/aestun-upgrade-${stamp}"
  mkdir -p "$bak"
  cp -a "$CONF" "$bak/config.json"
  [[ -f "$BIN_DST" ]] && cp -a "$BIN_DST" "$bak/aestun.bin"
  [[ -f "$SERVICE" ]] && cp -a "$SERVICE" "$bak/aestun.service"
  msg "Backup saved in $bak"

  sync_mgr_bin
  ensure_deps
  sync_clock_http
  ensure_binary || { err "No binary available."; return 1; }

  write_service
  systemctl daemon-reload
  ensure_loose_rp_filter "$(json_get "$CONF" tun_name)"
  apply_network_opt "bbr" "16777216" "1"
  write_watchdog_units

  python3 - "$CONF" "$DPI_LOG" <<'PY'
import json,sys
path,logpath=sys.argv[1],sys.argv[2]
with open(path) as fp:
    c=json.load(fp)
c["cipher"]="aes-gcm"
l=c.get("listen",":2087")
port=l.split(":")[-1] if ":" in l else "2087"
c["listen"]=":"+port
d=c.setdefault("dpi_log",{})
d["enabled"]=True
d.setdefault("path",logpath)
d["probe"]=True
c.setdefault("desync",{})["enabled"]=True
c.setdefault("junk",{})["enabled"]=True
c.setdefault("hop",{})["enabled"]=True
with open(path,"w") as fp:
    json.dump(c,fp,indent=2)
PY
  chmod 600 "$CONF"
  msg "Config updated with dual-stack IPv4/IPv6 listen and anti-DPI defaults."

  systemctl restart aestun && msg "aestun restarted." || err "restart failed — see: journalctl -u aestun -n 50"
  fwd_apply
}

# =============================================================================
#  installer entry
# =============================================================================
do_install() {
  need_root
  printf '%s\n' "${BOLD}${C}"
  cat <<'BANNER'
   +---------------------------------------------+
   |   aestun — AES-256-GCM anti-DPI tunnel      |
   |   server-to-server installer (IPv4 & IPv6)  |
   +---------------------------------------------+
BANNER
  printf '%s\n' "${N}"
  interactive_setup || { err "Setup aborted."; exit 1; }
  sync_mgr_bin
}

# =============================================================================
#  dispatcher
# =============================================================================
case "${1:-menu}" in
  zap-rule)       shift; zap_rule "$@"; exit $? ;;
  fwd-rule)       shift; fwd_rule "$@"; exit $? ;;
  watchdog-check) shift; watchdog_check "$@"; exit $? ;;
  fetch-core)     fetch_core; exit $? ;;
  build)          shift; do_build "$@"; exit $? ;;
  dpi-report)     shift; "$BIN_DST" dpi-report -config "$CONF" "$@"; exit $? ;;
  install)        need_root; auto_bootstrap; do_install; exit $? ;;
  upgrade)        do_upgrade; exit $? ;;
  menu|"")        need_root; auto_bootstrap; sync_mgr_bin; main_menu ;;
  -h|--help|help)
    cat <<'USAGE'
aestun.sh — installer + manager + monitor + zapret + build + port-forward.

  sudo ./aestun.sh                     open management menu
  sudo ./aestun.sh install             interactive installer
  sudo ./aestun.sh upgrade             upgrade binary and unit files
  ./aestun.sh build [arch] [obfuscate] cross-compile binary
  ./aestun.sh dpi-report               summarise the DPI/probe log
  ./aestun.sh zap-rule {add|del|rearm} NFQUEUE helper
  ./aestun.sh fwd-rule {add|del}       DNAT/FORWARD helper
  ./aestun.sh fetch-core               download upstream core and binaries
USAGE
    exit 0 ;;
  *) err "Unknown command: $1 (try: install | menu | upgrade | zap-rule | fwd-rule | fetch-core | build)"; exit 1 ;;
esac
