#!/usr/bin/env bash
# ============================================================
#  Xray VLESS + REALITY - UNIFIED SETUP SCRIPT (single-server model)
#  Works on any Ubuntu version (18.04 / 20.04 / 22.04 / 24.04)
# ============================================================
set -euo pipefail

REALITY_PORT=443                  # standard HTTPS port -> less suspicious than a custom port
MASQ_DOMAIN="www.microsoft.com"   # domain the traffic will masquerade as
KEYSHARE_PORT=18888

# ------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------
install_prereqs() {
  echo "==> Updating system and installing prerequisites ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl unzip jq openssl cron ufw python3

  echo "==> Installing Xray-core (latest official release) ..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

enable_bbr() {
  echo "==> Enabling BBR congestion control + TCP Fast Open (speed & stability) ..."
  cat > /etc/sysctl.d/99-tunnel-tuning.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl --system >/dev/null 2>&1 || true
}

# Robustly detect this machine's public IPv4 - tries several services,
# uses -f so an HTTP error page never gets mistaken for a real IP, and
# validates the result looks like an actual IPv4 address.
detect_public_ip() {
  local ip=""
  for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://ident.me"; do
    ip=$(curl -4 -fsS -m 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# Serves ONLY {SERVER_IP, PORT, UUID, PUBLIC_KEY, SHORT_ID, SNI} - never the
# private key - on a fixed port, for a maximum of 10 minutes or until the
# first successful fetch, whichever comes first. Then shuts itself down and
# closes the firewall port.
share_keys_temporarily() {
  mkdir -p /tmp/reality-share
  cat > /tmp/reality-share/reality-info-public.txt <<EOF
SERVER_IP=${SERVER_IP}
PORT=${REALITY_PORT}
UUID=${UUID}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${MASQ_DOMAIN}
EOF

  ufw allow ${KEYSHARE_PORT}/tcp >/dev/null 2>&1 || true

  nohup python3 - <<PYEOF >/tmp/reality-share/server.log 2>&1 &
import http.server, socketserver, threading, time, os

PORT = ${KEYSHARE_PORT}
DIRECTORY = "/tmp/reality-share"
os.chdir(DIRECTORY)

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        super().do_GET()
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    def log_message(self, *a):
        pass

httpd = socketserver.TCPServer(("0.0.0.0", PORT), Handler)

def auto_expire():
    time.sleep(600)
    try:
        httpd.shutdown()
    except Exception:
        pass

threading.Thread(target=auto_expire, daemon=True).start()
httpd.serve_forever()
PYEOF
  SERVER_PID=$!
  disown "$SERVER_PID"

  ( wait "$SERVER_PID" 2>/dev/null
    ufw delete allow ${KEYSHARE_PORT}/tcp >/dev/null 2>&1 || true
    rm -rf /tmp/reality-share
  ) &
  disown

  echo " Key-sharing service started on port ${KEYSHARE_PORT}."
  echo " It will close automatically after the first successful fetch, or in 10 minutes."
}

# ------------------------------------------------------------
# FOREIGN SERVER MODE - fully automatic, asks nothing
# ------------------------------------------------------------
setup_foreign() {
  install_prereqs
  enable_bbr

  echo "==> Generating Reality keypair (X25519) ..."
  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep -ioP 'private\s*key:\s*\K\S+')
  PUBLIC_KEY=$(echo "$KEYS" | grep -ioP 'public\s*key:\s*\K\S+')
  UUID=$(/usr/local/bin/xray uuid)
  SHORT_ID=$(openssl rand -hex 8)

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: could not parse Xray x25519 key output. Raw output was:"
    echo "$KEYS"
    exit 1
  fi

  echo "==> Detecting this server's public IP ..."
  SERVER_IP=$(detect_public_ip) || {
    echo "ERROR: could not auto-detect the public IP (all lookup services failed/blocked)."
    read -rp "Please enter this server's public IP manually: " SERVER_IP
  }

  mkdir -p /usr/local/etc/xray

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${MASQ_DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${MASQ_DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        },
        "sockopt": { "tcpFastOpen": true }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  echo "==> Opening firewall port ..."
  ufw allow ${REALITY_PORT}/tcp >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true

  echo "==> Enabling and starting the service ..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    echo "ERROR: xray failed to start. Log output:"
    journalctl -u xray -n 30 --no-pager
    exit 1
  fi

  cat > /root/reality-info.txt <<EOF
SERVER_IP=${SERVER_IP}
PORT=${REALITY_PORT}
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${MASQ_DOMAIN}
EOF

  echo ""
  echo "=================================================================="
  echo " Foreign server setup complete. Xray is running."
  echo " Server IP: ${SERVER_IP}"
  echo "=================================================================="
  echo " (full details saved to /root/reality-info.txt)"

  share_keys_temporarily

  echo ""
  echo " >>> Now go set up the Iran server (option 2) - it only needs this"
  echo " >>> server's IP (${SERVER_IP}) and will fetch everything else"
  echo " >>> automatically within the next 10 minutes."
}

# ------------------------------------------------------------
# IRAN SERVER MODE - asks only for the foreign IP and ports
# ------------------------------------------------------------
setup_iran() {
  read -rp "Foreign server IP: " SERVER_IP
  read -rp "Ports you want tunneled, comma-separated (e.g. 1080,443,23902,8080): " PORTS_RAW

  SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
  if [ -z "$SERVER_IP" ]; then
    echo "No foreign server IP entered. Aborting."
    exit 1
  fi

  IFS=',' read -ra PORT_ARRAY <<< "$PORTS_RAW"
  for i in "${!PORT_ARRAY[@]}"; do
    PORT_ARRAY[$i]=$(echo "${PORT_ARRAY[$i]}" | tr -d '[:space:]')
  done
  if [ "${#PORT_ARRAY[@]}" -eq 0 ]; then
    echo "No ports entered. Aborting."
    exit 1
  fi

  echo "==> Installing curl ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl >/dev/null 2>&1

  echo "==> Fetching Reality credentials from ${SERVER_IP}:${KEYSHARE_PORT} ..."
  REMOTE_INFO="/tmp/reality-info-remote.txt"
  rm -f "$REMOTE_INFO"

  if ! curl -fsS -m 15 "http://${SERVER_IP}:${KEYSHARE_PORT}/reality-info-public.txt" -o "$REMOTE_INFO"; then
    echo ""
    echo "Could not fetch credentials from ${SERVER_IP}."
    echo "This means the 10-minute key-sharing window on that server has already"
    echo "closed (or the foreign setup wasn't run there yet)."
    echo "Fix: on the foreign server, run this script again and choose option 6"
    echo "(Re-share Reality keys) to reopen the window for 10 more minutes, then"
    echo "re-run this Iran setup right away."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$REMOTE_INFO"
  echo "==> Got UUID / PUBLIC_KEY / SHORT_ID automatically. No manual entry needed."
  rm -f "$REMOTE_INFO"

  install_prereqs
  enable_bbr

  PROXY_USER="user_$(openssl rand -hex 3)"
  PROXY_PASS=$(openssl rand -hex 8)

  INBOUNDS_JSON="[]"
  for P in "${PORT_ARRAY[@]}"; do
    INBOUNDS_JSON=$(echo "$INBOUNDS_JSON" | jq \
      --arg port "$P" \
      --arg user "$PROXY_USER" \
      --arg pass "$PROXY_PASS" \
      '. + [{
        "listen": "0.0.0.0",
        "port": ($port | tonumber),
        "protocol": "socks",
        "settings": {
          "auth": "password",
          "accounts": [{ "user": $user, "pass": $pass }],
          "udp": true
        },
        "tag": ("socks-" + $port)
      }]')
  done

  mkdir -p /usr/local/etc/xray

  jq -n \
    --argjson inbounds "$INBOUNDS_JSON" \
    --arg server_ip "$SERVER_IP" \
    --argjson reality_port "$REALITY_PORT" \
    --arg uuid "$UUID" \
    --arg sni "$MASQ_DOMAIN" \
    --arg pubkey "$PUBLIC_KEY" \
    --arg shortid "$SHORT_ID" \
    '{
      "log": { "loglevel": "warning" },
      "inbounds": $inbounds,
      "outbounds": [
        {
          "protocol": "vless",
          "tag": "reality-out",
          "settings": {
            "vnext": [
              {
                "address": $server_ip,
                "port": $reality_port,
                "users": [
                  { "id": $uuid, "flow": "xtls-rprx-vision", "encryption": "none" }
                ]
              }
            ]
          },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "fingerprint": "chrome",
              "serverName": $sni,
              "publicKey": $pubkey,
              "shortId": $shortid
            },
            "sockopt": { "tcpFastOpen": true }
          }
        },
        { "protocol": "freedom", "tag": "direct" }
      ]
    }' > /usr/local/etc/xray/config.json

  echo "==> Opening firewall ports ..."
  for P in "${PORT_ARRAY[@]}"; do
    ufw allow "${P}/tcp" >/dev/null 2>&1 || true
  done
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true

  echo "==> Enabling and starting the service ..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    echo "ERROR: xray failed to start. Log output:"
    journalctl -u xray -n 30 --no-pager
    exit 1
  fi

  IRAN_IP=$(detect_public_ip) || IRAN_IP="unknown"

  cat > /root/proxy-info.txt <<EOF
