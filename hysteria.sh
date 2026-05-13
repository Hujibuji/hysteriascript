#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/hysteria/config.yaml"
MASQ_DIR="/var/www/masq"
SYSCTL="/etc/sysctl.d/99-hysteria.conf"
SERVICE="hysteria-server.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти от root: sudo bash install-hy2.sh"
  exit 1
fi

if [ ! -f /etc/debian_version ]; then
  echo "Скрипт рассчитан на Debian/Ubuntu."
  exit 1
fi

read -rp "Домен, например vpn.example.com: " DOMAIN
read -rp "Email для ACME/Let's Encrypt: " EMAIL
read -rsp "Пароль Hysteria. Пусто = сгенерировать: " PASSWORD
echo

if [ -z "$DOMAIN" ]; then
  echo "Домен пустой."
  exit 1
fi

if [ -z "$EMAIL" ]; then
  echo "Email пустой."
  exit 1
fi

apt-get update -y

DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

apt-get install -y curl ca-certificates openssl ufw iproute2

if [ -z "$PASSWORD" ]; then
  PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
fi

mkdir -p "$MASQ_DIR"

cat > "$MASQ_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Мы скоро откроемся</title>
  <style>
    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at top left, rgba(255, 128, 171, 0.24), transparent 34%),
        radial-gradient(circle at bottom right, rgba(96, 165, 250, 0.22), transparent 38%),
        linear-gradient(135deg, #0f172a, #111827);
      color: #f8fafc;
    }

    main {
      width: min(92vw, 680px);
      padding: 42px;
      border: 1px solid rgba(255, 255, 255, 0.14);
      border-radius: 28px;
      background: rgba(15, 23, 42, 0.68);
      box-shadow: 0 30px 90px rgba(0, 0, 0, 0.42);
      backdrop-filter: blur(18px);
      text-align: center;
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 14px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.08);
      color: #cbd5e1;
      font-size: 14px;
      margin-bottom: 22px;
    }

    h1 {
      margin: 0;
      font-size: clamp(34px, 7vw, 64px);
      line-height: 1.03;
      letter-spacing: -0.06em;
    }

    p {
      margin: 20px auto 0;
      max-width: 520px;
      color: #cbd5e1;
      font-size: 18px;
      line-height: 1.65;
    }

    .heart {
      display: inline-block;
      animation: pulse 1.5s ease-in-out infinite;
    }

    @keyframes pulse {
      0%, 100% {
        transform: scale(1);
      }

      50% {
        transform: scale(1.12);
      }
    }
  </style>
</head>
<body>
  <main>
    <div class="badge">Сайт готовится к запуску</div>
    <h1>Мы скоро откроемся <span class="heart">❤️</span></h1>
    <p>Здесь скоро появится сайт. Сейчас страница работает в техническом режиме.</p>
  </main>
</body>
</html>
EOF

chmod -R 755 "$MASQ_DIR"

bash <(curl -fsSL https://get.hy2.sh/)

mkdir -p /etc/hysteria

cat > "$CONFIG" <<EOF
listen: :443

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

auth:
  type: password
  password: "${PASSWORD}"

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

congestion:
  type: bbr
  bbrProfile: aggressive

disableUDP: false
udpIdleTimeout: 60s

masquerade:
  type: file
  file:
    dir: /var/www/masq
  listenHTTP: :80
  listenHTTPS: :443
  forceHTTPS: true
EOF

chmod 600 "$CONFIG"

cat > "$SYSCTL" <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=16777216
net.core.wmem_default=16777216
EOF

sysctl --system >/dev/null

SSH_PORT="22"

if [ -n "${SSH_CONNECTION:-}" ]; then
  SSH_PORT="$(echo "$SSH_CONNECTION" | awk '{print $4}')"
elif command -v sshd >/dev/null 2>&1; then
  SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
fi

if [ -z "$SSH_PORT" ]; then
  SSH_PORT="22"
fi

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

systemctl daemon-reload
systemctl enable --now "$SERVICE"
systemctl restart "$SERVICE"

sleep 4

echo
echo "=============================="
echo "Hysteria 2 installation result"
echo "=============================="
echo "Domain: $DOMAIN"
echo "Config: $CONFIG"
echo "Masquerade dir: $MASQ_DIR"
echo "SSH port allowed: $SSH_PORT/tcp"
echo "Allowed ports: 80/tcp, 443/tcp, 443/udp"
echo
echo "Password:"
echo "$PASSWORD"
echo
echo "Service status:"
systemctl --no-pager --full status "$SERVICE" || true
echo
echo "Listening ports:"
ss -lntup | grep -E ':(80|443)\s' || true
echo
echo "Recent logs:"
journalctl --no-pager -u "$SERVICE" -n 35 || true
echo
echo "Done."
HY2_LINK="hysteria2://${PASSWORD}@${DOMAIN}:443/?sni=${DOMAIN}&upmbps=30&downmbps=150#Hysteria"

echo
echo "=============================="
echo "Hysteria URI"
echo "=============================="
echo
echo "$HY2_LINK"
echo
exit 0
