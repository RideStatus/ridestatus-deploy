#!/usr/bin/env bash
# =============================================================================
# RideStatus — Server Bootstrap
# https://github.com/RideStatus/ridestatus-deploy
#
# Called by deploy.sh (non-interactively via env vars) or manually by a tech.
#
# When called by deploy.sh, ALL configuration arrives as environment variables:
#   RS_GITHUB_AUTH          — "deploy_key" or "pat"
#   RS_GITHUB_USER          — GitHub username (PAT mode only)
#   RS_GITHUB_PAT           — GitHub PAT (PAT mode only)
#   RS_ANSIBLE_KEY_URL      — URL to fetch Ansible public key from key server
#   RS_ANSIBLE_VM_HOST      — IP of Ansible Controller VM
#   RS_PARK_NAME            — Park display name
#   RS_PARK_TZ              — Park timezone (e.g. America/Chicago)
#   RS_API_KEY              — API key for edge node auth
#   RS_BOOTSTRAP_TOKEN      — Edge enrollment token (max 8 chars)
#   RS_WEATHER_API_KEY      — WeatherAPI.com key (optional)
#   RS_WEATHER_ZIP          — Weather ZIP code
#   RS_ALERT_EMAIL          — Alert email address (optional)
#   RS_ALERT_SMS            — Alert SMS address (optional)
#   RS_SMTP_HOST            — SMTP host (optional)
#   RS_SMTP_PORT            — SMTP port
#   RS_SMTP_USER            — SMTP username (optional)
#   RS_SMTP_PASS            — SMTP password (optional)
#   RS_DEFAULT_ROUTE_IFACE  — Interface name hint for default route
#
# The only interactive step is the GitHub deploy key display + "Press Enter"
# when using deploy_key mode. This works correctly because deploy.sh passes
# the TTY through (sudo bash as direct SSH command with -t -t).
#
# Usage:
#   sudo bash /path/to/server.sh           # called by deploy.sh
#   sudo bash server.sh                    # manual re-run
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[server.sh]${RESET} $*"; }
ok()     { echo -e "${GREEN}[server.sh]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[server.sh]${RESET} $*"; }
die()    { echo -e "${RED}[server.sh] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

as_rs() { runuser -l ridestatus -c "$1"; }

gen_keypair() {
  local keyfile=$1 comment=$2
  local tmp; tmp=$(mktemp -d /tmp/rs-keygen-XXXXXX)
  ssh-keygen -t ed25519 -f "${tmp}/key" -N "" -C "$comment" -q
  mv "${tmp}/key"     "$keyfile"
  mv "${tmp}/key.pub" "${keyfile}.pub"
  chmod 600 "$keyfile"; chmod 644 "${keyfile}.pub"
  chown "${RS_USER}:${RS_USER}" "$keyfile" "${keyfile}.pub"
  rm -rf "$tmp"
}

[[ $EUID -eq 0 ]] || die "Must be run as root"

RS_USER="ridestatus"
RS_HOME="/home/${RS_USER}"
SERVER_REPO="https://github.com/RideStatus/ridestatus-server.git"
SERVER_DIR="${RS_HOME}/ridestatus-server"
GITHUB_KEY="${RS_HOME}/.ssh/github_deploy"
LOG_DIR="${RS_HOME}/logs"
ANSIBLE_PUBKEY_PATH="${RS_HOME}/.ssh/ansible_ridestatus.pub"
NODE_VERSION="22"
PG_VERSION="16"

# Read from env vars (set by deploy.sh) or fall back to empty
GITHUB_AUTH="${RS_GITHUB_AUTH:-}"
GITHUB_USER="${RS_GITHUB_USER:-}"
GITHUB_PAT="${RS_GITHUB_PAT:-}"
ANSIBLE_KEY_URL="${RS_ANSIBLE_KEY_URL:-}"
PARK_NAME="${RS_PARK_NAME:-}"
PARK_TZ="${RS_PARK_TZ:-America/Chicago}"
API_KEY="${RS_API_KEY:-}"
BOOTSTRAP_TOKEN="${RS_BOOTSTRAP_TOKEN:-}"
WEATHER_API_KEY="${RS_WEATHER_API_KEY:-}"
WEATHER_ZIP="${RS_WEATHER_ZIP:-00000}"
ALERT_EMAIL="${RS_ALERT_EMAIL:-}"
ALERT_SMS="${RS_ALERT_SMS:-}"
SMTP_HOST="${RS_SMTP_HOST:-}"
SMTP_PORT="${RS_SMTP_PORT:-587}"
SMTP_USER="${RS_SMTP_USER:-}"
SMTP_PASS="${RS_SMTP_PASS:-}"
DEFAULT_ROUTE_IFACE="${RS_DEFAULT_ROUTE_IFACE:-}"

# =============================================================================
# 1. System packages
# =============================================================================
header "Installing System Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

if ! command -v node &>/dev/null || [[ "$(node --version 2>/dev/null)" != v${NODE_VERSION}* ]]; then
  info "Installing Node.js ${NODE_VERSION}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - &>/dev/null
  apt-get install -y --no-install-recommends nodejs
  ok "Node.js $(node --version) installed"
else
  info "Node.js $(node --version) already installed"
fi

if ! command -v psql &>/dev/null; then
  info "Installing PostgreSQL ${PG_VERSION}..."
  apt-get install -y --no-install-recommends \
    "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
  ok "PostgreSQL ${PG_VERSION} installed"
else
  info "PostgreSQL already installed"
fi

apt-get install -y --no-install-recommends chrony git curl jq python3 openssh-client

if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  ok "PM2 installed"
else
  info "PM2 already installed"
fi
ok "All packages installed"

# =============================================================================
# 2. Chrony
# =============================================================================
header "Configuring NTP (chrony)"
cat > /etc/chrony/chrony.conf << 'EOF'
pool pool.ntp.org iburst minpoll 6 maxpoll 10
allow 127.0.0.1
allow ::1
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF
systemctl enable chrony
systemctl restart chrony
for i in $(seq 1 6); do
  chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && break
  sleep 5
done
chronyc tracking | grep 'Leap status' || warn "chrony not yet synced"
ok "chrony configured"

# =============================================================================
# 3. ridestatus user
# =============================================================================
header "Ensuring ridestatus User"
if ! id "$RS_USER" &>/dev/null; then
  useradd -m -s /bin/bash -d "$RS_HOME" "$RS_USER"
  ok "User created"
else
  info "User already exists"
fi
mkdir -p "${RS_HOME}/.ssh" "${LOG_DIR}"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"
ok "Home directory ready"

# =============================================================================
# 4. Ansible public key
# =============================================================================
header "Ansible Public Key"
if [[ -f "$ANSIBLE_PUBKEY_PATH" ]]; then
  info "Ansible public key already installed — skipping"
else
  if [[ -z "$ANSIBLE_KEY_URL" ]]; then
    echo ""
    echo -e "${BOLD}Enter the Ansible key server URL.${RESET}"
    echo "  (Shown at end of ansible.sh output — http://<ip>:9876/ansible_ridestatus.pub)"
    echo ""
    while true; do
      read -rp "$(echo -e "${BOLD}Ansible key URL: ${RESET}")" ANSIBLE_KEY_URL
      [[ -n "$ANSIBLE_KEY_URL" ]] && break
    done
  else
    info "Fetching Ansible key from: ${ANSIBLE_KEY_URL}"
  fi

  if curl -fsSL --max-time 10 "$ANSIBLE_KEY_URL" -o "$ANSIBLE_PUBKEY_PATH" 2>/dev/null; then
    chmod 644 "$ANSIBLE_PUBKEY_PATH"
    chown "${RS_USER}:${RS_USER}" "$ANSIBLE_PUBKEY_PATH"
    ok "Ansible public key installed"
  else
    warn "Could not fetch Ansible key — install manually later"
    warn "  scp ridestatus@<ansible-ip>:~/.ssh/ansible_ridestatus.pub ${ANSIBLE_PUBKEY_PATH}"
  fi
fi

# =============================================================================
# 5. GitHub access
# =============================================================================
header "GitHub Access"
GITHUB_CREDS_OK=false
[[ -f "${GITHUB_KEY}" || -f "${RS_HOME}/.git-credentials" ]] && GITHUB_CREDS_OK=true

if [[ "$GITHUB_CREDS_OK" == "false" ]]; then

  if [[ -z "$GITHUB_AUTH" ]]; then
    echo ""
    echo "  1) Deploy key  (recommended)"
    echo "  2) Access token (PAT)"
    echo ""
    while true; do
      read -rp "$(echo -e "${BOLD}Choose [1]: ${RESET}")" _choice
      _choice="${_choice:-1}"
      [[ "$_choice" =~ ^[12]$ ]] && break
    done
    [[ "$_choice" == "1" ]] && GITHUB_AUTH="deploy_key" || GITHUB_AUTH="pat"
    if [[ "$GITHUB_AUTH" == "pat" ]]; then
      read -rp "$(echo -e "${BOLD}GitHub username: ${RESET}")" GITHUB_USER
      read -rsp "$(echo -e "${BOLD}GitHub PAT: ${RESET}")" GITHUB_PAT; echo ""
    fi
  fi

  if [[ "$GITHUB_AUTH" == "deploy_key" ]]; then
    gen_keypair "${GITHUB_KEY}" "ridestatus-server-deploy"
    ok "GitHub deploy key generated"

    echo ""
    echo -e "${BOLD}${YELLOW}▶ ACTION REQUIRED — Add this deploy key to GitHub:${RESET}"
    echo ""
    cat "${GITHUB_KEY}.pub"
    echo ""
    echo "    https://github.com/RideStatus/ridestatus-server/settings/keys"
    echo ""
    read -rp "$(echo -e "${BOLD}Press Enter once the deploy key has been added to GitHub...${RESET}")"

    SSH_CONFIG="${RS_HOME}/.ssh/config"
    if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
      cat >> "$SSH_CONFIG" << EOF

Host github.com
  HostName github.com
  User git
  IdentityFile ${GITHUB_KEY}
  StrictHostKeyChecking no
  IdentitiesOnly yes
EOF
      chmod 600 "$SSH_CONFIG"
      chown "${RS_USER}:${RS_USER}" "$SSH_CONFIG"
    fi

    SERVER_REPO="git@github.com:RideStatus/ridestatus-server.git"
    if as_rs "git ls-remote '${SERVER_REPO}' HEAD" &>/dev/null; then
      ok "ridestatus-server — access confirmed"
    else
      warn "Could not verify deploy key — check it was added correctly"
    fi

  else
    if [[ -z "$GITHUB_USER" ]]; then
      read -rp "$(echo -e "${BOLD}GitHub username: ${RESET}")" GITHUB_USER
    fi
    if [[ -z "$GITHUB_PAT" ]]; then
      read -rsp "$(echo -e "${BOLD}GitHub PAT: ${RESET}")" GITHUB_PAT; echo ""
    fi

    if [[ -n "$GITHUB_USER" && -n "$GITHUB_PAT" ]]; then
      as_rs "git config --global credential.helper store"
      echo "https://${GITHUB_USER}:${GITHUB_PAT}@github.com" > "${RS_HOME}/.git-credentials"
      chmod 600 "${RS_HOME}/.git-credentials"
      chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.git-credentials"
      ok "PAT credentials stored"
    fi
  fi
fi

# =============================================================================
# 6. Clone ridestatus-server
# =============================================================================
header "Cloning ridestatus-server"
if [[ -d "${SERVER_DIR}/.git" ]]; then
  info "Already cloned — pulling latest"
  as_rs "git -C '${SERVER_DIR}' pull --ff-only"
else
  as_rs "git clone '${SERVER_REPO}' '${SERVER_DIR}'"
  ok "Cloned to ${SERVER_DIR}"
fi

# =============================================================================
# 7. PostgreSQL
# =============================================================================
header "PostgreSQL Setup"
systemctl enable postgresql
systemctl start postgresql

DB_NAME="ridestatus"
DB_USER="ridestatus"

if [[ ! -f "${RS_HOME}/.pgpass_ridestatus" ]]; then
  DB_PASS=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))")
  echo "$DB_PASS" > "${RS_HOME}/.pgpass_ridestatus"
  chmod 600 "${RS_HOME}/.pgpass_ridestatus"
  chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.pgpass_ridestatus"