IRAN_IP=${IRAN_IP}
FOREIGN_IP=${SERVER_IP}
PORTS=${PORTS_RAW}
USER=${PROXY_USER}
PASS=${PROXY_PASS}
EOF

  echo ""
  echo "=================================================================="
  echo " Iran server setup complete. Tunnel to ${SERVER_IP} is up."
  echo "------------------------------------------------------------------"
  echo " SOCKS5 ports open on ${IRAN_IP}: ${PORTS_RAW}"
  echo " Username : ${PROXY_USER}"
  echo " Password : ${PROXY_PASS}"
  echo "=================================================================="
  echo " (also saved to /root/proxy-info.txt)"
}

# ------------------------------------------------------------
# STATUS CHECK
# ------------------------------------------------------------
check_status() {
  if [ -f /root/reality-info.txt ]; then
    echo "==> Detected role: FOREIGN SERVER"
    echo "------------------------------------------------------------------"
    # shellcheck disable=SC1090
    source /root/reality-info.txt
    if systemctl is-active --quiet xray; then
      echo " Xray service : RUNNING"
    else
      echo " Xray service : NOT RUNNING  <-- problem, run: systemctl restart xray"
      return
    fi
    if ss -tln | grep -q ":${PORT} "; then
      echo " Listening on port ${PORT} : YES"
    else
      echo " Listening on port ${PORT} : NO  <-- problem"
    fi
    echo " Recent log lines:"
    journalctl -u xray -n 5 --no-pager | sed 's/^/   /'

  elif [ -f /root/proxy-info.txt ]; then
    echo "==> Detected role: IRAN SERVER"
    echo "------------------------------------------------------------------"
    # shellcheck disable=SC1090
    source /root/proxy-info.txt
    if systemctl is-active --quiet xray; then
      echo " Xray service : RUNNING"
    else
      echo " Xray service : NOT RUNNING  <-- problem, run: systemctl restart xray"
      return
    fi

    FIRST_PORT=$(echo "$PORTS" | cut -d',' -f1)
    echo " Testing real tunnel traffic through port ${FIRST_PORT} ..."
    RESULT=$(curl -s -m 10 -w "\n__TIME__:%{time_total}\n__CODE__:%{http_code}" \
      -x "socks5://${USER}:${PASS}@127.0.0.1:${FIRST_PORT}" https://ifconfig.me 2>/dev/null || true)

    EXIT_IP=$(echo "$RESULT" | head -n1)
    TIME=$(echo "$RESULT" | grep "__TIME__" | cut -d':' -f2)
    CODE=$(echo "$RESULT" | grep "__CODE__" | cut -d':' -f2)

    if [ "$CODE" == "200" ]; then
      echo " Tunnel test  : SUCCESS"
      echo " Exit IP seen : ${EXIT_IP}"
      if [ "${EXIT_IP}" == "${FOREIGN_IP:-}" ]; then
        echo " Exit IP matches the foreign server -> tunnel confirmed working correctly."
      else
        echo " NOTE: exit IP differs from stored FOREIGN_IP (${FOREIGN_IP:-unknown}) - check config."
      fi
      echo " Round-trip time : ${TIME}s"
    else
      echo " Tunnel test  : FAILED (no response through the tunnel)"
      echo " Check: systemctl status xray / journalctl -u xray -n 30"
    fi
  else
    echo "No installation found on this server (neither reality-info.txt nor proxy-info.txt exists)."
  fi
}

# ------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------
uninstall_tunnel() {
  echo "This will remove Xray, its config, and the firewall rules opened by this script."
  read -rp "Are you sure? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    return
  fi

  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true

  if [ -f /root/reality-info.txt ]; then
    # shellcheck disable=SC1090
    source /root/reality-info.txt
    ufw delete allow ${PORT}/tcp >/dev/null 2>&1 || true
    ufw delete allow ${KEYSHARE_PORT}/tcp >/dev/null 2>&1 || true
    rm -f /root/reality-info.txt
  fi

  if [ -f /root/proxy-info.txt ]; then
    # shellcheck disable=SC1090
    source /root/proxy-info.txt
    IFS=',' read -ra P <<< "$PORTS"
    for p in "${P[@]}"; do
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
    done
    rm -f /root/proxy-info.txt
  fi

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove >/dev/null 2>&1 || true
  rm -rf /usr/local/etc/xray /tmp/reality-share
  rm -f /etc/sysctl.d/99-tunnel-tuning.conf

  echo "Uninstall complete. All tunnel components have been removed."
}

# ------------------------------------------------------------
# RE-SHARE KEYS (foreign server only - reopens the 10-min window
# without regenerating keys)
# ------------------------------------------------------------
reshare_keys() {
  if [ ! -f /root/reality-info.txt ]; then
    echo "No foreign-server install found on this machine (reality-info.txt missing)."
    return
  fi
  # shellcheck disable=SC1090
  source /root/reality-info.txt
  echo "==> Reopening key-sharing window for 10 minutes on port ${KEYSHARE_PORT} ..."
  share_keys_temporarily
}

# ------------------------------------------------------------
# MENU
# ------------------------------------------------------------
echo "What do you want to do?"
echo "  1) Install - Foreign server (Reality server)"
echo "  2) Install - Iran server (Reality client + forwarded ports)"
echo "  3) Check tunnel status / test connection"
echo "  4) Uninstall"
echo "  5) Exit"
echo "  6) Re-share Reality keys (foreign server, if the 10-min window expired)"
read -rp "Enter a number (1-6): " MODE

case "$MODE" in
  1) setup_foreign ;;
  2) setup_iran ;;
  3) check_status ;;
  4) uninstall_tunnel ;;
  5) echo "Bye." ; exit 0 ;;
  6) reshare_keys ;;
  *) echo "Invalid option." ; exit 1 ;;
esac
