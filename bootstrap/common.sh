#!/usr/bin/env bash
# =============================================================================
# RideStatus — Shared Bootstrap Functions
# =============================================================================
# Source this file from ride-node.sh or server.sh.
# Provides: logging helpers, Node.js installer, firewall configurator.
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RESET='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

install_nodejs() {
  local major="${1:-22}"
  if node --version 2>/dev/null | grep -q "^v${major}\."; then
    log_info "Node.js ${major} already installed ($(node --version))."
    return 0
  fi
  log_info "Installing Node.js ${major}..."
  curl -fsSL "https://deb.nodesource.com/setup_${major}.x" | bash - > /dev/null
  apt-get install -y -qq nodejs
  log_info "Node.js installed: $(node --version)"
}

configure_firewall_ride_node() {
  log_info "Configuring firewall (ride node)..."
  ufw --force reset > /dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow 1880/tcp comment "Node-RED editor + uibuilder"
  ufw --force enable
  log_info "Firewall configured."
}

configure_firewall_server() {
  log_info "Configuring firewall (server)..."
  ufw --force reset > /dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow 3100/tcp comment "RideStatus aggregation API"
  ufw allow 3000/tcp comment "RideStatus main board UI"
  # PostgreSQL — restrict to management VLAN only (uncomment and adjust subnet):
  # ufw allow from 10.250.0.0/24 to any port 5432
  ufw --force enable
  log_info "Firewall configured."
}
