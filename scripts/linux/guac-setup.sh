#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose nginx-full certbot python3-certbot-nginx postgresql-client jq ssl-cert
systemctl enable --now docker || true
# Wait briefly for Docker daemon to be ready
for i in $(seq 1 20); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

# Configure DNS to use DC for lab resolution
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/lab.conf <<EOF
[Resolve]
DNS=${dc_ip}
Domains=${domain_name}
FallbackDNS=8.8.8.8
EOF
systemctl restart systemd-resolved || true

mkdir -p /opt/guac && cd /opt/guac
# Pre-pull images with retries (network hiccups)
for img in guacamole/guacamole:1.5.5 guacamole/guacd:1.5.5 postgres:15; do
  n=0
  until [ $n -ge 5 ]; do
    docker pull "$img" && break
    n=$((n+1))
    sleep 5
  done
done

docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql > /opt/guac/initdb.sql

cat > /opt/guac/docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: guacamole_db
      POSTGRES_USER: guac
      POSTGRES_PASSWORD: ${guac_db_password}
    volumes:
      - guac-db:/var/lib/postgresql/data
      - ./initdb.sql:/docker-entrypoint-initdb.d/initdb.sql:ro
    restart: unless-stopped
  guacd:
    image: guacamole/guacd:1.5.5
    restart: unless-stopped
  guacamole:
    image: guacamole/guacamole:1.5.5
    environment:
      GUACD_HOSTNAME: guacd
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_DATABASE: guacamole_db
      POSTGRESQL_USER: guac
      POSTGRESQL_PASSWORD: ${guac_db_password}
      GUACAMOLE_HOME: /guac-home
    volumes:
      - guac-home:/guac-home
    ports:
      - "8080:8080"
    depends_on:
      - guacd
      - postgres
    restart: unless-stopped
volumes:
  guac-db:
  guac-home:
EOF

docker-compose -f /opt/guac/docker-compose.yml up -d