else
  DB_PASS=$(cat "${RS_HOME}/.pgpass_ridestatus")
  info "Using existing DB password"
fi

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
  | grep -q 1 2>/dev/null || \
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
  | grep -q 1 2>/dev/null || \
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"

sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" &>/dev/null
ok "PostgreSQL ready: ${DB_NAME}"

# =============================================================================
# 8. .env configuration
# =============================================================================
header "Server Configuration"
ENV_FILE="${SERVER_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — leaving intact (delete to reconfigure)"
else
  # If not provided by deploy.sh, prompt for essentials
  if [[ -z "$PARK_NAME" ]]; then
    read -rp "$(echo -e "${BOLD}Park name: ${RESET}")" PARK_NAME
    [[ -z "$PARK_NAME" ]] && PARK_NAME="My Park"
  fi
  if [[ -z "$API_KEY" ]]; then
    API_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    info "Generated API key: ${API_KEY}"
  fi
  if [[ -z "$BOOTSTRAP_TOKEN" ]]; then
    BOOTSTRAP_TOKEN=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(8)))")
    info "Generated bootstrap token: ${BOOTSTRAP_TOKEN}"
  fi
  BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:0:8}"

  # Detect default route interface
  local detected_iface
  detected_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1 || true)
  if [[ -z "$DEFAULT_ROUTE_IFACE" || "$DEFAULT_ROUTE_IFACE" == net* ]]; then
    DEFAULT_ROUTE_IFACE="${detected_iface:-ens18}"
  fi

  timedatectl set-timezone "$PARK_TZ" 2>/dev/null || warn "Could not set timezone"

  cat > "$ENV_FILE" << EOF
