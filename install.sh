#!/bin/sh
set -e

#
# Lintune Installer
# Usage: curl -fsSL https://get.lintune.xyz | bash
#

INSTALL_DIR=/opt/lintune
ADMIN_IMAGE=ghcr.io/lintune/lintune-admin:latest
DASH_IMAGE=ghcr.io/lintune/lintune-dash:latest
BACKUP_IMAGE=ghcr.io/lintune/lintune-backup:latest
HEADSCALE_IMAGE=headscale/headscale:latest
CADDY_IMAGE=ghcr.io/lintune/caddy:latest
UPTIME_KUMA_IMAGE=ghcr.io/lintune/lintune-uptimekuma:latest
VW_IMAGE=vaultwarden/server:latest

# ── Output helpers ────────────────────────────────────────────────────────────

bold()    { printf "\033[1m%s\033[0m\n" "$*"; }
info()    { printf "\033[1;34m  →\033[0m %s\n" "$*"; }
ok()      { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
warn()    { printf "\033[1;33m  !\033[0m %s\n" "$*"; }
die()     { printf "\033[1;31mError:\033[0m %s\n" "$*" >&2; exit 1; }

# When piped through bash, stdin is the script — use /dev/tty for prompts
ask() {
    printf "\033[1;36m  ?\033[0m %s " "$1" >/dev/tty
    read -r REPLY </dev/tty
    printf '%s' "$REPLY"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

printf "\n"
bold "╔══════════════════════════════════╗"
bold "║       Lintune Installer          ║"
bold "╚══════════════════════════════════╝"
printf "\n"

[ "$(id -u)" -eq 0 ] || die "Run as root or with sudo."

command -v curl    >/dev/null 2>&1 || die "curl is required but not installed."
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed."

if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    warn "Lintune is already installed at $INSTALL_DIR."
    CONFIRM=$(ask "Reinstall? This will recreate config files but keep data volumes. [y/N]")
    case "$CONFIRM" in
        [yY]*) info "Continuing with reinstall..." ;;
        *) die "Aborted." ;;
    esac
fi

# ── Install Docker ────────────────────────────────────────────────────────────

if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    info "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed."
fi

# Ensure docker compose (v2 plugin) is available
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found. Install docker-compose-plugin and retry."

# ── Gather config ─────────────────────────────────────────────────────────────

printf "\n"
bold "Configuration"
printf "\n"

# ── Base domain ────────────────────────────────────────────────────────────────

BASE_DOMAIN=${BASE_DOMAIN:-$(ask "Base domain (e.g. lintune.company.com):")}
[ -n "$BASE_DOMAIN" ] || die "Base domain is required."

ADMIN_DOMAIN="admin.${BASE_DOMAIN}"
DASH_DOMAIN="dash.${BASE_DOMAIN}"
KUMA_DOMAIN="isitup.${BASE_DOMAIN}"
HS_DOMAIN="vpn.${BASE_DOMAIN}"

ADMIN_URL="https://${ADMIN_DOMAIN}"
DASH_URL="https://${DASH_DOMAIN}"
SESSION_SECURE=true

printf "\n"
info "Service subdomains (point all to this server's IP):"
info "  Admin panel  ->  ${ADMIN_DOMAIN}"
info "  Tenant dash  ->  ${DASH_DOMAIN}"
info "  Keycloak     ->  auth.${BASE_DOMAIN}"
info "  Mailcow      ->  mail.${BASE_DOMAIN}"
info "  Nextcloud    ->  cloud.${BASE_DOMAIN}"
info "  Vaultwarden  ->  vault.${BASE_DOMAIN}"
info "  Status       ->  ${KUMA_DOMAIN}"
info "  VPN Mesh     ->  ${HS_DOMAIN}"
printf "\n"

# ── Reverse proxy choice ───────────────────────────────────────────────────────

