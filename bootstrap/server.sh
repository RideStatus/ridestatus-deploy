#!/usr/bin/env bash
# =============================================================================
# RideStatus — Aggregation Server Bootstrap Script
# =============================================================================
# Provisions a fresh Debian 12 VM as the RideStatus Aggregation Server.
# Installs Node.js 22, PM2, PostgreSQL 16, and ridestatus-server.
#
# Usage:    sudo bash server.sh
# Requires: /opt/ridestatus/server.env
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

ENV_FILE="/opt/ridestatus/server.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log_error "Environment file not found: $ENV_FILE"; exit 1
fi
source "$ENV_FILE"

log_info "=== RideStatus Aggregation Server Bootstrap ==="
log_info "Park: ${PARK_NAME:-UNKNOWN}"

apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl git ufw build-essential

install_nodejs 22

# Install PostgreSQL 16
if ! command -v psql &>/dev/null; then
  log_info "Installing PostgreSQL 16..."
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
  echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq && apt-get install -y -qq postgresql-16
fi

log_info "Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE USER ${POSTGRES_USER:-ridestatus} WITH PASSWORD '${POSTGRES_PASS:-changeme}';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE ${POSTGRES_DB:-ridestatus} OWNER ${POSTGRES_USER:-ridestatus};" 2>/dev/null || true

log_info "Installing PM2..."
npm install -g pm2 --silent

# TODO: Deploy ridestatus-server application (see ride-node.sh for options)
log_warn "Application deployment step is a placeholder — see server.sh comments."

configure_firewall_server

log_info "=== Aggregation Server Bootstrap Complete ==="
