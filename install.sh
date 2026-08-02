#!/usr/bin/env bash
# ============================================================
#  Xray VLESS + REALITY - UNIFIED SETUP SCRIPT
#  (Foreign server / Iran server)
#  Works on any Ubuntu version (18.04 / 20.04 / 22.04 / 24.04)
# ============================================================
set -euo pipefail

REALITY_PORT=443                  # standard HTTPS port -> less suspicious than a custom port
MASQ_DOMAIN="www.microsoft.com"   # domain the traffic will masquerade as

# ------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------
install_prereqs() {
  echo "==> Updating system and installing prerequisites ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl unzip jq openssl cron ufw

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

# ------------------------------------------------------------
# FOREIGN SERVER MODE
# ------------------------------------------------------------
setup_foreign() {
  install_prereqs
  enable_bbr

  echo "==> Generating Reality keypair (X25519) ..."
  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | awk '/Private key:/ {print $3}')
  PUBLIC_KEY=$(echo "$KEYS" | awk '/Public key:/ {print $3}')

  UUID=$(/usr/local/bin/xray uuid)
  SHORT_ID=$(openssl rand -hex 8)

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

  SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com)

  cat > /root/reality-info.txt <<EOF
SERVER_IP=${SERVER_IP}
PORT=${REALITY_PORT}
UUID=${UUID}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${MASQ_DOMAIN}
EOF

  echo ""
  echo "=================================================================="
  echo " Foreign server setup complete."
  echo " Copy this info - you'll need it when running this script on the Iran server:"
  echo "------------------------------------------------------------------"
  cat /root/reality-info.txt
  echo "=================================================================="
  echo " (also saved to /root/reality-info.txt)"
}

# ------------------------------------------------------------
# IRAN SERVER MODE
# ------------------------------------------------------------
setup_iran() {
  read -rp "Foreign server IP: " SERVER_IP
  read -rp "UUID: " UUID
  read -rp "PUBLIC_KEY: " PUBLIC_KEY
  read -rp "SHORT_ID: " SHORT_ID
  read -rp "Ports you want tunneled, comma-separated (e.g. 1080,443,23902,8080): " PORTS_RAW

  IFS=',' read -ra PORT_ARRAY <<< "$PORTS_RAW"
  for i in "${!PORT_ARRAY[@]}"; do
    PORT_ARRAY[$i]=$(echo "${PORT_ARRAY[$i]}" | tr -d '[:space:]')
  done

  if [ "${#PORT_ARRAY[@]}" -eq 0 ]; then
    echo "No ports entered. Aborting."
    exit 1
  fi

  install_prereqs
  enable_bbr

  PROXY_USER="user_$(openssl rand -hex 3)"
  PROXY_PASS=$(openssl rand -hex 8)

  INBOUNDS_JSON="[]"
  for PORT in "${PORT_ARRAY[@]}"; do
    INBOUNDS_JSON=$(echo "$INBOUNDS_JSON" | jq \
      --arg port "$PORT" \
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
  for PORT in "${PORT_ARRAY[@]}"; do
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  done
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true

  echo "==> Enabling and starting the service ..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 1
  systemctl --no-pager status xray | head -n 5

  IRAN_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com)

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
        echo " Exit IP matches foreign server IP -> tunnel confirmed working correctly."
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
    source /root/reality-info.txt
    ufw delete allow ${PORT}/tcp >/dev/null 2>&1 || true
    rm -f /root/reality-info.txt
  fi

  if [ -f /root/proxy-info.txt ]; then
    source /root/proxy-info.txt
    IFS=',' read -ra P <<< "$PORTS"
    for p in "${P[@]}"; do
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
    done
    rm -f /root/proxy-info.txt
  fi

  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove >/dev/null 2>&1 || true
  rm -rf /usr/local/etc/xray
  rm -f /etc/sysctl.d/99-tunnel-tuning.conf

  echo "Uninstall complete. All tunnel components have been removed."
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
read -rp "Enter a number (1-5): " MODE

case "$MODE" in
  1) setup_foreign ;;
  2) setup_iran ;;
  3) check_status ;;
  4) uninstall_tunnel ;;
  5) echo "Bye." ; exit 0 ;;
  *) echo "Invalid option." ; exit 1 ;;
esac