if [ -n "${USE_CADDY+x}" ]; then
    # Already set in environment — normalise to true/false
    case "$USE_CADDY" in
        [nN]*|false) USE_CADDY=false ;;
        *)           USE_CADDY=true  ;;
    esac
else
    USE_CADDY_REPLY=$(ask "Use Caddy as automatic reverse proxy with SSL for admin + dash? [Y/n]")
    case "$USE_CADDY_REPLY" in
        [nN]*) USE_CADDY=false ;;
        *)     USE_CADDY=true  ;;
    esac
fi

if $USE_CADDY; then
    info "Caddy will obtain SSL certificates via Cloudflare DNS challenge."
    info "Create a Cloudflare API token with Zone:DNS:Edit + Zone:Zone:Read for your zone."
    printf "\n"
    CF_API_TOKEN=${CF_API_TOKEN:-$(ask "Cloudflare API token:")}
    [ -n "$CF_API_TOKEN" ] || die "Cloudflare API token is required when using Caddy."
else
    printf "\n"
    info "Admin will be exposed on port 8889, tenant dashboard on port 8888."
    info "Point your reverse proxy to these ports for ${ADMIN_DOMAIN} and ${DASH_DOMAIN}."
fi
printf "\n"

# ── Generate secrets ──────────────────────────────────────────────────────────

info "Generating secrets..."
APP_KEY="base64:$(openssl rand -base64 32)"
DB_ROOT_PASSWORD=$(openssl rand -hex 20)
DB_PASSWORD=$(openssl rand -hex 20)
DB_DATABASE=lintune
DB_USERNAME=lintune
KUMA_DB_NAME=kuma
VW_ADMIN_PLAIN=$(openssl rand -base64 24)

ok "Secrets generated."

# ── Create install directory ──────────────────────────────────────────────────

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/logs"
chmod 700 "$INSTALL_DIR"
chmod 777 "$INSTALL_DIR/logs"

mkdir -p "$INSTALL_DIR/backup-data"
mkdir -p "$INSTALL_DIR/backups"
chmod 777 "$INSTALL_DIR/backup-data"
chmod 777 "$INSTALL_DIR/backups"

mkdir -p "$INSTALL_DIR/headscale-data"
chmod 700 "$INSTALL_DIR/headscale-data"

# ── Write Headscale config ────────────────────────────────────────────────────

cat > "$INSTALL_DIR/headscale-data/config.yaml" << EOF
server_url: https://${HS_DOMAIN}
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 0.0.0.0:50443
grpc_allow_insecure: false

noise:
  private_key_path: /etc/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

derp:
  server:
    enabled: true
    region_id: 999
    region_code: lintune
    region_name: "Lintune DERP"
    stun_listen_addr: "0.0.0.0:3479"
    private_key_path: /etc/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  paths: []
  auto_update_enabled: false
  update_frequency: 24h

disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m
node_update_check_interval: 10s

database:
  type: sqlite
  sqlite:
    path: /etc/headscale/db.sqlite

log:
  format: text
  level: info

policy:
  mode: file
  path: /etc/headscale/acls.yaml

dns:
  magic_dns: true
  base_domain: lintune.mesh
  override_local_dns: false
  nameservers:
    global: []
  search_domains: []
  extra_records: []

unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
EOF

cat > "$INSTALL_DIR/headscale-data/acls.yaml" << 'EOF'
{
  "acls": [
    {"action": "accept", "src": ["*"], "dst": ["*:*"]}
  ]
}
EOF

ok "Headscale config written."

# ── Write Caddyfile (only when using Caddy) ───────────────────────────────────

if $USE_CADDY; then
    # CF_API_TOKEN is passed via caddy.env at runtime — use Caddy's {$VAR} syntax, not shell expansion
    cat > "$INSTALL_DIR/Caddyfile" << 'CADDYEOF'
{
    acme_dns cloudflare {$CF_API_TOKEN}
}
CADDYEOF

    # Append the vhosts with the actual domain names (shell-expanded)
    cat >> "$INSTALL_DIR/Caddyfile" << EOF

