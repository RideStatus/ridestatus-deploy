#!/usr/bin/env bash
# =============================================================================
# RideStatus — Server Bootstrap
# https://github.com/RideStatus/ridestatus-deploy
#
# Run inside the RideStatus Server VM after creation by deploy.sh.
# Can also be run manually to re-bootstrap or repair an existing install.
#
# What this script does:
#   1.  Installs system packages (Node.js 22, PostgreSQL 16, PM2, git, chrony)
#   2.  Configures chrony for NTP sync
#   3.  Ensures the 'ridestatus' OS user exists
#   4.  Fetches the Ansible public key from the Ansible Controller VM
#   5.  Configures GitHub access to clone ridestatus-server (deploy key or PAT)
#   6.  Clones ridestatus-server to /home/ridestatus/ridestatus-server
#   7.  Creates PostgreSQL database and user
#   8.  Prompts for .env configuration (park name, timezone, API keys, etc.)
#   9.  Runs npm install and database migrations
#   10. Starts rs-server via PM2 and configures PM2 startup on boot
#
# Environment variables (passed by deploy.sh on single-host deployments):
#   ANSIBLE_KEY_URL           — URL to fetch the Ansible public key from
#   ANSIBLE_VM_HOST           — IP of the Ansible Controller VM
#   RS_DEFAULT_ROUTE_NIC_HINT — vNIC index hint for DEFAULT_ROUTE_INTERFACE
#
# Interactive input:
#   The script re-opens stdin from /dev/tty at startup so all prompts work
#   correctly under sudo (which closes the controlling terminal). If /dev/tty
#   is unavailable the script falls back to the original stdin.
#
# Usage (called by deploy.sh via SSH, or manually):
#   sudo bash /path/to/server.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[server.sh]${RESET} $*"; }
ok()     { echo -e "${GREEN}[server.sh]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[server.sh]${RESET} $*"; }
die()    { echo -e "${RED}[server.sh] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# Re-open stdin from /dev/tty so interactive prompts work under sudo.
# sudo closes the controlling terminal; this re-attaches it.
if [[ -c /dev/tty ]]; then
  exec </dev/tty
fi

# Run a command as the ridestatus user with a proper login environment.
as_rs() { runuser -l ridestatus -c "$1"; }

# Generate an SSH keypair safely without disturbing the active SSH session.
# Keys are generated to a tmpdir OUTSIDE ~/.ssh/ then moved in atomically.
gen_keypair() {
  local keyfile=$1 comment=$2
  local tmpdir
  tmpdir=$(mktemp -d /tmp/ridestatus-keygen-XXXXXX)
  local tmpkey="${tmpdir}/key"
  ssh-keygen -t ed25519 -f "$tmpkey" -N "" -C "$comment" -q
  mv "${tmpkey}"     "$keyfile"
  mv "${tmpkey}.pub" "${keyfile}.pub"
  chmod 600 "$keyfile"
  chmod 644 "${keyfile}.pub"
  chown "${RS_USER}:${RS_USER}" "$keyfile" "${keyfile}.pub"
  rm -rf "$tmpdir"
}

# Simple prompt helpers — stdin is already /dev/tty from exec above.
prompt() {
  local -n _p_var=$1; local msg=$2; local def=${3:-}
  if [[ -n "$def" ]]; then
    read -rp "$(echo -e "${BOLD}${msg}${RESET} [${def}]: ")" _p_var
    [[ -z "$_p_var" ]] && _p_var="$def"
  else
    read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" _p_var
  fi
}

prompt_secret() {
  local -n _ps_var=$1; local msg=$2
  read -rsp "$(echo -e "${BOLD}${msg}${RESET}: ")" _ps_var
  echo ""
}

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo bash server.sh)"

