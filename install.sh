#!/usr/bin/env bash
# =============================================================================
#  aestun.sh v2 — installer, manager, watchdog, port forwards, live monitor
#
#    sudo ./aestun.sh               menu
#    sudo ./aestun.sh install       first-time setup (run on each server)
#    sudo ./aestun.sh repair        rewrite units/timer/tuning, keep config, restart
#    sudo ./aestun.sh uninstall     remove everything this script installed
#    ./aestun.sh build [amd64|arm64] [obfuscate]
#    ./aestun.sh fetch-core         download the Go core + prebuilt binaries
#    ./aestun.sh dpi-report [hours]
#    (systemd only)                 apply-rules | watchdog
#
#  Roles
#    Iran server     (role a): tunnel + port forwards. Forwards are typed ONCE as a
#                              comma list (1080,443,...) and applied automatically.
#    Foreign client  (role b): tunnel only. Never asked about forwards.
#
#  These must be IDENTICAL on both servers: key, cipher, transport, obfs, port.
#  DEFAULT_PSK_PLACEHOLDER is the same in every copy of this file. Replace it once
#  with your own key (head -c32 /dev/urandom | base64) or export AESTUN_PSK.
# =============================================================================

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${LIB_DIR}/$(basename "${BASH_SOURCE[0]}")"
MGR_DST="/usr/local/sbin/aestun-mgr"
BIN_DST="/usr/local/bin/aestun"
CONF_DIR="/etc/aestun"
CONF="${CONF_DIR}/config.json"
SERVICE="/etc/systemd/system/aestun.service"
WD_SERVICE="/etc/systemd/system/aestun-watchdog.service"
WD_TIMER="/etc/systemd/system/aestun-watchdog.timer"
STATS="/run/aestun/stats.json"
WD_STATE="/run/aestun/watchdog.state"
DPI_LOG="/var/log/aestun/dpi.jsonl"
SYSCTL_FILE="/etc/sysctl.d/99-aestun.conf"
BBR_MODCONF="/etc/modules-load.d/aestun-bbr.conf"
CORE_REPO_ZIP="https://github.com/3aeidkhalili/AES-256-GCM-anti-DPI/archive/refs/heads/main.zip"

# Every iptables rule this script adds carries one of these comments, so re-apply and
# cleanup touch only our own rules, whatever ufw or a reboot did in the meantime.
TAG_FWD="aestun-fwd"       # DNAT / MASQUERADE / FORWARD for port forwards
TAG_OPEN="aestun-open"     # INPUT accept for the carrier (and hop) ports
TAG_TRUST="aestun-trust"   # accept for the tunnel interface

DEFAULT_PSK_PLACEHOLDER="gDfGvhlFAwaNB72O8/CrtbG6g6JnQjmJCIeSFtPRxMg="
DEFAULT_PSK="${AESTUN_PSK:-$DEFAULT_PSK_PLACEHOLDER}"
DEFAULT_PORT="${AESTUN_PORT:-2087}"
# Fixed on purpose. The old default was "whatever this CPU reports", so two servers with
# different CPUs could both press Enter, end up with different ciphers, and fail the
# handshake without any error message.
DEFAULT_CIPHER="${AESTUN_CIPHER:-chacha20-poly1305}"
DEFAULT_NET="${AESTUN_NET:-10.8.0}"    # tunnel /24: Iran = .1, foreign client = .2

CFG_OK=0
FLASH=""

# ----------------------------------------------------------------- output / input
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; W=$'\e[97m'
  D=$'\e[2m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; C=""; W=""; D=""; B=""; N=""
fi
# UI goes to stderr so that $(function) captures only the values a function returns.
msg()  { printf '%s[ok]%s %s\n' "$G" "$N" "$*" >&2; }
warn() { printf '%s[!]%s %s\n'  "$Y" "$N" "$*" >&2; }
err()  { printf '%s[x]%s %s\n'  "$R" "$N" "$*" >&2; }
hdr()  { printf '\n%s== %s ==%s\n' "$B$C" "$*" "$N" >&2; }
pause(){ printf '\n%sEnter to continue…%s' "$D" "$N" >&2; read -r _ || true; }
need_root() { [[ $EUID -eq 0 ]] || { err "run as root:  sudo $0 $*"; exit 1; }; }
clear_screen() { printf '\033[H\033[2J'; }
flash() { FLASH="$*"; }
show_flash() { if [[ -n "$FLASH" ]]; then printf '\n  %s%s%s\n' "$Y" "$FLASH" "$N"; FLASH=""; fi; }
onoff() { if [[ "$1" == 1 ]]; then printf 'on '; else printf 'off'; fi; }

ask() { # ask PROMPT [DEFAULT] -> value on stdout
  local p="$1" d="${2-}" a
  if [[ -n "$d" ]]; then printf '%s%s%s [%s]: ' "$W" "$p" "$N" "$d" >&2
  else printf '%s%s%s: ' "$W" "$p" "$N" >&2; fi
  IFS= read -r a || { printf '%s' "$d"; return 1; }
  printf '%s' "${a:-$d}"
}
ask_yn() { # ask_yn PROMPT [Y|N] -> exit 0 for yes
  local d="${2:-N}" a hint
  if [[ "$d" == Y ]]; then hint="Y/n"; else hint="y/N"; fi
  printf '%s%s%s [%s]: ' "$W" "$1" "$N" "$hint" >&2
  IFS= read -r a || return 1
  a="${a:-$d}"
  [[ "$a" =~ ^[yY]$ ]]
}
read_choice() { # main-menu prompt
  local a
  printf '%s›%s ' "$W" "$N" >&2
  IFS= read -r a || return 1
  printf '%s' "$a"
}

