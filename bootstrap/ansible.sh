#!/usr/bin/env bash
# =============================================================================
# RideStatus — Ansible Controller Bootstrap
# https://github.com/RideStatus/ridestatus-deploy
#
# Called by deploy.sh (non-interactively via env vars) or manually by a tech.
#
# When called by deploy.sh, ALL configuration arrives as environment variables:
#   RS_GITHUB_AUTH      — "deploy_key" or "pat"
#   RS_GITHUB_USER      — GitHub username (PAT mode only)
#   RS_GITHUB_PAT       — GitHub PAT (PAT mode only)
#
# The only interactive step is displaying the GitHub deploy key and waiting
# for the tech to add it to GitHub. This works correctly because:
#   - deploy.sh runs this as the direct SSH command (sudo bash /tmp/script.sh)
#     with -t -t so the PTY is passed through sudo
#   - When run manually the tech already has a real terminal
#
# Usage:
#   sudo bash /path/to/ansible.sh          # called by deploy.sh
#   sudo bash ansible.sh                   # manual re-run
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[ansible.sh]${RESET} $*"; }
ok()     { echo -e "${GREEN}[ansible.sh]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[ansible.sh]${RESET} $*"; }
die()    { echo -e "${RED}[ansible.sh] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

as_rs() { runuser -l ridestatus -c "$1"; }

# Generate SSH keypair to a tmpdir first (avoids sshd session drop on inotify)
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
DEPLOY_REPO="https://github.com/RideStatus/ridestatus-deploy.git"
DEPLOY_DIR="${RS_HOME}/ridestatus-deploy"
ANSIBLE_KEY="${RS_HOME}/.ssh/ansible_ridestatus"
GITHUB_KEY="${RS_HOME}/.ssh/github_deploy"
INVENTORY_DIR="${RS_HOME}/inventory"
LOG_DIR="${RS_HOME}/logs"
KEY_SERVER_PORT=9876
KEY_SERVER_TIMEOUT=1800

# Read configuration from env vars (set by deploy.sh) or use defaults
GITHUB_AUTH="${RS_GITHUB_AUTH:-}"         # deploy_key | pat | ""
GITHUB_USER="${RS_GITHUB_USER:-}"
GITHUB_PAT="${RS_GITHUB_PAT:-}"

PRIVATE_REPOS=("git@github.com:RideStatus/ridestatus-ride.git")

# =============================================================================
# 1. System packages
# =============================================================================
header "Installing System Packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
  ansible chrony git curl jq python3 python3-pip openssh-client
pip3 install --quiet ansible-lint 2>/dev/null || true
ok "Packages installed"

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
mkdir -p "${RS_HOME}/.ssh" "${INVENTORY_DIR}" "${LOG_DIR}"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"
ok "Home directory ready: ${RS_HOME}"

# =============================================================================
# 4. Ansible SSH keypair
# =============================================================================
header "Ansible SSH Keypair"
if [[ -f "${ANSIBLE_KEY}" ]]; then
  warn "Keypair already exists — leaving intact (delete to rotate)"
else
  gen_keypair "${ANSIBLE_KEY}" "ansible@ridestatus"
  ok "Keypair generated: ${ANSIBLE_KEY}"
fi

# =============================================================================
# 5. GitHub access
# =============================================================================
header "GitHub Access for Private Repos"

GITHUB_CREDS_OK=false

# Check if already configured
if [[ -f "${GITHUB_KEY}" ]] || [[ -f "${RS_HOME}/.git-credentials" ]]; then
  info "GitHub credentials already present — skipping setup"
  GITHUB_CREDS_OK=true
fi

if [[ "$GITHUB_CREDS_OK" == "false" ]]; then

  # If deploy.sh didn't provide an auth method, ask now (manual re-run case)
  if [[ -z "$GITHUB_AUTH" ]]; then
    echo ""
    echo -e "${BOLD}GitHub access is needed so Ansible can clone private repos.${RESET}"
    echo ""
    echo "  1) Deploy key  (recommended)"
    echo "  2) Access token (PAT)"
    echo ""
    while true; do
      read -rp "$(echo -e "${BOLD}Choose [1]: ${RESET}")" _choice
      _choice="${_choice:-1}"
      [[ "$_choice" =~ ^[12]$ ]] && break
      warn "Enter 1 or 2"
    done
    [[ "$_choice" == "1" ]] && GITHUB_AUTH="deploy_key" || GITHUB_AUTH="pat"

    if [[ "$GITHUB_AUTH" == "pat" ]]; then
      read -rp "$(echo -e "${BOLD}GitHub username: ${RESET}")" GITHUB_USER
      read -rsp "$(echo -e "${BOLD}GitHub PAT: ${RESET}")" GITHUB_PAT; echo ""
    fi
  fi

  if [[ "$GITHUB_AUTH" == "deploy_key" ]]; then
    gen_keypair "${GITHUB_KEY}" "ridestatus-ansible-deploy"
    ok "GitHub deploy key generated"

    echo ""
    echo -e "${BOLD}${YELLOW}▶ ACTION REQUIRED — Add this deploy key to GitHub:${RESET}"
    echo ""
    cat "${GITHUB_KEY}.pub"
    echo ""
    echo -e "${BOLD}  Add to each repo listed below (read-only, no write access needed):${RESET}"
    for repo in "${PRIVATE_REPOS[@]}"; do
      local repo_name; repo_name=$(basename "$repo" .git)
      echo "    https://github.com/RideStatus/${repo_name}/settings/keys"
    done
    echo ""
    echo -e "${BOLD}  Steps: Settings → Deploy keys → Add deploy key → paste key → Allow write access: NO${RESET}"
    echo ""
    # This read works because deploy.sh passes the TTY through with -t -t,
    # and the script is the direct sudo bash command (not wrapped in a shell).
    read -rp "$(echo -e "${BOLD}Press Enter once the deploy key has been added to GitHub...${RESET}")"

    # Write SSH config
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

    # Test
    info "Testing deploy key access..."
    for repo in "${PRIVATE_REPOS[@]}"; do
      local repo_name; repo_name=$(basename "$repo" .git)
      if as_rs "git ls-remote '${repo}' HEAD" &>/dev/null; then
        ok "  ✓ ${repo_name}"
      else
        warn "  ✗ ${repo_name} — verify the deploy key was added correctly"
      fi
    done

  else
    # PAT — if not provided by deploy.sh, prompt now
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

      info "Testing PAT access..."
      for repo in "${PRIVATE_REPOS[@]}"; do
        local https_url="https://github.com/RideStatus/$(basename "$repo" .git).git"
        if as_rs "git ls-remote '${https_url}' HEAD" &>/dev/null; then
          ok "  ✓ $(basename "$repo" .git)"
        else
          warn "  ✗ $(basename "$repo" .git) — verify PAT scopes"
        fi
      done
    else
      warn "GitHub credentials not provided — Ansible deploys may fail"
    fi
  fi
fi

# =============================================================================
# 6. Clone ridestatus-deploy
# =============================================================================
header "Cloning ridestatus-deploy"
if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  info "Already cloned — pulling latest"
  as_rs "git -C '${DEPLOY_DIR}' pull --ff-only"
else
  as_rs "git clone '${DEPLOY_REPO}' '${DEPLOY_DIR}'"
  ok "Cloned to ${DEPLOY_DIR}"
fi

# =============================================================================
# 7. Ansible config + inventory
# =============================================================================
header "Ansible Configuration"
cat > "${DEPLOY_DIR}/ansible.cfg" << EOF
[defaults]
inventory           = ${INVENTORY_DIR}/hosts.yml
remote_user         = ridestatus
private_key_file    = ${ANSIBLE_KEY}
host_key_checking   = False
retry_files_enabled = False
stdout_callback     = yaml
log_path            = ${LOG_DIR}/ansible.log

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s
EOF
chown "${RS_USER}:${RS_USER}" "${DEPLOY_DIR}/ansible.cfg"

if [[ ! -f "${INVENTORY_DIR}/hosts.yml" ]]; then
  cat > "${INVENTORY_DIR}/hosts.yml" << 'EOF'
---
all:
  vars:
    ansible_user: ridestatus
    ansible_become: true
  children:
    servers:
      hosts: {}
    ansible_controllers:
      hosts: {}
    edge_nodes:
      hosts: {}
EOF
  chown "${RS_USER}:${RS_USER}" "${INVENTORY_DIR}/hosts.yml"
  ok "Starter inventory written"
else
  info "Inventory already exists — leaving intact"
fi
mkdir -p "${INVENTORY_DIR}/host_vars"
chown -R "${RS_USER}:${RS_USER}" "${INVENTORY_DIR}"

# =============================================================================
# 8. Systemd health-check timer
# =============================================================================
header "Systemd Health-Check Timer"
cat > /etc/systemd/system/ridestatus-healthcheck.service << EOF
[Unit]
Description=RideStatus Ansible Health Check
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=${RS_USER}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=/usr/bin/ansible-playbook ansible/playbooks/healthcheck.yml -i ${INVENTORY_DIR}/hosts.yml
StandardOutput=append:${LOG_DIR}/healthcheck.log
StandardError=append:${LOG_DIR}/healthcheck.log
EOF
cat > /etc/systemd/system/ridestatus-healthcheck.timer << 'EOF'
[Unit]
Description=RideStatus Ansible Health Check Timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable ridestatus-healthcheck.timer
systemctl start  ridestatus-healthcheck.timer
ok "Health-check timer enabled"

# =============================================================================
# 9. Vault password placeholder
# =============================================================================
if [[ ! -f "${RS_HOME}/.vault_pass" ]]; then
  echo '# Replace with vault password' > "${RS_HOME}/.vault_pass"
  chmod 600 "${RS_HOME}/.vault_pass"
  chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.vault_pass"
fi

# =============================================================================
# 10. One-shot HTTP key server
# =============================================================================
header "Starting One-Shot Ansible Key Server"

ANSIBLE_IP=$(ip -4 addr show scope global \
  | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1 || echo "<ansible-vm-ip>")

KEY_SERVER_SCRIPT=$(mktemp /tmp/ridestatus-keyserver-XXXXXX.py)
cat > "$KEY_SERVER_SCRIPT" << PYEOF
import http.server, threading
PUBKEY_FILE = "${ANSIBLE_KEY}.pub"
PORT = ${KEY_SERVER_PORT}
TIMEOUT = ${KEY_SERVER_TIMEOUT}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def do_GET(self):
        if self.path != '/ansible_ridestatus.pub':
            self.send_response(404); self.end_headers(); return
        data = open(PUBKEY_FILE,'rb').read()
        self.send_response(200)
        self.send_header('Content-Type','text/plain')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers()
        self.wfile.write(data); self.wfile.flush()
        print(f'[key-server] Fetched by {self.client_address[0]} — shutting down')
        threading.Thread(target=self.server.shutdown,daemon=True).start()
server = http.server.HTTPServer(('',PORT),Handler)
server.timeout = 1
timer = threading.Timer(TIMEOUT, lambda: (print('[key-server] Timeout — shutting down'), server.shutdown()))
timer.daemon = True; timer.start()
print(f'[key-server] Listening on port {PORT}')
try: server.serve_forever()
finally: timer.cancel()
PYEOF

python3 "$KEY_SERVER_SCRIPT" >> "${LOG_DIR}/keyserver.log" 2>&1 &
KEY_SERVER_PID=$!
echo "$KEY_SERVER_PID" > /tmp/ridestatus-keyserver.pid
sleep 1
if ! kill -0 "$KEY_SERVER_PID" 2>/dev/null; then
  warn "Key server failed to start"
else
  ok "Key server running (PID ${KEY_SERVER_PID})"
fi
trap 'kill "$KEY_SERVER_PID" 2>/dev/null || true; rm -f "$KEY_SERVER_SCRIPT" /tmp/ridestatus-keyserver.pid' EXIT

# =============================================================================
# Done
# =============================================================================
header "Ansible Bootstrap Complete"
ok "Deploy repo:  ${DEPLOY_DIR}"
ok "Inventory:    ${INVENTORY_DIR}/hosts.yml"
ok "Ansible log:  ${LOG_DIR}/ansible.log"
echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║              Ansible Key Server Ready                        ║${RESET}"
echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${YELLOW}║  http://${ANSIBLE_IP}:${KEY_SERVER_PORT}/ansible_ridestatus.pub${RESET}"
echo -e "${BOLD}${YELLOW}║  Exits after one fetch or 30 minutes.                        ║${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Run bootstrap/server.sh on the Server VM now."

wait "$KEY_SERVER_PID" 2>/dev/null || true
rm -f "$KEY_SERVER_SCRIPT" /tmp/ridestatus-keyserver.pid
ok "Key server stopped."