# =============================================================================
# RideStatus Server — Environment Variables
# Generated $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

PARK_NAME=${PARK_NAME}
PARK_TIMEZONE=${PARK_TZ}

POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASS=${DB_PASS}

API_PORT=3100
API_KEY=${API_KEY}
SERVER_BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}

DEFAULT_ROUTE_INTERFACE=${DEFAULT_ROUTE_IFACE}
ANSIBLE_PUBKEY_PATH=${ANSIBLE_PUBKEY_PATH}

WEATHER_API_KEY=${WEATHER_API_KEY}
WEATHER_ZIP=${WEATHER_ZIP}
WEATHER_POLL_INTERVAL_S=60

ALERT_EMAIL=${ALERT_EMAIL}
ALERT_SMS=${ALERT_SMS}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}

OFFLINE_TIMEOUT_S=300
RTC_DRIFT_WARN_S=900
LOG_LEVEL=info
LOG_FILE=logs/server.log
EOF
  chmod 600 "$ENV_FILE"
  chown "${RS_USER}:${RS_USER}" "$ENV_FILE"
  ok ".env written"
fi

# =============================================================================
# 9. npm install + migrations
# =============================================================================
header "Installing Dependencies"
as_rs "cd '${SERVER_DIR}' && npm install --omit=dev --silent"
ok "npm install complete"