RS_USER="ridestatus"
RS_HOME="/home/${RS_USER}"
SERVER_REPO="https://github.com/RideStatus/ridestatus-server.git"
SERVER_DIR="${RS_HOME}/ridestatus-server"
GITHUB_KEY="${RS_HOME}/.ssh/github_deploy"
LOG_DIR="${RS_HOME}/logs"
ANSIBLE_PUBKEY_PATH="${RS_HOME}/.ssh/ansible_ridestatus.pub"
ANSIBLE_KEY_URL="${ANSIBLE_KEY_URL:-}"
ANSIBLE_VM_HOST="${ANSIBLE_VM_HOST:-}"
RS_DEFAULT_ROUTE_NIC_HINT="${RS_DEFAULT_ROUTE_NIC_HINT:-}"
NODE_VERSION="22"
PG_VERSION="16"

# =============================================================================
# 1. System packages
# =============================================================================
header "Installing System Packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# Node.js 22
if ! command -v node &>/dev/null || [[ "$(node --version 2>/dev/null)" != v${NODE_VERSION}* ]]; then
  info "Installing Node.js ${NODE_VERSION}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - &>/dev/null
  apt-get install -y --no-install-recommends nodejs
  ok "Node.js $(node --version) installed"
else
  info "Node.js $(node --version) already installed"
fi

# PostgreSQL 16
if ! command -v psql &>/dev/null; then
  info "Installing PostgreSQL ${PG_VERSION}..."
  apt-get install -y --no-install-recommends \
    "postgresql-${PG_VERSION}" \
    "postgresql-client-${PG_VERSION}"
  ok "PostgreSQL ${PG_VERSION} installed"
else
  info "PostgreSQL already installed"
fi

# Other packages
apt-get install -y --no-install-recommends \
  chrony \
  git \
  curl \
  jq \
  python3 \
  openssh-client

# PM2 — install globally as root, available system-wide
if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  ok "PM2 installed"
else
  info "PM2 already installed"
fi

ok "All packages installed"

# =============================================================================
# 2. Chrony — NTP sync
# =============================================================================
header "Configuring NTP (chrony)"

cat > /etc/chrony/chrony.conf << 'EOF'
# RideStatus Server — chrony config
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
chronyc tracking | grep 'Leap status' || warn "chrony not yet synced — may need internet route"

ok "chrony configured"

# =============================================================================
# 3. ridestatus OS user
# =============================================================================
header "Ensuring ridestatus User"

if ! id "$RS_USER" &>/dev/null; then
  useradd -m -s /bin/bash -d "$RS_HOME" "$RS_USER"
  ok "User ${RS_USER} created"
else
  info "User ${RS_USER} already exists"
fi

mkdir -p "${RS_HOME}/.ssh" "${LOG_DIR}"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"

ok "Home directory ready: ${RS_HOME}"

# =============================================================================
# 4. Ansible public key install
# =============================================================================
header "Ansible Public Key"

if [[ -f "$ANSIBLE_PUBKEY_PATH" ]]; then
  info "Ansible public key already installed at ${ANSIBLE_PUBKEY_PATH} — skipping"
else
  if [[ -z "$ANSIBLE_KEY_URL" ]]; then
    echo ""
    echo -e "${BOLD}The Ansible Controller VM hosts a one-shot key server.${RESET}"
    echo "  It prints a URL when ansible.sh completes — something like:"
    echo "  http://10.x.x.x:9876/ansible_ridestatus.pub"
    echo ""
    while true; do
      prompt ANSIBLE_KEY_URL "Ansible key server URL"
      [[ -n "$ANSIBLE_KEY_URL" ]] && break
      warn "URL is required."
    done
  else
    info "Using Ansible key URL from deploy.sh: ${ANSIBLE_KEY_URL}"
  fi

  info "Fetching Ansible public key from ${ANSIBLE_KEY_URL}..."
  if curl -fsSL --max-time 10 "$ANSIBLE_KEY_URL" -o "$ANSIBLE_PUBKEY_PATH" 2>/dev/null; then
    chmod 644 "$ANSIBLE_PUBKEY_PATH"
    chown "${RS_USER}:${RS_USER}" "$ANSIBLE_PUBKEY_PATH"
    ok "Ansible public key installed at ${ANSIBLE_PUBKEY_PATH}"
  else
    warn "Could not fetch Ansible public key from ${ANSIBLE_KEY_URL}"
    warn "The key server may have timed out or the Ansible VM is unreachable."
    warn "Install manually later:"
    warn "  scp ridestatus@<ansible-ip>:~/.ssh/ansible_ridestatus.pub ${ANSIBLE_PUBKEY_PATH}"
    warn "  Then update ANSIBLE_PUBKEY_PATH in ${SERVER_DIR}/.env"
  fi