${ADMIN_DOMAIN} {
    reverse_proxy lintune-admin:80
}

${DASH_DOMAIN} {
    reverse_proxy lintune-dash:80
}

${KUMA_DOMAIN} {
    reverse_proxy uptime-kuma:3001
}

${HS_DOMAIN} {
    reverse_proxy headscale:8080
}

vault.${BASE_DOMAIN} {
    reverse_proxy vaultwarden:80
}
EOF
    ok "Caddyfile written."
fi

# ── Write admin.env ───────────────────────────────────────────────────────────

cat > "$INSTALL_DIR/admin.env" << EOF
APP_NAME="Lintune Admin"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=${ADMIN_URL}
LOG_CHANNEL=stack
LOG_LEVEL=error
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
SESSION_DRIVER=database
SESSION_LIFETIME=120
SESSION_SECURE_COOKIE=${SESSION_SECURE}
DASH_URL=${DASH_URL}
BASE_DOMAIN=${BASE_DOMAIN}
KUMA_URL=https://${KUMA_DOMAIN}
KUMA_INTERNAL_URL=http://uptime-kuma:3001
BACKUP_SHARED_PATH=/var/lintune-backup
EOF

# 666 inside a 700 directory: host-protected but writable by the container's www-data.
# The install wizard writes Keycloak credentials and SETUP_COMPLETE back to this file.
chmod 666 "$INSTALL_DIR/admin.env"
ok "admin.env written."

if $USE_CADDY; then
    cat > "$INSTALL_DIR/caddy.env" << EOF
CF_API_TOKEN=${CF_API_TOKEN}
EOF
    chmod 600 "$INSTALL_DIR/caddy.env"
    ok "caddy.env written."
fi

# ── Write dash.env ────────────────────────────────────────────────────────────

cat > "$INSTALL_DIR/dash.env" << EOF
APP_NAME=Lintune
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=${DASH_URL}
LOG_CHANNEL=stack
LOG_LEVEL=error
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
SESSION_DRIVER=database
SESSION_LIFETIME=120
SESSION_SECURE_COOKIE=${SESSION_SECURE}
BASE_DOMAIN=${BASE_DOMAIN}
KEYCLOAK_BASE_URL=
KEYCLOAK_CLIENT_ID=lintune-frontend
KEYCLOAK_ALLOWED_GROUPS=realm-admin
KEYCLOAK_ADMIN_CLI_CLIENT=admin-cli
KUMA_INTERNAL_URL=http://uptime-kuma:3001
EOF

chmod 600 "$INSTALL_DIR/dash.env"
ok "dash.env written."

# ── Write vaultwarden.env ────────────────────────────────────────────────────

cat > "$INSTALL_DIR/vaultwarden.env" << EOF
DOMAIN=https://vault.${BASE_DOMAIN}
WEBSOCKET_ENABLED=true
SIGNUPS_ALLOWED=false
SSO_ENABLED=true
# Placeholders satisfy Vaultwarden's startup validation.
# Real values are written to /data/config.json by lintune-admin after Keycloak is configured —
# config.json takes precedence over these env vars without a container restart.
SSO_AUTHORITY=https://placeholder.invalid
SSO_CLIENT_ID=placeholder
SSO_CLIENT_SECRET=placeholder
EOF

# ADMIN_TOKEN (Argon2 hash) is appended below after images are pulled.
chmod 600 "$INSTALL_DIR/vaultwarden.env"
ok "vaultwarden.env written."

# ── Write secrets reference ───────────────────────────────────────────────────

cat > "$INSTALL_DIR/.env" << EOF
# Lintune — generated by installer on $(date -u '+%Y-%m-%d %H:%M UTC')
# Keep this file safe. Do not share it.
# Application env files: admin.env  dash.env