cat > /etc/nginx/sites-available/guac <<'EOF'
server {
  listen 80 default_server;
  server_name _;
  location / { return 301 https://$host$request_uri; }
}
server {
  listen 443 ssl;
  server_name _;
  ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
  ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
  # WebSocket tunnel for low-latency RDP/SSH
  location /guacamole/websocket-tunnel {
    proxy_pass http://127.0.0.1:8080/guacamole/websocket-tunnel;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
  }
  # Default reverse proxy to Guacamole
  location / {
    proxy_pass http://127.0.0.1:8080/guacamole/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Host $host;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }
}
EOF
ln -sf /etc/nginx/sites-available/guac /etc/nginx/sites-enabled/guac
rm -f /etc/nginx/sites-enabled/default || true
systemctl restart nginx

# Ensure Guacamole web is up
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%%{http_code}' http://127.0.0.1:8080/guacamole/ || true)
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then break; fi
  sleep 5
done

TOKEN=$(curl -sS -X POST 'http://127.0.0.1:8080/guacamole/api/tokens' --data 'username=guacadmin&password=guacadmin' | jq -r .authToken || true)
if [ -n "$${TOKEN:-}" ] && [ "$TOKEN" != "null" ]; then
  # Create an SSH connection to Ubuntu (before password change)
  if [ -n "$${TOKEN:-}" ] && [ "$TOKEN" != "null" ]; then
    payload=$(cat <<JSON
{
  "parentIdentifier": "ROOT",
  "name": "Ubuntu SSH",
  "protocol": "ssh",
  "parameters": {
    "port": "22",
    "read-only": "",
    "swap-red-blue": "",
    "cursor": "",
    "color-depth": "",
    "clipboard-encoding": "",
    "disable-copy": "",
    "disable-paste": "",
    "dest-port": "",
    "recording-exclude-output": "",
    "recording-exclude-mouse": "",
    "recording-include-keys": "",
    "create-recording-path": "",
    "enable-sftp": "",
    "sftp-port": "",
    "sftp-server-alive-interval": "",
    "enable-audio": "",
    "color-scheme": "",
    "font-size": "",
    "scrollback": "",
    "timezone": "",
    "server-alive-interval": "",
    "backspace": "",
    "terminal-type": "",
    "create-typescript-path": "",
    "hostname": "${ubuntu_ip}",
    "host-key": "",
    "private-key": "",
    "username": "ubuntu",
    "password": "${ubuntu_password}",
    "passphrase": "",
    "font-name": "",
    "command": "",
    "locale": "",
    "typescript-path": "",
    "typescript-name": "",
    "recording-path": "",
    "recording-name": "",
    "sftp-root-directory": ""
  },
  "attributes": {
    "max-connections": "",
    "max-connections-per-user": "",
    "weight": "",
    "failover-only": "",
    "guacd-port": "",
    "guacd-encryption": "",
    "guacd-hostname": ""
  }
}
JSON
)
    curl -sS -X POST "http://127.0.0.1:8080/guacamole/api/session/data/postgresql/connections?token=$TOKEN" \
      -H 'Content-Type: application/json' -d "$payload" || true

    # Helper to create RDP connections
    create_rdp() {
      local name="$1" host="$2" domain="$3" user="$4" pass="$5"
      local rdp_payload
      rdp_payload=$(cat <<JSON
{
  "parentIdentifier": "ROOT",
  "name": "$name",
  "protocol": "rdp",
  "parameters": {
    "port": "3389",
    "read-only": "",
    "swap-red-blue": "",
    "cursor": "",
    "color-depth": "",
    "clipboard-encoding": "",
    "disable-copy": "",
    "disable-paste": "",
    "dest-port": "",
    "recording-exclude-output": "",
    "recording-exclude-mouse": "",
    "recording-include-keys": "",
    "create-recording-path": "",
    "enable-sftp": "",
    "sftp-port": "",
    "sftp-server-alive-interval": "",
    "enable-audio": "",
    "security": "",
    "disable-auth": "",
    "ignore-cert": "true",
    "gateway-port": "",
    "server-layout": "",
    "timezone": "",
    "console": "",
    "width": "",
    "height": "",
    "dpi": "",
    "resize-method": "",
    "console-audio": "",
    "disable-audio": "",
    "enable-audio-input": "",
    "enable-printing": "",
    "enable-drive": "",
    "create-drive-path": "",
    "enable-wallpaper": "",
    "enable-theming": "",
    "enable-font-smoothing": "",
    "enable-full-window-drag": "",
    "enable-desktop-composition": "",
    "enable-menu-animations": "",
    "disable-bitmap-caching": "",
    "disable-offscreen-caching": "",
    "disable-glyph-caching": "",
    "preconnection-id": "",
    "hostname": "$host",
    "username": "$user",
    "password": "$pass",
    "domain": "$domain",
    "gateway-hostname": "",
    "gateway-username": "",
    "gateway-password": "",
    "gateway-domain": "",
    "initial-program": "",
    "client-name": "",
    "printer-name": "",
    "drive-name": "",
    "drive-path": "",
    "static-channels": "",
    "remote-app": "",
    "remote-app-dir": "",
    "remote-app-args": "",
    "preconnection-blob": "",
    "load-balance-info": "",
    "recording-path": "",
    "recording-name": "",
    "sftp-hostname": "",
    "sftp-host-key": "",
    "sftp-username": "",
    "sftp-password": "",
    "sftp-private-key": "",
    "sftp-passphrase": "",
    "sftp-root-directory": "",
    "sftp-directory": ""
  },
  "attributes": {
    "max-connections": "",
    "max-connections-per-user": "",
    "weight": "",
    "failover-only": "",
    "guacd-port": "",
    "guacd-encryption": "",
    "guacd-hostname": ""
  }
}
JSON
)
      curl -sS -X POST "http://127.0.0.1:8080/guacamole/api/session/data/postgresql/connections?token=$TOKEN" \
        -H 'Content-Type: application/json' -d "$rdp_payload" || true
    }

    # Create RDP connections (DC/CA as Administrator; WRKST as alice and bob)
    create_rdp "DC RDP"    "${dc_ip_rdp}" "${domain_netbios}" "Administrator" "${domain_admin_password}"
    create_rdp "CA RDP"    "${ca_ip_rdp}" "${domain_netbios}" "Administrator" "${domain_admin_password}"
    create_rdp "WRKST RDP (alice)" "${ws_ip_rdp}" "${domain_netbios}" "alice" "${alice_password}"
    create_rdp "WRKST RDP (bob)"   "${ws_ip_rdp}" "${domain_netbios}" "bob"   "${bob_password}"
  fi

  # Now change guacadmin password
  curl -sS -X PUT "http://127.0.0.1:8080/guacamole/api/session/data/postgresql/users/guacadmin/password?token=$TOKEN" \
    -H 'Content-Type: application/json' --data '{"oldPassword":"guacadmin","newPassword":"${guac_admin_password}"}' || true
fi