fi

# =============================================================================
# 5. GitHub access — clone ridestatus-server
# =============================================================================
header "GitHub Access"

GITHUB_CREDS_CONFIGURED=false

if [[ -f "${GITHUB_KEY}" ]]; then
  info "GitHub deploy key already present — skipping setup"
  GITHUB_CREDS_CONFIGURED=true
elif [[ -f "${RS_HOME}/.git-credentials" ]]; then
  info "GitHub PAT credentials already present — skipping setup"
  GITHUB_CREDS_CONFIGURED=true
fi

if [[ "$GITHUB_CREDS_CONFIGURED" == "false" ]]; then
  echo ""
  echo -e "${BOLD}GitHub access is needed to clone ridestatus-server.${RESET}"
  echo ""
  echo "  1) Deploy key  (recommended — SSH key scoped to ridestatus-server)"
  echo "  2) Access token (PAT — simpler, enter once, done)"
  echo ""

  GITHUB_AUTH_METHOD=""
  while true; do
    prompt GITHUB_AUTH_METHOD "Choose" "1"
    [[ "$GITHUB_AUTH_METHOD" =~ ^[12]$ ]] && break
    warn "Enter 1 or 2."
  done

  if [[ "$GITHUB_AUTH_METHOD" == "1" ]]; then
    # Deploy key — generate via tmpdir to avoid sshd session drop
    if [[ ! -f "${GITHUB_KEY}" ]]; then
      gen_keypair "${GITHUB_KEY}" "ridestatus-server-deploy"
      ok "GitHub deploy key generated: ${GITHUB_KEY}"
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}Action required — add this deploy key to ridestatus-server in GitHub:${RESET}"
    echo ""
    echo -e "${BOLD}  Public key to add:${RESET}"
    echo ""
    cat "${GITHUB_KEY}.pub"
    echo ""
    echo -e "${BOLD}  Add it here:${RESET}"
    echo "    https://github.com/RideStatus/ridestatus-server/settings/keys"
    echo ""
    echo -e "${BOLD}  Steps: Settings → Deploy keys → Add deploy key → paste → Allow write access: NO${RESET}"
    echo ""
    _enter=""
    read -rp "$(echo -e "${BOLD}Press Enter once you have added the deploy key to GitHub...${RESET}")" _enter

    # Configure SSH for github.com
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

    info "Testing deploy key access..."
    if as_rs "git ls-remote '${SERVER_REPO}' HEAD" &>/dev/null; then
      ok "ridestatus-server — access confirmed"
    else
      warn "Could not verify deploy key access — check the key was added correctly"
    fi

  else
    # PAT
    echo ""
    echo -e "${BOLD}Create a PAT at: https://github.com/settings/tokens${RESET}"
    echo "  Token type: Classic"
    echo "  Scopes needed: repo (read-only is sufficient)"
    echo ""
    prompt GITHUB_USER "GitHub username"
    prompt_secret GITHUB_PAT "GitHub PAT (input hidden)"

    if [[ -n "$GITHUB_USER" && -n "$GITHUB_PAT" ]]; then
      as_rs "git config --global credential.helper store"
      echo "https://${GITHUB_USER}:${GITHUB_PAT}@github.com" \
        > "${RS_HOME}/.git-credentials"
      chmod 600 "${RS_HOME}/.git-credentials"
      chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.git-credentials"

      if as_rs "git ls-remote '${SERVER_REPO}' HEAD" &>/dev/null; then
        ok "ridestatus-server — access confirmed"
      else
        warn "Could not verify PAT access — check PAT scopes"
      fi
    else
      warn "Username or PAT empty — skipping. Re-run server.sh to configure."
    fi
  fi
fi

# =============================================================================
# 6. Clone ridestatus-server
# =============================================================================
header "Cloning ridestatus-server"