# ------------------------------------------------------------------- validation
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
  return 0
}
is_host() { # an IP or a domain — never a bare port number
  if [[ "$1" =~ ^[0-9.]+$ ]]; then is_ipv4 "$1"; return; fi
  [[ "$1" == *.* && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}
normalize_input() { # Persian digits and Persian comma -> ASCII, drop blanks
  printf '%s' "$1" | sed -e 's/۰/0/g;s/۱/1/g;s/۲/2/g;s/۳/3/g;s/۴/4/g;s/۵/5/g;s/۶/6/g;s/۷/7/g;s/۸/8/g;s/۹/9/g;s/،/,/g' | tr -d ' \t\r'
}
arch_tag() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo unknown ;; esac; }
cpu_has_aesni() { grep -qw aes /proc/cpuinfo 2>/dev/null && grep -qw pclmulqdq /proc/cpuinfo 2>/dev/null; }
human() {
  awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i] }'
}
fmt_dur() {
  local s=${1:-0} d h m
  d=$(( s / 86400 )); h=$(( s % 86400 / 3600 )); m=$(( s % 3600 / 60 ))
  if (( d > 0 )); then printf '%dd %dh %dm' "$d" "$h" "$m"
  elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# ------------------------------------------------------------------ dependencies
ensure_deps() {
  local miss=() pair
  for pair in ip:iproute2 ss:iproute2 ping:iputils-ping iptables:iptables \
              python3:python3 curl:curl unzip:unzip; do
    command -v "${pair%%:*}" >/dev/null 2>&1 || miss+=("${pair#*:}")
  done
  if (( ${#miss[@]} > 0 )); then
    warn "installing: ${miss[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y "${miss[@]}" >/dev/null 2>&1 || warn "could not install ${miss[*]} — install them by hand"
  fi
}

build_core() { # build_core ARCH OUTPUT_PATH
  [[ -d "${LIB_DIR}/vendor" ]] || warn "vendor/ missing — go will download modules (needs internet)"
  ( cd "$LIB_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$1" go build -trimpath -ldflags "-s -w" -o "$2" . )
}

do_build() {
  local arch="${1:-amd64}" mode="${2:-plain}"
  command -v go >/dev/null 2>&1 || { err "Go is not installed"; return 1; }
  [[ -f "${LIB_DIR}/main.go" ]] || { err "main.go not found next to the script"; return 1; }
  if [[ "$mode" == obfuscate ]]; then
    command -v garble >/dev/null 2>&1 || go install mvdan.cc/garble@latest >/dev/null 2>&1
    export PATH="$PATH:$(go env GOPATH)/bin"
    command -v garble >/dev/null 2>&1 || { err "garble is unavailable (needs internet)"; return 1; }
    ( cd "$LIB_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        garble -tiny -literals build -trimpath -o "aestun-linux-${arch}-obf" . ) || { err "garble build failed"; return 1; }
    msg "built aestun-linux-${arch}-obf"
    warn "obfuscation slows reverse engineering; it does not make the binary secret"
    return 0
  fi
  build_core "$arch" "${LIB_DIR}/aestun-linux-${arch}" \
    && msg "built ${LIB_DIR}/aestun-linux-${arch} — copy it next to aestun.sh on the servers"
}

fetch_core() {
  ensure_deps
  local tmp src f
  tmp="$(mktemp -d)"
  msg "downloading the core from upstream…"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 "$CORE_REPO_ZIP" -o "$tmp/core.zip" 2>/dev/null
  else
    wget -q "$CORE_REPO_ZIP" -O "$tmp/core.zip"
  fi
  if [[ ! -s "$tmp/core.zip" ]]; then
    err "download failed (GitHub may be blocked here) — copy aestun-linux-<arch> next to this script by hand"
    rm -rf "$tmp"; return 1
  fi
  unzip -q "$tmp/core.zip" -d "$tmp/x" || { err "unzip failed"; rm -rf "$tmp"; return 1; }
  src="$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$src" ]] || { err "unexpected archive layout"; rm -rf "$tmp"; return 1; }
  for f in "$src"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "$(basename "$SELF")" ]] && continue
    cp -f "$f" "$LIB_DIR/"
  done
  rm -rf "$tmp"
  chmod +x "$LIB_DIR"/aestun-linux-* 2>/dev/null
  msg "core files copied to $LIB_DIR"
}

ensure_binary() {
  local tag pre
  tag="$(arch_tag)"
  [[ "$tag" == unknown ]] && { err "unsupported CPU: $(uname -m) (aestun ships amd64 and arm64)"; return 1; }
  pre="${LIB_DIR}/aestun-linux-${tag}"
  if [[ ! -f "$pre" && ! -f "${LIB_DIR}/main.go" && ! -x "$BIN_DST" ]]; then
    warn "no core next to the script — fetching it from upstream"
    fetch_core || true
  fi
  if [[ -f "$pre" ]] && install -m 0755 "$pre" "$BIN_DST"; then
    msg "core installed (prebuilt ${tag})"; return 0
  fi
  if command -v go >/dev/null 2>&1 && [[ -f "${LIB_DIR}/main.go" ]]; then
    warn "building the core from source…"
    if build_core "$tag" "$BIN_DST"; then msg "core built and installed"; return 0; fi
    err "go build failed"; return 1
  fi
  if [[ -x "$BIN_DST" ]]; then warn "keeping the installed core ($BIN_DST)"; return 0; fi
  err "no core available. On a machine with Go:  ./aestun.sh build ${tag}  and put aestun-linux-${tag} next to this script."
  return 1
}

# ------------------------------------------------------------- config & state I/O
# load_cfg — reads config.json in ONE python call into shell variables.
load_cfg() {
  CFG_OK=0
  [[ -f "$CONF" ]] || return 1
  local out
  out="$(python3 -c '
import json, shlex, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
def put(k, v):
    if isinstance(v, bool):
        v = "1" if v else "0"
    print("%s=%s" % (k, shlex.quote(str(v))))
ls = str(c.get("listen", ""))
pe = str(c.get("peer", ""))
put("ROLE", c.get("role", "a"))
put("LISTEN_PORT", ls.rsplit(":", 1)[-1] if ":" in ls else "")
put("PEER", pe)
put("PEER_HOST", pe.rsplit(":", 1)[0] if ":" in pe else pe)
put("TRANSPORT", c.get("transport", "udp"))
put("OBFS", c.get("obfs", "none"))
put("CIPHER", c.get("cipher", ""))
put("TUN", c.get("tun_name", "tun0"))
put("LOCAL_IP", c.get("local_ip", ""))
put("PEER_IP", str(c.get("peer_ip", "")).split("/")[0])
put("HAS_KEY", 1 if c.get("key") else 0)
put("DPI_ON", (c.get("dpi_log") or {}).get("enabled", True))
for b in ("desync", "junk", "hop", "split"):
    put("ON_" + b.upper(), (c.get(b) or {}).get("enabled", False))
put("HOP_PORTS", " ".join(str(x) for x in (c.get("hop") or {}).get("ports", [])))
' "$CONF" 2>/dev/null)" || return 1
  eval "$out"
  CFG_OK=1
}

# load_stats — live counters from the daemon, one python call.
load_stats() {
  local out
  out="$(python3 -c '
import json, shlex
try:
    s = json.load(open("/run/aestun/stats.json"))
except Exception:
    s = {}
INTS = {"TX_BYTES", "RX_BYTES", "TX_PKTS", "RX_PKTS", "AUTH_FAIL", "REPLAY",
        "UPTIME", "LAST_RX", "NOW", "REKEY"}
F = [
    ("TX_BYTES", "tx_bytes", 0), ("RX_BYTES", "rx_bytes", 0),
    ("TX_PKTS", "tx_packets", 0), ("RX_PKTS", "rx_packets", 0),
    ("AUTH_FAIL", "auth_fail", 0), ("REPLAY", "replay_drop", 0),
    ("UPTIME", "uptime_seconds", 0), ("PEER", "peer", "-"),
    ("LAST_RX", "last_rx_unix", 0), ("NOW", "now_unix", 0),
    ("REKEY", "rekey_interval", 0), ("DPI_ON", "dpi_enabled", False),
    ("DPI_PROBES", "dpi_probes", 0), ("DPI_REPLAYS", "dpi_replays", 0),
    ("DPI_INJ", "dpi_injections", 0), ("DPI_TTL", "dpi_ttl_anomalies", 0),
    ("LOSS", "loss_pct", "-"), ("RTT", "rtt_ms", "-"),
]
for name, field, dflt in F:
    v = s.get(field, dflt)
    if v is None:
        v = dflt
    if isinstance(v, bool):
        v = "1" if v else "0"
    if name in INTS:
        try:
            v = int(float(v))
        except Exception:
            v = 0
    print("ST_%s=%s" % (name, shlex.quote(str(v))))
' 2>/dev/null)"
  eval "$out"
}

# save_config KEY=VALUE ... — merges into config.json; creates it with defaults on first run.
save_config() {
  mkdir -p "$CONF_DIR"
  python3 -c '
import json, os, sys
p = sys.argv[1]
c = {}
if os.path.exists(p):
    try:
        c = json.load(open(p))
    except Exception:
        c = {}
defaults = {
    "cipher": "chacha20-poly1305", "transport": "udp", "obfs": "quic",
    "sni": "www.play.google.com", "tun_name": "tun0", "mtu": 1280, "txqueuelen": 1000,
    "rcvbuf": 8388608, "sndbuf": 8388608, "pad_max": 64, "rekey_interval": 3600,
    "keepalive": 25, "manage_ip": True, "stats_path": "/run/aestun/stats.json",
    "dpi_log": {"enabled": True, "path": "/var/log/aestun/dpi.jsonl", "probe": True},
    "desync": {"enabled": False, "repeats": 4, "autottl": True, "delta": -1, "badsum": False},
    "junk": {"enabled": False, "count": 8, "min_ms": 5, "max_ms": 50},
    "hop": {"enabled": False, "ports": [443, 8443, 2053, 2083, 2087, 2096], "interval": 30},
    "split": {"enabled": False, "frag_pos": 24},
    "forwards": [],
}
for k, v in defaults.items():
    c.setdefault(k, v)
for a in sys.argv[2:]:
    k, _, v = a.partition("=")
    try:
        v = json.loads(v)
    except Exception:
        pass
    c[k] = v
tmp = p + ".tmp"
json.dump(c, open(tmp, "w"), indent=2)
os.replace(tmp, p)
' "$CONF" "$@" && chmod 600 "$CONF"
}

# cfg_patch PY_STATEMENTS [ARG...] — edits config.json atomically. The dict is `c`,
# the extra arguments are sys.argv[3:].
cfg_patch() {
  local code="$1"; shift
  python3 -c '
import json, os, sys
p = sys.argv[1]
c = json.load(open(p))
exec(sys.argv[2])
tmp = p + ".tmp"
json.dump(c, open(tmp, "w"), indent=2)
os.replace(tmp, p)
' "$CONF" "$code" "$@" && chmod 600 "$CONF"
}

# fwd_list — "PORT TARGET PROTO" per line
fwd_list() {
  [[ -f "$CONF" ]] || return 0
  python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
for f in c.get("forwards") or []:
    print(f.get("port", ""), f.get("target_port", f.get("port", "")), f.get("proto", "tcp"))
' "$CONF" 2>/dev/null
}

# fwd_string — the human form the user types: 1080,443:8443,53/udp
fwd_string() {
  fwd_list | awk 'NF == 3 { s = s (s == "" ? "" : ",") $1 ($2 != $1 ? ":" $2 : "") ($3 != "tcp" ? "/" $3 : "") }
                  END { print s }'
}

# lines_to_json — stdin "PORT TARGET PROTO" -> JSON array text
lines_to_json() {
  local p t pr out="" sep=""
  while read -r p t pr; do
    [[ -n "$p" && -n "$t" && -n "$pr" ]] || continue
    out+="${sep}{\"port\":${p},\"target_port\":${t},\"proto\":\"${pr}\"}"
    sep=","
  done
  printf '[%s]' "$out"
}

# fwd_merge — stdin lines -> one line per port/proto (last one wins)
fwd_merge() {
  awk 'NF == 3 { k = $1 "/" $3; if (!(k in v)) ord[++n] = k; v[k] = $0 }
       END { for (i = 1; i <= n; i++) print v[ord[i]] }'
}

# fwd_save — stdin lines -> replaces the whole forward list in config.json
fwd_save() {
  local json
  json="$(lines_to_json)"
  cfg_patch 'c["forwards"] = json.loads(sys.argv[3])' "$json"
}

# parse_ports TEXT -> "PORT TARGET PROTO" lines. Accepts 1080,443:8443,53/udp,443/both
parse_ports() {
  local raw tok p t pr
  local -a items
  raw="$(normalize_input "$1")"
  IFS=',' read -ra items <<< "$raw"
  for tok in "${items[@]}"; do
    [[ -n "$tok" ]] || continue
    pr="tcp"
    if [[ "$tok" == */* ]]; then pr="${tok#*/}"; tok="${tok%%/*}"; fi
    p="${tok%%:*}"; t="$p"
    [[ "$tok" == *:* ]] && t="${tok#*:}"
    case "$pr" in
      tcp|udp|both) ;;
      *) warn "'$tok': protocol must be tcp, udp or both — skipped"; continue ;;
    esac
    if ! is_port "$p" || ! is_port "$t"; then warn "'$tok': not a valid port — skipped"; continue; fi
    if [[ "$pr" == both ]]; then
      printf '%s %s tcp\n%s %s udp\n' "$p" "$t" "$p" "$t"
    else
      printf '%s %s %s\n' "$p" "$t" "$pr"
    fi
  done
}

# read_ports DEFAULT -> "PORT TARGET PROTO" lines. Empty output = none. Loops until valid.
read_ports() {
  local def="${1-}" ans lines
  while true; do
    ans="$(ask 'Ports (comma separated, e.g. 1080,443)' "$def")" || return 1
    if [[ -z "$ans" || "$ans" == "-" ]]; then return 0; fi
    lines="$(parse_ports "$ans")"
    if [[ -z "$lines" ]]; then err "no valid port in '$ans' — example: 1080,443"; continue; fi
    if printf '%s\n' "$lines" | awk -v lp="${LISTEN_PORT:-$DEFAULT_PORT}" '$1 == lp { bad = 1 } END { exit bad }'; then
      printf '%s\n' "$lines" | fwd_merge
      return 0
    fi
    err "port ${LISTEN_PORT:-$DEFAULT_PORT} is this tunnel's own port — choose another"
  done
}

pick_tun() { # first free tunN — other tunnel scripts on the same box often hold tun0
  local i
  for i in 0 1 2 3 4 5 6 7 8 9; do
    ip link show "tun$i" >/dev/null 2>&1 || { echo "tun$i"; return 0; }
  done
  echo tun0
}
tun_ip() { ip -4 -o addr show dev "$TUN" 2>/dev/null | awk '{ print $4; exit }'; }
public_ip() { command -v curl >/dev/null 2>&1 && curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null; }
peer_rtt() { ping -c 3 -W 2 "$PEER_IP" 2>/dev/null | awk -F/ '/^rtt|^round-trip/ { print $5 }'; }
wait_peer() { # wait up to N seconds for the peer's tunnel IP to answer
  local i
  for (( i = 0; i < ${1:-30}; i++ )); do
    ping -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------- firewall / NAT (idempotent)
ipt() { iptables -w 5 "$@"; }
ipt_ensure() { # ipt_ensure TABLE CHAIN SPEC… — inserts at the top only when missing
  local t="$1" c="$2"; shift 2
  ipt -t "$t" -C "$c" "$@" 2>/dev/null && return 0
  ipt -t "$t" -I "$c" 1 "$@" 2>/dev/null
}
open_port() { # open_port PORT PROTO — accept inbound on a port of THIS server
  ipt_ensure filter INPUT -p "$2" --dport "$1" -m comment --comment "$TAG_OPEN" -j ACCEPT
}
trust_tunnel() { # traffic from the tunnel interface is already authenticated (AEAD)
  local tun="$1"
  ipt_ensure filter INPUT -i "$tun" -m comment --comment "$TAG_TRUST" -j ACCEPT
  ipt_ensure filter FORWARD -i "$tun" -m comment --comment "$TAG_TRUST" -j ACCEPT
  ipt_ensure filter FORWARD -o "$tun" -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment "$TAG_TRUST" -j ACCEPT
}
apply_forwards() { # apply_forwards PEER_TUNNEL_IP TUN — Iran side only
  local peer_ip="$1" tun="$2" p t pr
  while read -r p t pr; do
    [[ -n "$p" ]] || continue
    ipt_ensure nat PREROUTING -p "$pr" --dport "$p" -m comment --comment "$TAG_FWD" \
      -j DNAT --to-destination "${peer_ip}:${t}"
    ipt_ensure nat POSTROUTING -o "$tun" -p "$pr" -d "$peer_ip" --dport "$t" \
      -m comment --comment "$TAG_FWD" -j MASQUERADE
    ipt_ensure filter FORWARD -p "$pr" -d "$peer_ip" --dport "$t" \
      -m comment --comment "$TAG_FWD" -j ACCEPT
  done < <(fwd_list)
}
flush_tag() { # flush_tag TAG — delete every rule carrying TAG and nothing else
  local tag="$1" tbl t c line
  for tbl in nat:PREROUTING nat:POSTROUTING filter:INPUT filter:FORWARD; do
    t="${tbl%%:*}"; c="${tbl#*:}"
    while IFS= read -r line; do
      line="${line//\"/}"          # iptables -S may print comments quoted
      line="${line//\'/}"
      [[ "$line" == *"--comment ${tag}"* ]] || continue
      # shellcheck disable=SC2086
      ipt -t "$t" -D "$c" ${line#-A "$c" } 2>/dev/null
    done < <(ipt -t "$t" -S "$c" 2>/dev/null)
  done
}
# apply_rules — idempotent: every rule this tunnel needs is (re)asserted here.
# Runs after every start (systemd), every watchdog tick, and after every forward edit.
apply_rules() {
  load_cfg || return 0
  sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1
  open_port "$LISTEN_PORT" "$TRANSPORT"
  if [[ "$ON_HOP" == 1 ]]; then
    local hp
    for hp in $HOP_PORTS; do open_port "$hp" "$TRANSPORT"; done
  fi
  trust_tunnel "$TUN"
  if [[ "$ROLE" == a && -n "$PEER_IP" ]]; then apply_forwards "$PEER_IP" "$TUN"; fi
  return 0
}
# ufw has its own filter; mirror our rules into it so `ufw status` tells the truth.
ufw_sync() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" || return 0
  load_cfg || return 0
  ufw allow "${LISTEN_PORT}/${TRANSPORT}" >/dev/null 2>&1
  if [[ "$ON_HOP" == 1 ]]; then
    local hp
    for hp in $HOP_PORTS; do ufw allow "${hp}/${TRANSPORT}" >/dev/null 2>&1; done
  fi
  ufw allow in on "$TUN" >/dev/null 2>&1
  if [[ "$ROLE" == a ]]; then
    local p t pr
    while read -r p t pr; do
      [[ -n "$p" ]] || continue
      ufw route allow proto "$pr" to "$PEER_IP" port "$t" >/dev/null 2>&1
    done < <(fwd_list)
  fi
  msg "ufw synced"
}

# ------------------------------------------------------------ system pieces
apply_netopt() {
  local cc=cubic buf=16777216
  if modprobe tcp_bbr 2>/dev/null; then cc=bbr; echo tcp_bbr > "$BBR_MODCONF"; fi
  cat > "$SYSCTL_FILE" <<EOF
# managed by aestun — buffers, congestion control and forwarding for the tunnel
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}
net.core.rmem_max = ${buf}
net.core.wmem_max = ${buf}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_rmem = 4096 1048576 ${buf}
net.ipv4.tcp_wmem = 4096 65536 ${buf}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.ip_forward = 1
EOF
  sysctl -q --system >/dev/null 2>&1
  local now; now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [[ "$now" == "$cc" ]]; then msg "network tuning applied (congestion control: $cc)"
  else warn "congestion control is '${now}', not $cc — this kernel lacks it"; fi
}

cleanup_legacy() { # pieces left behind by older versions (zapret module, old forward unit, …)
  local u line
  for u in aestun-zapret aestun-fwd; do
    systemctl disable --now "${u}.service" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${u}.service"
  done
  rm -f /etc/sysctl.d/98-aestun-bufmin.conf
  while IFS= read -r line; do
    # shellcheck disable=SC2086
    iptables -w 5 -t mangle ${line/-A OUTPUT/-D OUTPUT} 2>/dev/null
  done < <(iptables -w 5 -t mangle -S OUTPUT 2>/dev/null | grep 'NFQUEUE --queue-num 200')
}

write_units() {
  cat > "$SERVICE" <<EOF
[Unit]
Description=aestun - AES-256-GCM obfuscated server-to-server tunnel
After=network-online.target
Wants=network-online.target
# Never park the unit in "failed": systemd's default start-rate limit would do that.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BIN_DST} -config ${CONF}
# Re-asserts firewall, NAT and forward rules after every (re)start. The "-" prefix means
# a failure here can never take the tunnel itself down.
ExecStartPost=-${MGR_DST} apply-rules
Restart=always
RestartSec=2
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
RuntimeDirectory=aestun
LogsDirectory=aestun
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
  cat > "$WD_SERVICE" <<EOF
[Unit]
Description=aestun watchdog - re-assert rules and reconnect when the peer is unreachable

[Service]
Type=oneshot
ExecStart=${MGR_DST} watchdog
EOF
  cat > "$WD_TIMER" <<EOF
[Unit]
Description=aestun watchdog timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
  cleanup_legacy
  systemctl daemon-reload
}

# watchdog — runs every minute (systemd timer). Re-asserts rules (they vanish after a
# reboot or a ufw reload), and restarts the tunnel after 3 failed pings, with backoff so a
# peer that is simply offline does not cause a restart storm.
watchdog() {
  load_cfg || return 0
  apply_rules
  mkdir -p /run/aestun
  local fails=0 last=0 backoff=600 now st
  if [[ -f "$WD_STATE" ]]; then read -r fails last backoff < "$WD_STATE"; fi
  : "${fails:=0}" "${last:=0}" "${backoff:=600}"
  now="$(date +%s)"
  st="$(systemctl is-active aestun 2>/dev/null)"
  if [[ "$st" == failed ]]; then
    echo "aestun-watchdog: service is in failed state — starting it again"
    systemctl reset-failed aestun 2>/dev/null
    systemctl start aestun
    fails=0; last=$now
  elif [[ "$st" == active && -n "$PEER_IP" ]]; then
    if ping -c 2 -W 2 "$PEER_IP" >/dev/null 2>&1; then
      fails=0; backoff=600
    else
      fails=$(( fails + 1 ))
      if (( fails >= 3 && now - last >= backoff )); then
        echo "aestun-watchdog: ${PEER_IP} unreachable for ${fails} checks — restarting aestun"
        systemctl restart aestun
        last=$now; fails=0
        backoff=$(( backoff * 2 )); (( backoff > 3600 )) && backoff=3600
      fi
    fi
  else
    fails=0
  fi
  printf '%s %s %s\n' "$fails" "$last" "$backoff" > "$WD_STATE"
}

# ---------------------------------------------------------------- setup flows
install_wizard() {
  hdr "aestun setup"
  ensure_deps
  ensure_binary || return 1
  install -m 0755 "$SELF" "$MGR_DST" || { err "cannot write $MGR_DST"; return 1; }

  load_cfg
  local was_ok="$CFG_OK" cur_role="${ROLE:-}" cur_host="${PEER_HOST:-}"
  local cur_local="${LOCAL_IP:-}" cur_tun="${TUN:-}" have_key="${HAS_KEY:-0}"
  local listen_port="${LISTEN_PORT:-$DEFAULT_PORT}"
  local sel role=a def=1 host fwd="" tun local_ip peer_ip octet peer_octet fwd_json
  local -a extra=()

  printf '\n%sThis server is:%s\n' "$B" "$N" >&2
  printf '  %s1%s) Iran server       inside the filter — port forwards are configured here\n' "$C" "$N" >&2
  printf '  %s2%s) Foreign client    outside — tunnel only\n' "$C" "$N" >&2
  [[ "$cur_role" == b ]] && def=2
  sel="$(ask 'Choose' "$def")" || return 1
  [[ "$sel" == 2 ]] && role=b

  host="$(ask_peer "$cur_host")" || return 1

  if [[ "$role" == a ]]; then
    printf '\n%sPort forwards%s — type them ONCE, comma separated; they are applied automatically:\n' "$B" "$N" >&2
    printf '   %s1080,443%s           same port on both ends\n' "$C" "$N" >&2
    printf '   %s8443:443%s           public 8443  →  foreign 443\n' "$C" "$N" >&2
    printf '   %s53/udp, 443/both%s   protocol (default tcp)\n' "$C" "$N" >&2
    printf '   %sEnter%s keeps the current list    %s-%s = none\n' "$D" "$N" "$C" "$N" >&2
    fwd="$(read_ports "$(fwd_string)")" || return 1
  fi

  if [[ "$role" == a ]]; then octet=1; peer_octet=2; else octet=2; peer_octet=1; fi
  peer_ip="${DEFAULT_NET}.${peer_octet}"
  if [[ "$was_ok" == 1 && "$role" == "$cur_role" && -n "$cur_local" ]]; then
    local_ip="$cur_local"
  else
    local_ip="${DEFAULT_NET}.${octet}/24"
  fi
  if [[ "$was_ok" == 1 && -n "$cur_tun" ]]; then tun="$cur_tun"; else tun="$(pick_tun)"; fi

  if [[ "$have_key" != 1 ]]; then
    extra+=("key=${DEFAULT_PSK}")
    if [[ "$DEFAULT_PSK" == "$DEFAULT_PSK_PLACEHOLDER" ]]; then
      warn "using the built-in key — change it (menu → New key) and put the same key on the other server"
    fi
  fi
  if [[ "$was_ok" != 1 ]]; then extra+=("cipher=${DEFAULT_CIPHER}"); fi

  fwd_json="$(printf '%s\n' "$fwd" | lines_to_json)"
  save_config "role=${role}" "listen=0.0.0.0:${listen_port}" "peer=${host}:${listen_port}" \
    "peer_ip=${peer_ip}" "local_ip=${local_ip}" "tun_name=${tun}" "forwards=${fwd_json}" \
    "${extra[@]}" || { err "could not write the config"; return 1; }

  flush_tag "$TAG_FWD"
  write_units
  apply_netopt
  systemctl enable aestun >/dev/null 2>&1
  systemctl enable --now aestun-watchdog.timer >/dev/null 2>&1
  systemctl restart aestun
  apply_rules
  ufw_sync >/dev/null 2>&1
  load_cfg

  hdr "link check"
  if wait_peer 30; then
    msg "connected — ${PEER_IP} replies (avg $(peer_rtt) ms)"
  else
    warn "no reply from ${PEER_IP} yet. Normal if the other server is not set up yet."
    warn "Run this same setup there (same key, port and cipher), then use menu → 2 (Diagnose)."
  fi

  local pub fs
  pub="$(public_ip)"
  hdr "summary"
  if [[ "$ROLE" == a ]]; then
    fs="$(fwd_string)"
    printf '  role      Iran server (a)\n' >&2
    printf '  tunnel    %s · %s · %s · port %s · %s %s\n' "$TRANSPORT" "$OBFS" "$CIPHER" "$LISTEN_PORT" "$TUN" "$(tun_ip)" >&2
    printf '  forwards  %s\n' "${fs:-none}" >&2
    if [[ -n "$fs" ]]; then warn "open these public ports in the provider firewall too"; fi
  else
    printf '  role      Foreign client (b) — tunnel only\n' >&2
    printf '  tunnel    %s · %s · %s · port %s · %s %s\n' "$TRANSPORT" "$OBFS" "$CIPHER" "$LISTEN_PORT" "$TUN" "$(tun_ip)" >&2
    msg "on the Iran server the peer must be this server's public IP: ${pub:-<unknown>}"
  fi
  return 0
}

ask_peer() { # ask_peer [DEFAULT] -> IP or domain, never a port
  local d="${1-}" h
  while true; do
    h="$(ask "Public IP / domain of the OTHER server (no port)" "$d")" || return 1
    h="$(normalize_input "$h")"
    if is_host "$h"; then printf '%s' "$h"; return 0; fi
    err "'$h' is not an IP or domain. Enter ONLY the address — no port, no ':'."
  done
}

repair() {
  need_root
  load_cfg || { err "nothing to repair — run install first"; pause; return 1; }
  hdr "repair"
  ensure_deps
  install -m 0755 "$SELF" "$MGR_DST" || { err "cannot write $MGR_DST"; pause; return 1; }
  ensure_binary || { pause; return 1; }
  write_units
  apply_netopt
  systemctl enable aestun >/dev/null 2>&1
  systemctl enable --now aestun-watchdog.timer >/dev/null 2>&1
  systemctl restart aestun
  apply_rules
  ufw_sync >/dev/null 2>&1
  msg "units rewritten, tuning applied, service restarted"
  pause
}

uninstall_all() {
  need_root
  if ! ask_yn "Remove EVERYTHING aestun installed (service, watchdog, core, config, firewall rules, tuning)?" N; then
    flash "cancelled — nothing removed"
    return 0
  fi
  load_cfg
  local port="$LISTEN_PORT" tp="$TRANSPORT" tun="$TUN"
  systemctl disable --now aestun-watchdog.timer aestun >/dev/null 2>&1
  flush_tag "$TAG_FWD"; flush_tag "$TAG_OPEN"; flush_tag "$TAG_TRUST"
  if command -v ufw >/dev/null 2>&1 && [[ -n "$port" ]]; then
    ufw delete allow "${port}/${tp}" >/dev/null 2>&1
    ufw delete allow in on "$tun" >/dev/null 2>&1
  fi
  ip link del "$tun" >/dev/null 2>&1
  rm -f "$SERVICE" "$WD_SERVICE" "$WD_TIMER" "$BIN_DST" "$MGR_DST" "$SYSCTL_FILE" "$BBR_MODCONF"
  rm -rf "$CONF_DIR" /var/log/aestun /run/aestun
  cleanup_legacy
  systemctl daemon-reload
  sysctl -q -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
  sysctl -q -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
  msg "aestun removed"
  exit 0
}

# ------------------------------------------------------------------------ menus
status_block() {
  local st role_txt f
  st="$(systemctl is-active aestun 2>/dev/null)"
  if [[ "$st" == active ]]; then st="${G}● active${N}"; else st="${R}● ${st:-unknown}${N}"; fi
  role_txt="Iran server (a)"
  [[ "$ROLE" == b ]] && role_txt="Foreign client (b)"
  printf '  service %s    role %s    %s %s\n' "$st" "$role_txt" "$TUN" "$(tun_ip)"
  printf '  peer %s    port %s    %s · %s · %s\n' "$PEER_HOST" "$LISTEN_PORT" "$TRANSPORT" "$OBFS" "$CIPHER"
  if [[ "$ROLE" == a ]]; then
    f="$(fwd_string)"
    printf '  forwards %s\n' "${f:-none}"
  fi
}

main_menu() {
  local c
  while true; do
    load_cfg
    clear_screen
    printf '%s  aestun%s  ·  anti-DPI tunnel manager\n\n' "$B$C" "$N"
    if (( CFG_OK == 0 )); then
      warn "not configured yet"
      printf '\n  %s1%s) install / setup        %s0%s) exit\n' "$C" "$N" "$C" "$N"
      c="$(read_choice)" || exit 0
      case "$c" in
        1) install_wizard; pause ;;
        *) exit 0 ;;
      esac
      continue
    fi
    status_block
    cat <<EOF

   ${C}1${N}) Live monitor                ${C}8${N}) Change peer IP
   ${C}2${N}) Diagnose & ping test        ${C}9${N}) Cipher / transport / obfs
   ${C}3${N}) Port forwards ${D}(Iran)${N}         ${C}10${N}) Anti-DPI toggles
   ${C}4${N}) Start / stop / restart      ${C}11${N}) DPI report
   ${C}5${N}) Live logs                   ${C}12${N}) New key (PSK)
   ${C}6${N}) Show config                 ${C}13${N}) Repair ${D}(keeps config)${N}
   ${C}7${N}) Edit config                 ${C}14${N}) Uninstall
                                    ${C}0${N}) Exit
EOF
    show_flash
    c="$(read_choice)" || exit 0
    case "$c" in
      1) menu_monitor ;;
      2) menu_diagnose ;;
      3) menu_forwards ;;
      4) menu_service ;;
      5) run_interruptible journalctl -u aestun -f -n 60 --no-pager ;;
      6) menu_show_config ;;
      7) menu_edit_config ;;
      8) menu_peer ;;
      9) menu_crypto ;;
      10) menu_antidpi ;;
      11) menu_dpi ;;
      12) menu_newkey ;;
      13) repair ;;
      14) uninstall_all ;;
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

run_interruptible() { # Ctrl-C stops the command only, not the menu
  trap ':' INT
  "$@"
  trap - INT
}

menu_monitor() {
  local quit=0 first=1 prev_tx=0 prev_rx=0 prev_t=0
  local now dt dtx drx age svc lnk rk k
  trap 'quit=1' INT
  clear_screen
  printf '\033[?25l'
  while (( quit == 0 )); do
    load_stats
    now="$(date +%s)"; dt=1; dtx=0; drx=0; age="-"
    if (( first == 0 )); then
      dt=$(( now - prev_t )); (( dt < 1 )) && dt=1
      dtx=$(( (ST_TX_BYTES - prev_tx) / dt )); drx=$(( (ST_RX_BYTES - prev_rx) / dt ))
      (( dtx < 0 )) && dtx=0
      (( drx < 0 )) && drx=0
    fi
    prev_tx=$ST_TX_BYTES; prev_rx=$ST_RX_BYTES; prev_t=$now; first=0
    (( ST_LAST_RX > 0 )) && age="$(( ST_NOW - ST_LAST_RX ))s"
    rk="static"; (( ST_REKEY > 0 )) && rk="every ${ST_REKEY}s"
    svc="$(systemctl is-active aestun 2>/dev/null)"
    lnk="$(ip -br link show "$TUN" 2>/dev/null | awk '{ print $2 }')"

    printf '\033[H%s  aestun monitor%s   %s   %sq quits%s\033[K\n' "$B$C" "$N" "$(date +%T)" "$D" "$N"
    printf '\n  service  %s    %s %s  %s\033[K\n' "${svc:-unknown}" "$TUN" "${lnk:-down}" "$(tun_ip)"
    printf '  peer     %s    last rx %s    uptime %s\033[K\n' "$ST_PEER" "$age" "$(fmt_dur "$ST_UPTIME")"
    printf '\n  TX  %14s   %12s/s   %s pkts\033[K\n' "$(human "$ST_TX_BYTES")" "$(human "$dtx")" "$ST_TX_PKTS"
    printf '  RX  %14s   %12s/s   %s pkts\033[K\n' "$(human "$ST_RX_BYTES")" "$(human "$drx")" "$ST_RX_PKTS"
    printf '\n  auth fail %s    replay drop %s    rekey %s\033[K\n' "$ST_AUTH_FAIL" "$ST_REPLAY" "$rk"
    if [[ "$ST_DPI_ON" == 1 ]]; then
      printf '  DPI  probes %s   replays %s   injections %s   ttl anomalies %s   loss %s%%   rtt %s ms\033[K\n' \
        "$ST_DPI_PROBES" "$ST_DPI_REPLAYS" "$ST_DPI_INJ" "$ST_DPI_TTL" "$ST_LOSS" "$ST_RTT"
    fi
    printf '\033[J'
    k=""
    read -r -t 2 -n 1 k || true
    [[ "$k" == [qQ] ]] && quit=1
  done
  printf '\033[?25h\n'
  trap - INT
}

menu_diagnose() {
  load_cfg
  clear_screen
  hdr "Diagnose"
  local bad=0 st state flag out avg cpu_hw p t pr n=0 good=0
  st="$(systemctl is-active aestun 2>/dev/null)"
  if [[ "$st" == active ]]; then msg "service: active"
  else err "service: ${st:-unknown}   →  journalctl -u aestun -n 50"; bad=1; fi

  state="$(ip -br link show "$TUN" 2>/dev/null | awk '{ print $2 }')"
  if [[ -n "$state" ]]; then msg "interface $TUN: $state  $(tun_ip)"
  else err "interface $TUN does not exist"; bad=1; fi

  flag="-lun"; [[ "$TRANSPORT" == tcp ]] && flag="-ltn"
  if ss -H "$flag" "sport = :${LISTEN_PORT}" 2>/dev/null | grep -q .; then
    msg "listening on ${LISTEN_PORT}/${TRANSPORT}"
  else
    err "nothing listens on ${LISTEN_PORT}/${TRANSPORT}"; bad=1
  fi
  if ipt -C INPUT -p "$TRANSPORT" --dport "$LISTEN_PORT" -m comment --comment "$TAG_OPEN" -j ACCEPT 2>/dev/null; then
    msg "local firewall: port open"
  else
    warn "local firewall: no accept rule (restarting aestun re-adds it)"
  fi

  cpu_hw="no"; cpu_has_aesni && cpu_hw="yes"
  printf '  cipher %s · AES-NI on this CPU: %s\n' "$CIPHER" "$cpu_hw"
  if [[ "$CIPHER" == aes-gcm && "$cpu_hw" == no ]]; then
    warn "aes-gcm without AES-NI runs in software — use chacha20-poly1305 on BOTH servers"
  fi

  if [[ -n "$PEER_IP" ]]; then
    out="$(ping -c 4 -W 2 "$PEER_IP" 2>&1)"
    if printf '%s' "$out" | grep -q ' 0% packet loss'; then
      avg="$(printf '%s' "$out" | awk -F/ '/^rtt|^round-trip/ { print $5 }')"
      msg "peer ${PEER_IP} replies (avg ${avg:-?} ms)"
    else
      err "peer ${PEER_IP} does not reply"; bad=1
    fi
  fi

  if [[ "$ROLE" == a ]]; then
    while read -r p t pr; do
      [[ -n "$p" ]] || continue
      n=$(( n + 1 ))
      if ipt -t nat -C PREROUTING -p "$pr" --dport "$p" -m comment --comment "$TAG_FWD" \
           -j DNAT --to-destination "${PEER_IP}:${t}" 2>/dev/null; then
        good=$(( good + 1 ))
      else
        warn "forward ${p}/${pr} → ${t}: rule missing"
      fi
    done < <(fwd_list)
    if (( n > 0 )); then msg "forwards: ${good}/${n} rules present"; fi
  fi

  if (( bad )); then
    printf '\n  %sIf the peer does not reply:%s\n' "$B" "$N"
    printf '   1. Run the same setup on the OTHER server with the same key, port %s, cipher and transport.\n' "$LISTEN_PORT"
    printf '   2. Open %s/%s in the provider firewall (security group / cloud firewall) on BOTH servers.\n' "$LISTEN_PORT" "$TRANSPORT"
    printf '   3. Check the peer IP (menu 8): a changed public IP silently breaks the link.\n'
    printf '   4. journalctl -u aestun -n 100 — key or cipher mismatches show up as auth failures.\n'
  fi
  pause
}

menu_forwards() {
  load_cfg
  if [[ "$ROLE" != a ]]; then
    flash "port forwards are configured on the Iran server only"
    return 0
  fi
  local c cur lines rmv keep
  while true; do
    load_cfg
    clear_screen
    hdr "Port forwards  (Iran server)"
    cur="$(fwd_string)"
    printf '  current: %s\n\n' "${cur:-none}"
    printf '  %s1%s) set the whole list     %s2%s) add ports     %s3%s) remove ports     %s0%s) back\n' \
      "$C" "$N" "$C" "$N" "$C" "$N" "$C" "$N"
    show_flash
    c="$(read_choice)" || return 0
    case "$c" in
      1) lines="$(read_ports "$cur")" || return 0
         printf '%s\n' "$lines" | fwd_save
         forwards_changed ;;
      2) lines="$(read_ports "")" || return 0
         { fwd_list; printf '%s\n' "$lines"; } | fwd_merge | fwd_save
         forwards_changed ;;
      3) lines="$(read_ports "")" || return 0
         rmv="$(printf '%s' "$lines" | tr '\n' ';')"
         keep="$(fwd_list | awk -v rmv="$rmv" '
           BEGIN { n = split(rmv, L, ";"); for (i = 1; i <= n; i++) { split(L[i], f, " "); if (f[1] != "") del[f[1] "/" f[3]] = 1 } }
           NF == 3 && !(($1 "/" $3) in del) { print }')"
         printf '%s\n' "$keep" | fwd_save
         forwards_changed ;;
      0|q|Q) return 0 ;;
      *) ;;
    esac
  done
}

forwards_changed() {
  local f
  flush_tag "$TAG_FWD"
  apply_rules
  ufw_sync >/dev/null 2>&1
  f="$(fwd_string)"
  flash "forwards applied: ${f:-none}"
}

menu_service() {
  local c st
  while true; do
    clear_screen
    hdr "Service"
    st="$(systemctl is-active aestun 2>/dev/null)"
    printf '  now: %s\n\n' "${st:-unknown}"
    printf '  %s1%s) start    %s2%s) stop    %s3%s) restart    %s0%s) back\n' "$C" "$N" "$C" "$N" "$C" "$N" "$C" "$N"
    show_flash
    c="$(read_choice)" || return 0
    case "$c" in
      1) if systemctl start aestun; then flash "started"; else flash "start failed — journalctl -u aestun -n 50"; fi ;;
      2) systemctl stop aestun; flash "stopped" ;;
      3) if systemctl restart aestun; then flash "restarted"; else flash "restart failed — journalctl -u aestun -n 50"; fi ;;
      0|q|Q) return 0 ;;
      *) ;;
    esac
  done
}

menu_peer() {
  load_cfg
  clear_screen
  hdr "Peer address"
  printf '  current: %s\n' "$PEER_HOST"
  local h
  h="$(ask_peer "$PEER_HOST")" || return 0
  if [[ "$h" == "$PEER_HOST" ]]; then flash "peer unchanged"; return 0; fi
  if cfg_patch 'c["peer"] = sys.argv[3]' "${h}:${LISTEN_PORT}"; then
    systemctl restart aestun >/dev/null 2>&1
    flash "peer set to ${h} — if the other server's IP changed too, update it there (menu 8)"
  else
    flash "could not save the peer"
  fi
}

menu_crypto() {
  local c
  while true; do
    load_cfg
    clear_screen
    hdr "Cipher / transport / obfs"
    printf '  %s1%s) cipher      %s    (chacha20-poly1305 | aes-gcm)\n' "$C" "$N" "$CIPHER"
    printf '  %s2%s) transport   %s    (udp | tcp)\n' "$C" "$N" "$TRANSPORT"
    printf '  %s3%s) obfs        %s    (quic | none)\n' "$C" "$N" "$OBFS"
    printf '\n  %sThese must be identical on both servers. Change both, then restart both.%s\n' "$Y" "$N"
    printf '  %s0%s) back\n' "$C" "$N"
    show_flash
    c="$(read_choice)" || return 0
    case "$c" in
      1) set_choice cipher "cipher" "$CIPHER" chacha20-poly1305 aes-gcm ;;
      2) set_choice transport "transport" "$TRANSPORT" udp tcp ;;
      3) set_choice obfs "obfs" "$OBFS" quic none ;;
      0|q|Q) return 0 ;;
      *) ;;
    esac
  done
}

set_choice() { # set_choice KEY PROMPT CURRENT OPTION...
  local key="$1" prompt="$2" cur="$3" v o
  shift 3
  v="$(ask "$prompt" "$cur")" || return 1
  for o in "$@"; do
    if [[ "$v" == "$o" ]]; then
      if cfg_patch 'c[sys.argv[3]] = sys.argv[4]' "$key" "$v"; then
        flash "${key} = ${v} — set the same value on the other server and restart both"
      else
        flash "could not save ${key}"
      fi
      return 0
    fi
  done
  flash "'${v}' is not one of: $*"
}

menu_antidpi() {
  local c
  while true; do
    load_cfg
    clear_screen
    hdr "Anti-DPI hardening"
    printf '  %s1%s) desync  [%s]  in-process fake packets (replaces zapret)\n' "$C" "$N" "$(onoff "$ON_DESYNC")"
    printf '  %s2%s) junk    [%s]  cover-traffic burst when a flow opens\n' "$C" "$N" "$(onoff "$ON_JUNK")"
    printf '  %s3%s) split   [%s]  IP-fragment the desync fakes\n' "$C" "$N" "$(onoff "$ON_SPLIT")"
    printf '  %s4%s) hop     [%s]  keyed UDP port hopping (ports: %s)\n' "$C" "$N" "$(onoff "$ON_HOP")" "$HOP_PORTS"
    printf '  %s5%s) set hop ports\n' "$C" "$N"
    printf '\n  %sAll off by default. Changes need a restart of BOTH servers.%s\n' "$D" "$N"
    printf '  %s0%s) back\n' "$C" "$N"
    show_flash
    c="$(read_choice)" || return 0
    case "$c" in
      1) toggle_block desync ;;
      2) toggle_block junk ;;
      3) toggle_block split ;;
      4) toggle_block hop ;;
      5) set_hop_ports ;;
      0|q|Q) return 0 ;;
      *) ;;
    esac
  done
}

toggle_block() { # toggle_block NAME — flips the "enabled" flag of an anti-DPI block
  if cfg_patch 'b = c.setdefault(sys.argv[3], {}); b["enabled"] = not b.get("enabled", False)' "$1"; then
    flash "$1 toggled — restart BOTH servers to apply"
  else
    flash "could not change $1"
  fi
}

set_hop_ports() {
  local ans ports
  ans="$(ask "hop ports, comma separated (same order on BOTH servers)" "${HOP_PORTS// /,}")" || return 0
  ports="$(normalize_input "$ans")"
  if cfg_patch 'c.setdefault("hop", {})["ports"] = [int(x) for x in sys.argv[3].split(",") if x.isdigit()]' "$ports"; then
    flash "hop ports set — open them on BOTH servers and restart both"
  else
    flash "could not save hop ports"
  fi
}

menu_dpi() {
  local c
  while true; do
    load_cfg
    clear_screen
    hdr "DPI / probe log"
    printf '  logging %s    file %s\n\n' "$(onoff "$DPI_ON")" "$DPI_LOG"
    printf '  %s1%s) report — last 24 h     %s2%s) report — last 7 days\n' "$C" "$N" "$C" "$N"
    printf '  %s3%s) toggle logging         %s4%s) clear the log       %s0%s) back\n' "$C" "$N" "$C" "$N" "$C" "$N"
    show_flash
    c="$(read_choice)" || return 0
    case "$c" in
      1) "$BIN_DST" dpi-report -log "$DPI_LOG" -hours 24 2>&1 | ${PAGER:-less -R} ;;
      2) "$BIN_DST" dpi-report -log "$DPI_LOG" -hours 168 2>&1 | ${PAGER:-less -R} ;;
      3) if cfg_patch 'd = c.setdefault("dpi_log", {}); d["enabled"] = not d.get("enabled", True)'; then
           flash "DPI logging toggled — restart aestun to apply"
         fi ;;
      4) rm -f "$DPI_LOG" "$DPI_LOG".[0-9] 2>/dev/null; flash "log cleared" ;;
      0|q|Q) return 0 ;;
      *) ;;
    esac
  done
}

menu_show_config() {
  clear_screen
  hdr "config.json  (key hidden)"
  if [[ -f "$CONF" ]]; then
    sed -E 's/("key"[[:space:]]*:[[:space:]]*")[^"]*/\1********/' "$CONF"
  fi
  pause
}

menu_edit_config() {
  local ed="${EDITOR:-}"
  [[ -n "$ed" ]] || ed="$(command -v nano || command -v vi)"
  "$ed" "$CONF"
  if ask_yn "restart aestun to apply?" Y; then
    if systemctl restart aestun; then flash "restarted"; else flash "restart failed — journalctl -u aestun -n 50"; fi
  fi
}

menu_newkey() {
  local k
  k="$(head -c 32 /dev/urandom | base64)"
  clear_screen
  hdr "New key"
  printf '  %s%s%s\n\n' "$B" "$k" "$N"
  printf '  Put this SAME key on the other server. It is not applied yet.\n\n'
  if ask_yn "Apply it to THIS server now (restarts aestun)?" N; then
    if cfg_patch 'c["key"] = sys.argv[3]' "$k"; then
      systemctl restart aestun >/dev/null 2>&1
      flash "key applied here — apply the same key on the other server now"
    else
      flash "could not save the key"
    fi
  else
    pause
    flash "key not applied"
  fi
}

# ------------------------------------------------------------------ dispatcher
usage() {
  cat >&2 <<'USAGE'
aestun.sh — anti-DPI tunnel manager

  sudo ./aestun.sh               menu
  sudo ./aestun.sh install       first-time setup (run on each server)
  sudo ./aestun.sh repair        rewrite units + watchdog + tuning, keep config, restart
  sudo ./aestun.sh uninstall     remove everything
  ./aestun.sh build [amd64|arm64] [obfuscate]
  ./aestun.sh fetch-core         download the core next to this script
  ./aestun.sh dpi-report [hours]
USAGE
}

case "${1:-menu}" in
  menu)                 need_root; main_menu ;;
  install)              need_root; install_wizard; pause ;;
  repair)               need_root; repair ;;
  uninstall)            need_root; uninstall_all ;;
  apply-rules|fwd-rule) apply_rules ;;   # fwd-rule: name used by the previous version
  watchdog)             watchdog ;;
  zap-rule)             exit 0 ;;        # the zapret module is gone; nothing to do
  build)                shift; do_build "$@" ;;
  dpi-report)           shift; "$BIN_DST" dpi-report -log "$DPI_LOG" -hours "${1:-24}" ;;
  fetch-core)           need_root; fetch_core ;;
  -h|--help|help)       usage ;;
  *)                    err "unknown command: $1"; usage; exit 1 ;;
esac