header "Running Database Migrations"
as_rs "cd '${SERVER_DIR}' && \
  POSTGRES_HOST=localhost POSTGRES_PORT=5432 \
  POSTGRES_DB=${DB_NAME} POSTGRES_USER=${DB_USER} POSTGRES_PASS=${DB_PASS} \
  node db/migrate.js"
ok "Migrations complete"

# =============================================================================
# 10. PM2
# =============================================================================
header "Starting RideStatus Server (PM2)"
mkdir -p "${LOG_DIR}"
chown "${RS_USER}:${RS_USER}" "${LOG_DIR}"

cp "${SERVER_DIR}/ecosystem.config.js" "${RS_HOME}/ecosystem.config.js"
chown "${RS_USER}:${RS_USER}" "${RS_HOME}/ecosystem.config.js"

if as_rs "pm2 describe ridestatus-server" &>/dev/null; then
  as_rs "pm2 reload ridestatus-server --update-env"
else
  as_rs "pm2 start '${RS_HOME}/ecosystem.config.js'"
fi
as_rs "pm2 save"

PM2_CMD=$(as_rs "pm2 startup systemd -u ${RS_USER} --hp ${RS_HOME}" 2>/dev/null \
  | grep -o 'sudo env PATH.*' || true)
[[ -n "$PM2_CMD" ]] && eval "$PM2_CMD" || \
  pm2 startup systemd -u "$RS_USER" --hp "$RS_HOME" 2>/dev/null || true

systemctl enable "pm2-${RS_USER}" 2>/dev/null || true
ok "PM2 startup configured"

# =============================================================================
# Done
# =============================================================================
header "Server Bootstrap Complete"
SERVER_IP=$(ip -4 addr show scope global \
  | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1 || echo "<server-ip>")

ok "ridestatus-server: ${SERVER_DIR}"
ok "PostgreSQL:        ${DB_NAME}@localhost"
ok "PM2:               ridestatus-server"
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  Management UI:  http://${SERVER_IP}:3100/manage${RESET}"
echo -e "${BOLD}${GREEN}║  Status board:   http://${SERVER_IP}:3100${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "Verify: ${BOLD}pm2 list${RESET}  |  ${BOLD}pm2 logs ridestatus-server --lines 20${RESET}"
echo ""