if [[ -d "${SERVER_DIR}/.git" ]]; then
  info "Repo already cloned — pulling latest"
  as_rs "git -C '${SERVER_DIR}' pull --ff-only"
else
  as_rs "git clone '${SERVER_REPO}' '${SERVER_DIR}'"
  ok "Repo cloned to ${SERVER_DIR}"
fi

# =============================================================================
# 7. PostgreSQL — create database and user
# =============================================================================
header "PostgreSQL Setup"

systemctl enable postgresql
systemctl start postgresql

DB_NAME="ridestatus"
DB_USER="ridestatus"

if [[ ! -f "${RS_HOME}/.pgpass_ridestatus" ]]; then
  DB_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32)))")
  echo "$DB_PASS" > "${RS_HOME}/.pgpass_ridestatus"
  chmod 600 "${RS_HOME}/.pgpass_ridestatus"
  chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.pgpass_ridestatus"
else
  DB_PASS=$(cat "${RS_HOME}/.pgpass_ridestatus")
  info "Using existing PostgreSQL password"
fi

# Create user if not exists
if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
    | grep -q 1 2>/dev/null; then
  sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
fi

# Create database if not exists
if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
    | grep -q 1 2>/dev/null; then
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
fi

# Ensure password is current (idempotent)
sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" &>/dev/null

ok "PostgreSQL database '${DB_NAME}' and user '${DB_USER}' ready"

# =============================================================================
# 8. .env configuration
# =============================================================================
header "Server Configuration"

ENV_FILE="${SERVER_DIR}/.env"

DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1 || true)

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists at ${ENV_FILE} — leaving intact"
  warn "To reconfigure: rm ${ENV_FILE} && server.sh"
else
  echo ""
  echo -e "${BOLD}Park Configuration${RESET}"
  echo "  These values are written to .env and can be changed later."
  echo ""

  prompt PARK_NAME "Park name"
  [[ -z "$PARK_NAME" ]] && PARK_NAME="My Park"

  echo ""
  echo "  Common timezones: America/Chicago  America/New_York  America/Los_Angeles"
  echo "                    America/Denver   Europe/London     Australia/Sydney"
  prompt PARK_TZ "Timezone" "America/Chicago"

  timedatectl set-timezone "$PARK_TZ" 2>/dev/null \
    || warn "Could not set system timezone to ${PARK_TZ}"

  echo ""
  prompt API_KEY "API key for edge node authentication (Enter to generate)"
  if [[ -z "$API_KEY" ]]; then
    API_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    ok "Generated API key: ${API_KEY}"
  fi

  echo ""
  prompt BOOTSTRAP_TOKEN "Bootstrap token for edge enrollment (max 8 chars, Enter to generate)"
  if [[ -z "$BOOTSTRAP_TOKEN" ]]; then
    BOOTSTRAP_TOKEN=$(python3 -c "import secrets, string; \
      print(''.join(secrets.choice(string.ascii_uppercase + string.digits) for _ in range(8)))")
    ok "Generated bootstrap token: ${BOOTSTRAP_TOKEN}"
  fi
  BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:0:8}"

  echo ""
  prompt WEATHER_API_KEY "WeatherAPI.com API key (Enter to skip)"
  prompt WEATHER_ZIP "Weather ZIP code" "00000"

  echo ""
  echo -e "${BOLD}SMTP alert settings (Enter to skip each):${RESET}"
  prompt ALERT_EMAIL "  Alert email address"
  prompt ALERT_SMS "  Alert SMS address"
  prompt SMTP_HOST "  SMTP host"
  prompt SMTP_PORT "  SMTP port" "587"
  prompt SMTP_USER "  SMTP username"
  prompt_secret SMTP_PASS "  SMTP password (hidden)"

  cat > "$ENV_FILE" << EOF
# =============================================================================
# RideStatus Server — Environment Variables
# Generated by server.sh on $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# Park identity
PARK_NAME=${PARK_NAME}
PARK_TIMEZONE=${PARK_TZ}

# PostgreSQL
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASS=${DB_PASS}

# API
API_PORT=3100
API_KEY=${API_KEY}

# Bootstrap token — shown in admin UI, max 8 chars
SERVER_BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}

