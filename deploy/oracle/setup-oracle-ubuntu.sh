#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/lightwinter-retailos"
REPO_URL="${REPO_URL:-}"
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN:-lightwinter}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"
PUBLIC_HOST="${PUBLIC_HOST:-${DUCKDNS_DOMAIN}.duckdns.org}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${PUBLIC_HOST}}"

if [[ -z "${REPO_URL}" ]]; then
  echo "Set REPO_URL to the Git repository URL before running this script."
  exit 1
fi

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git nginx certbot python3-certbot-nginx

if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

sudo mkdir -p "${APP_DIR}"
sudo chown "$USER":"$USER" "${APP_DIR}"
if [[ ! -d "${APP_DIR}/.git" ]]; then
  git clone "${REPO_URL}" "${APP_DIR}"
else
  git -C "${APP_DIR}" pull --ff-only
fi

if [[ ! -f "${APP_DIR}/deploy/.env.oracle" ]]; then
  cp "${APP_DIR}/deploy/oracle/.env.oracle.example" "${APP_DIR}/deploy/.env.oracle"
  DB_PASS="$(openssl rand -base64 36 | tr -d '\n')"
  JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
  sed -i "s#replace-with-a-long-random-database-password#${DB_PASS}#g" "${APP_DIR}/deploy/.env.oracle"
  sed -i "s#replace-with-a-long-random-jwt-secret#${JWT_SECRET}#g" "${APP_DIR}/deploy/.env.oracle"
fi

sudo mkdir -p /var/www/certbot
sudo cp "${APP_DIR}/deploy/nginx/lightwinter-duckdns.conf" /etc/nginx/sites-available/lightwinter-duckdns.conf
sudo sed -i "s/lightwinter.duckdns.org/${PUBLIC_HOST}/g" /etc/nginx/sites-available/lightwinter-duckdns.conf
sudo ln -sf /etc/nginx/sites-available/lightwinter-duckdns.conf /etc/nginx/sites-enabled/lightwinter-duckdns.conf
sudo nginx -t
sudo systemctl reload nginx

if [[ -n "${DUCKDNS_TOKEN}" ]]; then
  sudo tee /usr/local/bin/lightwinter-duckdns-update >/dev/null <<EOF
#!/usr/bin/env bash
curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip="
EOF
  sudo chmod +x /usr/local/bin/lightwinter-duckdns-update
  sudo tee /etc/systemd/system/lightwinter-duckdns.service >/dev/null <<'EOF'
[Unit]
Description=Update Light Winter DuckDNS address

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lightwinter-duckdns-update
EOF
  sudo tee /etc/systemd/system/lightwinter-duckdns.timer >/dev/null <<'EOF'
[Unit]
Description=Run Light Winter DuckDNS updater every five minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=5min
Unit=lightwinter-duckdns.service

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now lightwinter-duckdns.timer
  sudo /usr/local/bin/lightwinter-duckdns-update
fi

docker compose --env-file "${APP_DIR}/deploy/.env.oracle" -f "${APP_DIR}/deploy/docker-compose.oracle.yml" up -d --build

sudo certbot --nginx -d "${PUBLIC_HOST}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" --redirect

echo "Light Winter RetailOS backend is live at https://${PUBLIC_HOST}"
echo "Swagger is live at https://${PUBLIC_HOST}/docs"
