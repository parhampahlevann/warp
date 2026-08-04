#!/usr/bin/env bash
# ============================================================
#  Xray VLESS + REALITY - SIMPLE, RELIABLE SETUP SCRIPT
#  Works on any Ubuntu version (18.04 / 20.04 / 22.04 / 24.04)
# ============================================================
set -euo pipefail

REALITY_PORT=443                  # standard HTTPS port -> less suspicious than a custom port
MASQ_DOMAIN="www.microsoft.com"   # domain the traffic will masquerade as

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

# ------------------------------------------------------------
# FOREIGN SERVER MODE - asks nothing
# ------------------------------------------------------------
setup_foreign() {
  install_prereqs
  enable_bbr

  echo "==> Generating Reality keypair (X25519) ..."
  KEYS=$(/usr/local/bin/xray x25519 2>&1) || true
  PRIVATE_KEY=$(echo "$KEYS" | grep -ioP 'private\s*key\S*\s*[:=]\s*\K\S+' || true)
  PUBLIC_KEY=$(echo "$KEYS" | grep -ioP 'public\s*key\S*\s*[:=]\s*\K\S+' || true)
  UUID=$(/usr/local/bin/xray uuid 2>&1) || true
  SHORT_ID=$(openssl rand -hex 8)

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo ""
    echo "Could not auto-parse the key output. Raw output from 'xray x25519' was:"
    echo "------------------------------------------------------------------"
    echo "$KEYS"
    echo "------------------------------------------------------------------"
    echo "Copy the Private key and Public key values from above and paste them here:"
    read -rp "Private key: " PRIVATE_KEY
    read -rp "Public key: " PUBLIC_KEY
    PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
      echo "ERROR: keys still empty. Aborting."
      exit 1
    fi
  fi

  if [ -z "$UUID" ] || [[ ! "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "Could not auto-generate a valid UUID. Raw output was: $UUID"
    read -rp "Paste a UUID manually (or run 'xray uuid' yourself and paste it): " UUID
  fi

  echo "==> Detecting this server's public IP ..."
  SERVER_IP=$(detect_public_ip) || {
    echo "Could not auto-detect the public IP."
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
  echo "------------------------------------------------------------------"
  echo " Copy these 3 values - the Iran server setup will ask for them:"
  echo ""
  echo " Foreign IP : ${SERVER_IP}"
  echo " UUID       : ${UUID}"
  echo " PUBLIC_KEY : ${PUBLIC_KEY}"
  echo " SHORT_ID   : ${SHORT_ID}"
  echo "=================================================================="
  echo " (also saved to /root/reality-info.txt on this server)"
}

# ------------------------------------------------------------
# IRAN SERVER MODE - asks for the foreign IP, the 3 values above, and ports
# ------------------------------------------------------------
setup_iran() {
  read -rp "Foreign server IP: " SERVER_IP
  read -rp "UUID (from the foreign server output): " UUID
  read -rp "PUBLIC_KEY (from the foreign server output): " PUBLIC_KEY
  read -rp "SHORT_ID (from the foreign server output): " SHORT_ID
  read -rp "Ports you want tunneled, comma-separated (e.g. 1080,443,23902,8080): " PORTS_RAW

  SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
  UUID=$(echo "$UUID" | tr -d '[:space:]')
  PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')
  SHORT_ID=$(echo "$SHORT_ID" | tr -d '[:space:]')

  if [ -z "$SERVER_IP" ] || [ -z "$UUID" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
    echo "ERROR: one of SERVER_IP / UUID / PUBLIC_KEY / SHORT_ID is empty."
    echo "Run this on the FOREIGN server first (option 1) and copy its output. Aborting."
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
  echo " Test: curl -x socks5://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:<PORT> https://ifconfig.me"
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
      echo " Xray service : NOT RUNNING  <-- run: systemctl restart xray"
      return
    fi
    if ss -tln | grep -q ":${PORT} "; then
      echo " Listening on port ${PORT} : YES"
    else
      echo " Listening on port ${PORT} : NO  <-- problem"
    fi
    journalctl -u xray -n 5 --no-pager | sed 's/^/   /'

  elif [ -f /root/proxy-info.txt ]; then
    echo "==> Detected role: IRAN SERVER"
    echo "------------------------------------------------------------------"
    # shellcheck disable=SC1090
    source /root/proxy-info.txt
    if systemctl is-active --quiet xray; then
      echo " Xray service : RUNNING"
    else
      echo " Xray service : NOT RUNNING  <-- run: systemctl restart xray"
      return
    fi
    FIRST_PORT=$(echo "$PORTS" | cut -d',' -f1)
    echo " Testing real tunnel traffic through port ${FIRST_PORT} ..."
    RESULT=$(curl -s -m 10 -w "\n__TIME__:%{time_total}\n__CODE__:%{http_code}" \
      -x "socks5://${USER}:${PASS}@127.0.0.1:${FIRST_PORT}" https://ifconfig.me 2>/dev/null || true)
    EXIT_IP=$(echo "$RESULT" | head -n1)
    TIME=$(echo "$RESULT" | grep "__TIME__" | cut -d':' -f2 || true)
    CODE=$(echo "$RESULT" | grep "__CODE__" | cut -d':' -f2 || true)
    if [ "$CODE" == "200" ]; then
      echo " Tunnel test  : SUCCESS"
      echo " Exit IP seen : ${EXIT_IP}"
      if [ "${EXIT_IP}" == "${FOREIGN_IP:-}" ]; then
        echo " Exit IP matches the foreign server -> tunnel confirmed working."
      fi
      echo " Round-trip time : ${TIME}s"
    else
      echo " Tunnel test  : FAILED - check: journalctl -u xray -n 30"
    fi
  else
    echo "No installation found on this server."
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
  rm -rf /usr/local/etc/xray
  rm -f /etc/sysctl.d/99-tunnel-tuning.conf

  echo "Uninstall complete."
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
