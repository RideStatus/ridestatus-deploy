#!/usr/bin/env bash
# =============================================================================
# RideStatus — Ansible Controller Bootstrap
# https://github.com/RideStatus/ridestatus-deploy
#
# Run inside the Ansible Controller VM after creation by deploy.sh.
# Can also be run manually to re-bootstrap or repair an existing install.
#
# What this script does:
#   1. Installs system packages (Ansible, chrony, git, curl, jq)
#   2. Configures chrony to sync from internet NTP pool (stratum 2,
#      independent of the RideStatus Server VM)
#   3. Ensures the 'ridestatus' OS user exists with correct home/permissions
#   4. Generates the Ansible SSH keypair used to manage all nodes
#      (/home/ridestatus/.ssh/ansible_ridestatus)
#   5. Clones ridestatus-deploy repo to /home/ridestatus/ridestatus-deploy
#   6. Writes a starter Ansible inventory
#   7. Installs a systemd timer for the health-check playbook (every 5 min)
#   8. Starts a one-shot HTTP key server on port 9876 (dept NIC) so that
#      server.sh can fetch the Ansible public key automatically — no
#      copy-paste required, even across two physical hosts.
#      The server exits after one successful fetch or after 10 minutes.
#
# Usage (called by deploy.sh via SSH, or manually):
#   curl -fsSL https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/ansible.sh | sudo bash
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[ansible.sh]${RESET} $*"; }
ok()     { echo -e "${GREEN}[ansible.sh]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[ansible.sh]${RESET} $*"; }
die()    { echo -e "${RED}[ansible.sh] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo bash ansible.sh)"

RS_USER="ridestatus"
RS_HOME="/home/${RS_USER}"
DEPLOY_REPO="https://github.com/RideStatus/ridestatus-deploy.git"
DEPLOY_DIR="${RS_HOME}/ridestatus-deploy"
ANSIBLE_KEY="${RS_HOME}/.ssh/ansible_ridestatus"
INVENTORY_DIR="${RS_HOME}/inventory"
LOG_DIR="${RS_HOME}/logs"
KEY_SERVER_PORT=9876
KEY_SERVER_TIMEOUT=600  # 10 minutes

# =============================================================================
# 1. System packages
# =============================================================================
header "Installing System Packages"

apt-get update -qq
apt-get install -y --no-install-recommends \
  ansible \
  chrony \
  git \
  curl \
  jq \
  python3 \
  python3-pip \
  openssh-client

pip3 install --quiet ansible-lint 2>/dev/null || true

ok "Packages installed"

# =============================================================================
# 2. Chrony — sync from internet NTP pool (stratum 2, independent)
# =============================================================================
header "Configuring NTP (chrony)"

cat > /etc/chrony/chrony.conf << 'EOF'
# RideStatus Ansible Controller — chrony config
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

mkdir -p "${RS_HOME}/.ssh" "${INVENTORY_DIR}" "${LOG_DIR}"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"

ok "Home directory ready: ${RS_HOME}"

# =============================================================================
# 4. Ansible SSH keypair
# Generated once — never rotated automatically.
# To rotate: rm the key files and re-run.
# =============================================================================
header "Ansible SSH Keypair"

if [[ -f "${ANSIBLE_KEY}" ]]; then
  warn "Ansible keypair already exists at ${ANSIBLE_KEY} — leaving intact"
  warn "To rotate: rm ${ANSIBLE_KEY} ${ANSIBLE_KEY}.pub and re-run"
else
  sudo -u "$RS_USER" ssh-keygen \
    -t ed25519 -f "${ANSIBLE_KEY}" -N "" -C "ansible@ridestatus" -q
  chmod 600 "${ANSIBLE_KEY}"
  chmod 644 "${ANSIBLE_KEY}.pub"
  ok "Keypair generated: ${ANSIBLE_KEY}"
fi

# =============================================================================
# 5. Clone ridestatus-deploy repo
# =============================================================================
header "Cloning ridestatus-deploy"

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  info "Repo already cloned — pulling latest"
  sudo -u "$RS_USER" git -C "$DEPLOY_DIR" pull --ff-only
else
  sudo -u "$RS_USER" git clone "$DEPLOY_REPO" "$DEPLOY_DIR"
  ok "Repo cloned to ${DEPLOY_DIR}"
fi

# =============================================================================
# 6. Ansible configuration and starter inventory
# =============================================================================
header "Ansible Configuration"

cat > "${DEPLOY_DIR}/ansible.cfg" << EOF
[defaults]
inventory          = ${INVENTORY_DIR}/hosts.yml
remote_user        = ridestatus
private_key_file   = ${ANSIBLE_KEY}
host_key_checking  = False
retry_files_enabled = False
stdout_callback    = yaml
callback_whitelist = timer, profile_tasks
log_path           = ${LOG_DIR}/ansible.log

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s
EOF
chown "${RS_USER}:${RS_USER}" "${DEPLOY_DIR}/ansible.cfg"

if [[ ! -f "${INVENTORY_DIR}/hosts.yml" ]]; then
  cat > "${INVENTORY_DIR}/hosts.yml" << 'EOF'
---
# RideStatus Ansible Inventory
# Managed by bootstrap scripts and the RideStatus server admin UI.
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
      # Goliath:
      #   ansible_host: 10.15.140.17
      #   ride_nic_ip: 192.168.1.254
      #   plc_ip: 192.168.1.2
      #   plc_protocol: enip
EOF
  chown "${RS_USER}:${RS_USER}" "${INVENTORY_DIR}/hosts.yml"
  ok "Starter inventory written"
else
  info "Inventory already exists — leaving intact"
fi

# =============================================================================
# 7. Systemd timer — health-check playbook every 5 minutes
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
ExecStart=/usr/bin/ansible-playbook ansible/playbooks/healthcheck.yml \\
  -i ${INVENTORY_DIR}/hosts.yml
StandardOutput=append:${LOG_DIR}/healthcheck.log
StandardError=append:${LOG_DIR}/healthcheck.log
EOF

cat > /etc/systemd/system/ridestatus-healthcheck.timer << 'EOF'
[Unit]
Description=RideStatus Ansible Health Check Timer
After=network-online.target

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

ok "Health-check timer enabled (every 5 minutes)"

# =============================================================================
# 8. Ansible vault password placeholder
# =============================================================================
if [[ ! -f "${RS_HOME}/.vault_pass" ]]; then
  echo '# Replace with vault password, then: chmod 600 ~/.vault_pass' \
    > "${RS_HOME}/.vault_pass"
  chmod 600 "${RS_HOME}/.vault_pass"
  chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.vault_pass"
  warn "Set vault password in ${RS_HOME}/.vault_pass before using ansible-vault"
fi

# =============================================================================
# 9. One-shot HTTP key server
#
# Serves only ansible_ridestatus.pub on port KEY_SERVER_PORT.
# Exits after the first successful GET request, or after KEY_SERVER_TIMEOUT
# seconds, whichever comes first.
#
# server.sh (on any host reachable via the dept network) can fetch the key
# automatically with:
#   curl -fsSL http://<ansible-dept-ip>:9876/ansible_ridestatus.pub
#
# The server binds to all interfaces so it's reachable whether the tech
# connects via the dept NIC or the external NIC.
# Security: only the public key is served; the private key is never exposed.
# The server stops itself after one fetch, limiting the exposure window.
# =============================================================================
header "Starting One-Shot Ansible Key Server"

ANSIBLE_PUBKEY_CONTENT=$(cat "${ANSIBLE_KEY}.pub")

# Determine the dept-network IP to display to the tech.
# We look for the first non-loopback, non-link-local IPv4.
ANSIBLE_IP=$(ip -4 addr show scope global \
  | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1 || echo "<ansible-vm-ip>")

# Write the one-shot server script to a temp file so we can run it in the
# background without relying on heredoc process substitution.
KEY_SERVER_SCRIPT=$(mktemp /tmp/ridestatus-keyserver-XXXXXX.py)
cat > "$KEY_SERVER_SCRIPT" << PYEOF
import http.server
import os
import signal
import threading

PUBKEY_FILE = "${ANSIBLE_KEY}.pub"
PORT        = ${KEY_SERVER_PORT}
TIMEOUT     = ${KEY_SERVER_TIMEOUT}

class OneShotHandler(http.server.BaseHTTPRequestHandler):
    served = False

    def log_message(self, fmt, *args):
        # Suppress default access log noise — we print our own
        pass

    def do_GET(self):
        if self.path != '/ansible_ridestatus.pub':
            self.send_response(404)
            self.end_headers()
            return

        with open(PUBKEY_FILE, 'rb') as f:
            data = f.read()

        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

        print(f'[key-server] Key fetched by {self.client_address[0]} — shutting down')
        # Shut down in a thread so we can return the response first
        threading.Thread(target=self.server.shutdown, daemon=True).start()

server = http.server.HTTPServer(('', PORT), OneShotHandler)
server.timeout = 1

# Auto-shutdown after TIMEOUT seconds even if nobody fetches the key
def auto_shutdown():
    print(f'[key-server] Timeout reached ({TIMEOUT}s) — shutting down')
    server.shutdown()

timer = threading.Timer(TIMEOUT, auto_shutdown)
timer.daemon = True
timer.start()

print(f'[key-server] Listening on port {PORT}')
try:
    server.serve_forever()
finally:
    timer.cancel()
PYEOF

# Start the key server in the background, owned by root (reads key as root)
python3 "$KEY_SERVER_SCRIPT" >> "${LOG_DIR}/keyserver.log" 2>&1 &
KEY_SERVER_PID=$!
echo "$KEY_SERVER_PID" > /tmp/ridestatus-keyserver.pid

# Give it a moment to bind
sleep 1
if ! kill -0 "$KEY_SERVER_PID" 2>/dev/null; then
  warn "Key server failed to start — check ${LOG_DIR}/keyserver.log"
  warn "server.sh will need the Ansible public key entered manually"
else
  ok "Key server running (PID ${KEY_SERVER_PID})"
fi

# Cleanup on exit
trap 'kill "$KEY_SERVER_PID" 2>/dev/null || true; rm -f "$KEY_SERVER_SCRIPT" /tmp/ridestatus-keyserver.pid' EXIT

# =============================================================================
# Done
# =============================================================================
header "Ansible Bootstrap Complete"

ok "ridestatus-deploy cloned:  ${DEPLOY_DIR}"
ok "Inventory:                 ${INVENTORY_DIR}/hosts.yml"
ok "Ansible log:               ${LOG_DIR}/ansible.log"
ok "Health-check timer:        active (every 5 min)"

echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║              Ansible Key Server Ready                        ║${RESET}"
echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${YELLOW}║  server.sh can fetch the Ansible public key automatically:   ║${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${CYAN}║  URL: http://${ANSIBLE_IP}:${KEY_SERVER_PORT}/ansible_ridestatus.pub${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${YELLOW}║  The server exits after one fetch or 10 minutes.             ║${RESET}"
echo -e "${BOLD}${YELLOW}║  Public key path: ${ANSIBLE_KEY}.pub${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Run bootstrap/server.sh on the RideStatus Server VM now."
info "It will fetch the key automatically if given this VM's dept IP."
info "The key server will stop after server.sh fetches it (or in 10 min)."

# Keep the script alive so the key server keeps running.
# deploy.sh SSHs in and runs this as a background pipe, so it will
# stay up until the key server shuts itself down.
wait "$KEY_SERVER_PID" 2>/dev/null || true
rm -f "$KEY_SERVER_SCRIPT" /tmp/ridestatus-keyserver.pid
ok "Key server stopped."