ADMIN_URL=${ADMIN_URL}
DASH_URL=${DASH_URL}

APP_KEY=${APP_KEY}

DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}

VW_ADMIN_TOKEN=${VW_ADMIN_PLAIN}
VW_ADMIN_URL=https://vault.${BASE_DOMAIN}/admin
EOF

chmod 600 "$INSTALL_DIR/.env"
ok "Secrets reference (.env) written."

# ── Write MariaDB init script ─────────────────────────────────────────────────

cat > "$INSTALL_DIR/init-kuma.sql" << EOF
CREATE DATABASE IF NOT EXISTS \`${KUMA_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${KUMA_DB_NAME}\`.* TO '${DB_USERNAME}'@'%';
FLUSH PRIVILEGES;
EOF

chmod 644 "$INSTALL_DIR/init-kuma.sql"
ok "MariaDB init script written."

# ── Write docker-compose.yml ──────────────────────────────────────────────────

if $USE_CADDY; then

cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:

  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
      - ./init-kuma.sql:/docker-entrypoint-initdb.d/init-kuma.sql:ro
    networks:
      - internal
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 10

  lintune-admin:
    image: ${ADMIN_IMAGE}
    restart: unless-stopped
    env_file: admin.env
    volumes:
      - ./admin.env:/var/www/html/lintune-admin/.env
      - ./logs:/var/www/html/lintune-admin/storage/logs/install
      - ${INSTALL_DIR}/backup-data:/var/lintune-backup
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  lintune-dash:
    image: ${DASH_IMAGE}
    restart: unless-stopped
    env_file: dash.env
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  lintune-backup:
    image: ${BACKUP_IMAGE}
    restart: unless-stopped
    environment:
      - BACKUP_CRON=0 2 * * *
      - BACKUP_PRIVATE_KEY_PATH=/backups/id_backup
      - BACKUP_STORAGE_PATH=/storage
    volumes:
      - ${INSTALL_DIR}/backup-data:/backups
      - ${INSTALL_DIR}/backups:/storage
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - internal

  headscale:
    image: ${HEADSCALE_IMAGE}
    restart: unless-stopped
    command: serve
    volumes:
      - ${INSTALL_DIR}/headscale-data:/etc/headscale
    ports:
      - "3479:3479/udp"
    networks:
      - internal

  caddy:
    image: ${CADDY_IMAGE}
    restart: unless-stopped
    env_file: caddy.env
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - internal

  uptime-kuma:
    image: ${UPTIME_KUMA_IMAGE}
    restart: unless-stopped
    environment:
      - UPTIME_KUMA_DB_TYPE=mariadb
      - UPTIME_KUMA_DB_HOSTNAME=db
      - UPTIME_KUMA_DB_PORT=3306
      - UPTIME_KUMA_DB_NAME=${KUMA_DB_NAME}
      - UPTIME_KUMA_DB_USERNAME=${DB_USERNAME}
      - UPTIME_KUMA_DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  vaultwarden:
    image: ${VW_IMAGE}
    restart: unless-stopped
    env_file: vaultwarden.env
    volumes:
      - vw_data:/data
    networks:
      - internal

volumes:
  db_data:
  caddy_data:
  caddy_config:
  vw_data:

networks:
  internal:
    driver: bridge
EOF

else

cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:

  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${DB_DATABASE}
      MARIADB_USER: ${DB_USERNAME}
      MARIADB_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
      - ./init-kuma.sql:/docker-entrypoint-initdb.d/init-kuma.sql:ro
    networks:
      - internal
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${DB_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 10

  lintune-admin:
    image: ${ADMIN_IMAGE}
    restart: unless-stopped
    ports:
      - "8889:80"
    env_file: admin.env
    volumes:
      - ./admin.env:/var/www/html/lintune-admin/.env
      - ./logs:/var/www/html/lintune-admin/storage/logs/install
      - ${INSTALL_DIR}/backup-data:/var/lintune-backup
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  lintune-dash:
    image: ${DASH_IMAGE}
    restart: unless-stopped
    ports:
      - "8888:80"
    env_file: dash.env
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal

  lintune-backup:
    image: ${BACKUP_IMAGE}
    restart: unless-stopped
    environment:
      - BACKUP_CRON=0 2 * * *
      - BACKUP_PRIVATE_KEY_PATH=/backups/id_backup
      - BACKUP_STORAGE_PATH=/storage
    volumes:
      - ${INSTALL_DIR}/backup-data:/backups
      - ${INSTALL_DIR}/backups:/storage
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - internal

  headscale:
    image: ${HEADSCALE_IMAGE}
    restart: unless-stopped
    command: serve
    volumes:
      - ${INSTALL_DIR}/headscale-data:/etc/headscale
    ports:
      - "8085:8080"
      - "3479:3479/udp"
    networks:
      - internal

  uptime-kuma:
    image: ${UPTIME_KUMA_IMAGE}
    restart: unless-stopped
    environment:
      - UPTIME_KUMA_DB_TYPE=mariadb
      - UPTIME_KUMA_DB_HOSTNAME=db
      - UPTIME_KUMA_DB_PORT=3306
      - UPTIME_KUMA_DB_NAME=${KUMA_DB_NAME}
      - UPTIME_KUMA_DB_USERNAME=${DB_USERNAME}
      - UPTIME_KUMA_DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "3001:3001"
    networks:
      - internal

  vaultwarden:
    image: ${VW_IMAGE}
    restart: unless-stopped
    env_file: vaultwarden.env
    volumes:
      - vw_data:/data
    ports:
      - "8887:80"
    networks:
      - internal

volumes:
  db_data:
  vw_data:

networks:
  internal:
    driver: bridge
EOF

fi

ok "docker-compose.yml written."

# ── Pull images and start ─────────────────────────────────────────────────────

printf "\n"
bold "Starting Lintune..."
printf "\n"

cd "$INSTALL_DIR"

info "Pulling images..."
docker compose pull

info "Generating Vaultwarden admin token hash..."
if ! command -v argon2 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -q argon2 >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q argon2 >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q argon2 >/dev/null 2>&1 || true
    fi
fi
if command -v argon2 >/dev/null 2>&1; then
    # Parameters match vaultwarden hash --preset owasp: argon2id, m=65536 KiB, t=3, p=4, l=32
    VW_ADMIN_HASH=$(printf '%s' "$VW_ADMIN_PLAIN" | argon2 "$(openssl rand -hex 16)" -id -t 3 -m 16 -p 4 -l 32 -e 2>/dev/null)
    if printf '%s' "$VW_ADMIN_HASH" | grep -q '^\$argon2'; then
        printf "ADMIN_TOKEN='%s'\n" "$VW_ADMIN_HASH" >> "$INSTALL_DIR/vaultwarden.env"
        ok "Vaultwarden admin token set."
    else
        warn "Could not generate Argon2 hash — set ADMIN_TOKEN manually in $INSTALL_DIR/vaultwarden.env"
    fi
else
    warn "argon2 not available — set ADMIN_TOKEN manually in $INSTALL_DIR/vaultwarden.env"
fi

info "Starting services..."
docker compose up -d

# ── Bootstrap Headscale API key ───────────────────────────────────────────────

info "Waiting for Headscale to be ready..."
HS_API_KEY=""
HS_TRIES=0
# Poll the headscale unix socket via docker exec — works in both Caddy and no-Caddy mode
# since the HTTP port is only exposed to the host in the no-Caddy config.
until docker compose exec -T headscale headscale users list >/dev/null 2>&1; do
    HS_TRIES=$((HS_TRIES + 1))
    if [ "$HS_TRIES" -ge 90 ]; then
        warn "Headscale did not start within 3 minutes — VPN mesh wizard step will be unavailable."
        break
    fi
    sleep 2
done

if [ "$HS_TRIES" -lt 90 ]; then
    info "Headscale is up. Generating API key..."
    HS_API_KEY=$(docker compose exec -T headscale headscale apikeys create --expiration 9999d 2>&1 | tr -d '[:space:]')
    # Strip any non-key characters (e.g. warnings) — valid key starts with "hskey-api-"
    HS_API_KEY=$(printf '%s' "$HS_API_KEY" | grep -o 'hskey-api-[A-Za-z0-9_-]*')
    if [ -n "$HS_API_KEY" ]; then
        printf '\nHEADSCALE_API_KEY=%s\nHEADSCALE_URL=https://%s\n' "$HS_API_KEY" "$HS_DOMAIN" >> "$INSTALL_DIR/admin.env"
        ok "Headscale API key generated."
    else
        warn "Failed to generate Headscale API key — VPN mesh wizard step will be unavailable."
    fi
fi

# ── Wait for admin to be reachable ────────────────────────────────────────────

info "Waiting for lintune-admin to be ready..."
TRIES=0
until docker compose exec -T lintune-admin php artisan --version >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge 30 ]; then
        die "lintune-admin did not start within 60 seconds. Check logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs lintune-admin"
    fi
    sleep 2
done

ok "lintune-admin is up."

ok "Uptime Kuma will be configured during the web setup wizard."

# Restart lintune-admin to pick up HEADSCALE_API_KEY written to admin.env
if [ -n "$HS_API_KEY" ]; then
    info "Restarting lintune-admin to load Headscale API key..."
    docker compose restart lintune-admin
    TRIES=0
    until docker compose exec -T lintune-admin php artisan --version >/dev/null 2>&1; do
        TRIES=$((TRIES + 1))
        [ "$TRIES" -ge 20 ] && break
        sleep 2
    done
fi

# ── Done ──────────────────────────────────────────────────────────────────────

printf "\n"
bold "╔══════════════════════════════════════════════════════════╗"
bold "║  Lintune is running!                                     ║"
bold "╚══════════════════════════════════════════════════════════╝"
printf "\n"
ok "Admin panel  : ${ADMIN_URL}"
ok "Tenant dash  : ${DASH_URL}"
ok "Vault        : https://vault.${BASE_DOMAIN}  (admin at /admin — token in .env)"
ok "Status page  : https://${KUMA_DOMAIN}  (credentials set during wizard)"
ok "VPN Mesh     : https://${HS_DOMAIN}    (enable in setup wizard)"

if ! $USE_CADDY; then
    printf "\n"
    info "Ports exposed on this host:"
    info "  Admin      : 8889  ->  point your proxy to http://$(hostname -I | awk '{print $1}'):8889"
    info "  Dash       : 8888  ->  point your proxy to http://$(hostname -I | awk '{print $1}'):8888"
    info "  Headscale  : 8085  ->  point your proxy to http://$(hostname -I | awk '{print $1}'):8085"
    info "  Vault      : 8887  ->  point your proxy to http://$(hostname -I | awk '{print $1}'):8887"
fi

printf "\n"
warn "Secrets saved to: ${INSTALL_DIR}/.env  (root-readable only)"
warn "App env files  : ${INSTALL_DIR}/admin.env and ${INSTALL_DIR}/dash.env"
printf "\n"
info "Open ${ADMIN_URL} in your browser to complete the setup wizard."
info "The wizard will pre-fill service domains from base domain: ${BASE_DOMAIN}"
printf "\n"
info "  Keycloak  ->  https://auth.${BASE_DOMAIN}"
info "  Mailcow   ->  https://mail.${BASE_DOMAIN}"
info "  Nextcloud ->  https://cloud.${BASE_DOMAIN}"
printf "\n"
info "To view logs:    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
info "To stop:         docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
printf "\n"