# Network interfaces
# RideStatus services listen on all interfaces.
# DEFAULT_ROUTE_INTERFACE is used for outbound internet traffic
# (software updates, SMTP alerts, weather data).
DEFAULT_ROUTE_INTERFACE=${DEFAULT_IFACE:-ens18}

# Ansible SSH public key path
ANSIBLE_PUBKEY_PATH=${ANSIBLE_PUBKEY_PATH}

# Weather
WEATHER_API_KEY=${WEATHER_API_KEY:-}
WEATHER_ZIP=${WEATHER_ZIP}
WEATHER_POLL_INTERVAL_S=60

# Alerting
ALERT_EMAIL=${ALERT_EMAIL:-}
ALERT_SMS=${ALERT_SMS:-}
SMTP_HOST=${SMTP_HOST:-}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER:-}
SMTP_PASS=${SMTP_PASS:-}

# Thresholds
OFFLINE_TIMEOUT_S=300
RTC_DRIFT_WARN_S=900

# Logging
LOG_LEVEL=info
LOG_FILE=logs/server.log
EOF

  chmod 600 "$ENV_FILE"
  chown "${RS_USER}:${RS_USER}" "$ENV_FILE"
  ok ".env written to ${ENV_FILE}"
fi

# =============================================================================
# 9. npm install and database migration
# =============================================================================
header "Installing Dependencies"

as_rs "cd '${SERVER_DIR}' && npm install --omit=dev --silent"
ok "npm install complete"

header "Running Database Migrations"

as_rs "cd '${SERVER_DIR}' && \
  POSTGRES_HOST=localhost \
  POSTGRES_PORT=5432 \
  POSTGRES_DB=${DB_NAME} \
  POSTGRES_USER=${DB_USER} \
  POSTGRES_PASS=${DB_PASS} \
  node db/migrate.js"

ok "Database migrations complete"

# =============================================================================
# 10. PM2 — start rs-server and configure boot startup
# =============================================================================
header "Starting RideStatus Server (PM2)"

mkdir -p "${LOG_DIR}"
chown "${RS_USER}:${RS_USER}" "${LOG_DIR}"

ECOSYSTEM_SRC="${SERVER_DIR}/ecosystem.config.js"
ECOSYSTEM_DEST="${RS_HOME}/ecosystem.config.js"
cp "$ECOSYSTEM_SRC" "$ECOSYSTEM_DEST"
chown "${RS_USER}:${RS_USER}" "$ECOSYSTEM_DEST"

if as_rs "pm2 describe ridestatus-server" &>/dev/null; then
  info "PM2 process already exists — reloading"
  as_rs "pm2 reload ridestatus-server --update-env"
else
  as_rs "pm2 start '${ECOSYSTEM_DEST}'"
fi

as_rs "pm2 save"

PM2_STARTUP_CMD=$(as_rs "pm2 startup systemd -u ${RS_USER} --hp ${RS_HOME}" 2>/dev/null \
  | grep -o 'sudo env PATH.*' || true)

if [[ -n "$PM2_STARTUP_CMD" ]]; then
  eval "$PM2_STARTUP_CMD"
else
  pm2 startup systemd -u "$RS_USER" --hp "$RS_HOME" 2>/dev/null || true
fi

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
ok "PM2 process:       ridestatus-server"
ok "Logs:              ${LOG_DIR}/"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║           RideStatus Server Ready                            ║${RESET}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  Management UI:                                              ║${RESET}"
echo -e "${BOLD}${CYAN}║  http://${SERVER_IP}:3100/manage${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  Status board:                                               ║${RESET}"
echo -e "${BOLD}${CYAN}║  http://${SERVER_IP}:3100${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Verify with:${RESET}"
echo "  pm2 list"
echo "  pm2 logs ridestatus-server --lines 20"
echo ""
echo -e "${BOLD}${YELLOW}*** IMPORTANT: Copy your admin SSH private key off this Proxmox host ***${RESET}"
echo "  The key is at /root/ridestatus-admin-key on PVE-SCADA2"
echo "  Use WinSCP or similar to download it to your PC"
echo ""
