#!/usr/bin/env bash
# =============================================================================
# Ride Status — Proxmox Deploy Script  (v2 — Docker Compose)
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates a Ride Status VM, installs Docker, drops docker-compose.yml + .env,
# and starts services with docker compose up -d.
#
# No bootstrap scripts. No PM2. No Ansible installs. Docker handles everything.
#
# NOTE: This script uses Proxmox-local CLI tools (pvesh, qm, pvesm).
# It must be run directly on the target Proxmox host.
# To deploy on a different host, SSH into that host first, then run this script.
#
# Usage:
#   curl -fsSL -H "Accept: application/vnd.github.raw" \
#     "https://api.github.com/repos/RideStatus/ridestatus-deploy/contents/proxmox/deploy.sh" \
#     -o /tmp/deploy.sh && bash /tmp/deploy.sh
#
# Requirements on Proxmox host:
#   apt install dialog jq
# =============================================================================

set -euo pipefail

RED='\033[0;31m';  YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';      RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()    { err "$*"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }
step()   { echo -e "${CYAN}  →${RESET} $*"; }

# =============================================================================
# Preflight
# =============================================================================
[[ $EUID -eq 0 ]] || die "Must be run as root."
command -v pvesh    >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v qm       >/dev/null 2>&1 || die "qm not found"
command -v dialog   >/dev/null 2>&1 || die "dialog not found (apt install dialog)"
command -v scp      >/dev/null 2>&1 || die "scp not found"
command -v ssh      >/dev/null 2>&1 || die "ssh not found"
command -v python3  >/dev/null 2>&1 || die "python3 not found"
command -v curl     >/dev/null 2>&1 || die "curl not found"
command -v jq       >/dev/null 2>&1 || die "jq not found (apt install jq)"

PROXMOX_NODE=$(hostname)
ADMIN_KEY_PATH="/root/ridestatus-admin-key"
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
SNIPPET_DIR="/var/lib/vz/snippets"
COMPOSE_BASE_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/compose"
GHCR_TOKEN_FILE="/root/.config/ridestatus/ghcr-token"

# =============================================================================
# Step 1 — GitHub token (plain terminal, no dialog)
# Read from saved file if present; otherwise walk the user through creating one.
# =============================================================================
GITHUB_TOKEN=""

if [[ -f "$GHCR_TOKEN_FILE" ]]; then
  GITHUB_TOKEN=$(tr -d '[:space:]' < "$GHCR_TOKEN_FILE")
  echo ""
  echo -e "${GREEN}========================================${RESET}"
  echo -e "${BOLD}  Ride Status — Proxmox Deploy${RESET}"
  echo -e "${GREEN}========================================${RESET}"
  echo ""
  ok "GitHub token loaded from ${GHCR_TOKEN_FILE}"
  echo ""
else
  clear
  echo ""
  echo -e "${GREEN}========================================${RESET}"
  echo -e "${BOLD}  Ride Status — Proxmox Deploy${RESET}"
  echo -e "${GREEN}========================================${RESET}"
  echo ""
  echo -e "${BOLD}Step 1 of 1 — GitHub Token Setup${RESET}"
  echo ""
  echo "  Ride Status pulls Docker images from a private GitHub Container"
  echo "  Registry (ghcr.io). A GitHub Personal Access Token (PAT) with"
  echo "  read:packages scope is required."
  echo ""
  echo -e "  ${BOLD}How to create the token:${RESET}"
  echo "  1. Go to: https://github.com/settings/tokens"
  echo "  2. Click \"Generate new token (classic)\""
  echo "  3. Name it: ride-status-deploy"
  echo "  4. Set expiration: No expiration  (or your org's policy)"
  echo "  5. Check ONLY: read:packages"
  echo "  6. Click \"Generate token\""
  echo "  7. Copy the token (starts with ghp_)"
  echo ""
  echo -e "  ${BOLD}Paste your token below and press Enter.${RESET}"
  echo -e "  ${CYAN}(Paste works normally — the token will be saved to${RESET}"
  echo -e "  ${CYAN} ${GHCR_TOKEN_FILE} so you won't be asked again.)${RESET}"
  echo ""
  read -r -p "  Token: " GITHUB_TOKEN
  echo ""

  if [[ -z "$GITHUB_TOKEN" ]]; then
    die "No token entered. Exiting."
  fi

  if [[ ! "$GITHUB_TOKEN" =~ ^gh[ps]_[A-Za-z0-9]+ ]]; then
    warn "Token doesn't look like a GitHub PAT (expected ghp_ or ghs_ prefix). Continuing anyway."
  fi

  mkdir -p "$(dirname "$GHCR_TOKEN_FILE")"
  echo "$GITHUB_TOKEN" > "$GHCR_TOKEN_FILE"
  chmod 600 "$GHCR_TOKEN_FILE"
  ok "Token saved to ${GHCR_TOKEN_FILE} — you won't be asked again on this host."
  echo ""
fi

echo -e "  Press ${BOLD}Enter${RESET} to continue to the deployment wizard..."
read -r
clear

# =============================================================================
# Temp file for dialog output — avoids $() subshell losing the TTY
# =============================================================================
_DLG_TMP=$(mktemp /tmp/ridestatus-dlg-XXXXXX)
_WORK_DIR=$(mktemp -d /tmp/ridestatus-deploy-XXXXXX)

cleanup() {
  rm -f "$_DLG_TMP"
  rm -rf "$_WORK_DIR"
  rm -f "${SNIPPET_DIR}/ridestatus-userdata-"*.yaml 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# dialog helpers
# =============================================================================
WT_H=20; WT_W=72

wt_msg() { dialog --title "Ride Status Deploy" --msgbox "$1" $WT_H $WT_W; }

wt_input() {
  local _v=$1 _p=$2 _d=${3:-}
  dialog --title "Ride Status Deploy" --inputbox "$_p" 10 $WT_W "$_d" 2>"$_DLG_TMP" || true
  local _val; _val=$(cat "$_DLG_TMP")
  [[ -z "$_val" && -n "$_d" ]] && _val="$_d"
  printf -v "$_v" '%s' "$_val"
}

wt_password() {
  local _v=$1 _p=$2
  dialog --title "Ride Status Deploy" --passwordbox "$_p" 10 $WT_W 2>"$_DLG_TMP" || true
  printf -v "$_v" '%s' "$(cat "$_DLG_TMP")"
}

wt_menu() {
  local _v=$1 _p=$2; shift 2
  dialog --title "Ride Status Deploy" --menu "$_p" $WT_H $WT_W 8 "$@" 2>"$_DLG_TMP" || true
  printf -v "$_v" '%s' "$(cat "$_DLG_TMP")"
}

wt_yesno() { dialog --title "Ride Status Deploy" --yesno "$1" 10 $WT_W; }

# =============================================================================
# Storage detection
# =============================================================================
storage_json() { pvesh get /storage --output-format json 2>/dev/null || echo '[]'; }

find_lvm_storage() {
  pvesm status --storage "local-lvm" &>/dev/null && echo "local-lvm" && return
  storage_json | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if 'images' in s.get('content',''):
        print(s['storage']); break
" 2>/dev/null || true
}

find_dir_storage() {
  storage_json | python3 -c "
import sys,json
stores=json.load(sys.stdin)
for s in stores:
    if s.get('storage')=='local' and s.get('type')=='dir':
        print('local'); sys.exit(0)
for s in stores:
    if s.get('type')=='dir':
        print(s['storage']); sys.exit(0)
" 2>/dev/null || true
}

ensure_content_type() {
  local storage=$1 ctype=$2
  local cur
  cur=$(storage_json | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if s.get('storage')=='${storage}':
        print(s.get('content','')); break
" 2>/dev/null || true)
  echo "$cur" | grep -qw "$ctype" && return 0
  pvesm set "$storage" --content "${cur:+${cur},}${ctype}" \
    || die "Failed to enable ${ctype} on ${storage}"
}

DISK_STORAGE=$(find_lvm_storage)
[[ -n "$DISK_STORAGE" ]] || die "No images-capable storage found"
CI_STORAGE=$(find_dir_storage)
[[ -n "$CI_STORAGE" ]] || die "No directory-type storage found"
ensure_content_type "$CI_STORAGE" "images"
ensure_content_type "$CI_STORAGE" "snippets"
mkdir -p "$SNIPPET_DIR"

# =============================================================================
# USB NIC detection
# =============================================================================
declare -A USB_NIC_MAC=() USB_NIC_BUS=() USB_NIC_VP=()
declare -a FREE_USB_NICS=()
declare -A USB_BUS_CLAIMED=()

_detect_usb_nics() {
  local iface syspath usb_dir vp bp v p
  for iface in $(ip -o link show | awk -F': ' '{print $2}' \
      | grep -v '^lo$' | grep -v '@' \
      | grep -Ev '^(vmbr|tap|veth|fwbr|fwpr|fwln)'); do
    syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
    [[ -z "$syspath" ]] && continue
    echo "$syspath" | grep -q '/usb' || continue
    usb_dir=$(echo "$syspath" | sed 's|/[^/]*$||')
    vp=""
    while [[ "$usb_dir" =~ /usb ]]; do
      v=$(cat "${usb_dir}/idVendor"  2>/dev/null || true)
      p=$(cat "${usb_dir}/idProduct" 2>/dev/null || true)
      [[ -n "$v" && -n "$p" ]] && vp="${v}:${p}" && break
      usb_dir=$(dirname "$usb_dir")
    done
    [[ -z "$vp" ]] && continue
    bp=$(echo "$syspath" | grep -oP 'usb\d+/\K[\d]+-[\d.]+(?=/)' | head -1 || true)
    [[ -z "$bp" ]] && continue
    USB_NIC_MAC["$iface"]=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
    USB_NIC_BUS["$iface"]="$bp"
    USB_NIC_VP["$iface"]="$vp"
  done

  local vmid cfg entry raw
  for vmid in $(pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null \
      | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true); do
    cfg=$(pvesh get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" --output-format json 2>/dev/null || true)
    while IFS= read -r entry; do
      raw=$(echo "$entry" | grep -o 'host=[^ ",]*' | sed 's/host=//' || true)
      [[ -z "$raw" ]] && continue
      echo "$raw" | grep -qP '^\d+-[\d.]+$' && USB_BUS_CLAIMED["$raw"]="$vmid"
    done < <(echo "$cfg" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done

  for iface in "${!USB_NIC_VP[@]}"; do
    [[ -z "${USB_BUS_CLAIMED[${USB_NIC_BUS[$iface]}]:-}" ]] && FREE_USB_NICS+=("$iface")
  done
}
_detect_usb_nics

mapfile -t EXISTING_BRIDGES < <(
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' | grep -v '@' || true
)

# =============================================================================
# Admin SSH keypair (persistent across runs)
# =============================================================================
ADMIN_SSH_PUBKEY=""
ADMIN_GENERATED=false

if [[ -f "${ADMIN_KEY_PATH}.pub" ]]; then
  ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
else
  ssh-keygen -t ed25519 -f "$ADMIN_KEY_PATH" -N "" -C "ridestatus-admin" -q
  ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
  ADMIN_GENERATED=true
fi

# Temp deploy keypair (single-use, destroyed on exit)
DEPLOY_KEY="${_WORK_DIR}/deploy_key"
ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "ridestatus-deploy-temp" -q
DEPLOY_PUBKEY_CONTENT=$(cat "${DEPLOY_KEY}.pub")

# =============================================================================
# SSH helpers
#
# rssh      — BatchMode=yes, no TTY. For simple remote commands.
# rssh_pipe — No BatchMode, no TTY. For piping heredocs (sudo bash -s).
#             Output streams to the calling terminal normally.
# rssh_tty  — Interactive TTY (-t -t). Only for docker compose pull/up
#             which renders progress bars requiring a TTY.
# =============================================================================
_ssh_base_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes"

rssh() {
  local ip=$1; shift
  for key in "$DEPLOY_KEY" "$ADMIN_KEY_PATH"; do
    [[ -f "$key" ]] || continue
    # shellcheck disable=SC2086
    SSH_AUTH_SOCK="" ssh -i "$key" $_ssh_base_opts -o BatchMode=yes "ridestatus@${ip}" "$@" \
      2>/dev/null && return 0
  done
  return 1
}

rssh_pipe() {
  # Like rssh but without BatchMode — allows stdin/heredoc piping.
  # Output (stdout+stderr) streams directly to the terminal.
  local ip=$1; shift
  for key in "$DEPLOY_KEY" "$ADMIN_KEY_PATH"; do
    [[ -f "$key" ]] || continue
    # shellcheck disable=SC2086
    SSH_AUTH_SOCK="" ssh -i "$key" $_ssh_base_opts "ridestatus@${ip}" "$@" \
      && return 0
  done
  return 1
}

rssh_tty() {
  local ip=$1; shift
  for key in "$DEPLOY_KEY" "$ADMIN_KEY_PATH"; do
    [[ -f "$key" ]] || continue
    # shellcheck disable=SC2086
    SSH_AUTH_SOCK="" ssh -i "$key" $_ssh_base_opts -t -t "ridestatus@${ip}" "$@" \
      2>/dev/null && return 0
  done
  return 1
}

rscp() {
  local local_file=$1 ip=$2 remote_path=$3
  for key in "$DEPLOY_KEY" "$ADMIN_KEY_PATH"; do
    [[ -f "$key" ]] || continue
    # shellcheck disable=SC2086
    SSH_AUTH_SOCK="" scp -i "$key" $_ssh_base_opts -o BatchMode=yes \
      "$local_file" "ridestatus@${ip}:${remote_path}" 2>/dev/null && return 0
  done
  return 1
}

wait_ssh() {
  local ip=$1 elapsed=0
  info "Waiting for SSH on ${ip}..."
  while (( elapsed < 300 )); do
    rssh "$ip" 'exit 0' && { ok "SSH ready"; return 0; }
    sleep 5; elapsed=$(( elapsed+5 )); echo -n "."
  done
  echo ""; die "Timed out waiting for SSH on ${ip}"
}

wait_agent() {
  local vmid=$1 elapsed=0
  info "Waiting for guest agent on VM ${vmid}..."
  while (( elapsed < 300 )); do
    qm guest cmd "$vmid" ping &>/dev/null 2>&1 && { ok "Guest agent ready"; return 0; }
    sleep 5; elapsed=$(( elapsed+5 )); echo -n "."
  done
  echo ""; die "Timed out waiting for guest agent"
}

wait_http() {
  local url=$1 elapsed=0
  info "Waiting for dashboard at ${url}..."
  while (( elapsed < 300 )); do
    if curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "^[23]"; then
      echo ""; ok "Dashboard is up"; return 0
    fi
    sleep 5; elapsed=$(( elapsed+5 )); echo -n "."
  done
  echo ""; warn "Dashboard did not respond within 5 minutes — check container logs"
}

purge_known_host() {
  ssh-keygen -f /root/.ssh/known_hosts -R "$1" &>/dev/null 2>&1 || true
}

# =============================================================================
# NIC collection helper
# =============================================================================
declare -a NIC_TYPES=() NIC_BRIDGES=() NIC_USBS=() NIC_IPS=() NIC_GWS=() NIC_DR=()
_session_claimed=()

collect_nics() {
  local vm_label=$1
  NIC_TYPES=(); NIC_BRIDGES=(); NIC_USBS=(); NIC_IPS=(); NIC_GWS=(); NIC_DR=()
  local dr_assigned=false nic_num=1

  while true; do
    local nic_type=""
    local available_usb=()
    for u in "${FREE_USB_NICS[@]:-}"; do
      local skip=false
      for c in "${_session_claimed[@]:-}"; do [[ "$c" == "$u" ]] && skip=true && break; done
      $skip || available_usb+=("$u")
    done

    if [[ ${#available_usb[@]} -gt 0 ]]; then
      local conn_items=("bridge" "Shared bridge (virtio)")
      for u in "${available_usb[@]}"; do
        conn_items+=("usb:${u}" "USB passthrough: ${u}  MAC=${USB_NIC_MAC[$u]}  bus=${USB_NIC_BUS[$u]}")
      done
      wt_menu nic_type "${vm_label} vNIC${nic_num} — Connection type:" "${conn_items[@]}"
    else
      nic_type="bridge"
    fi

    local bridge_name="" usb_iface=""
    if [[ "$nic_type" == "bridge" ]]; then
      local b_items=()
      for b in "${EXISTING_BRIDGES[@]:-}"; do b_items+=("$b" "Existing bridge"); done
      b_items+=("new" "Create new bridge")
      local b_sel=""
      wt_menu b_sel "${vm_label} vNIC${nic_num} — Bridge:" "${b_items[@]}"
      if [[ "$b_sel" == "new" ]]; then
        local next_num=0
        while ip link show "vmbr${next_num}" &>/dev/null 2>&1; do next_num=$(( next_num+1 )); done
        wt_input bridge_name "New bridge name:" "vmbr${next_num}"
        if ! ip link show "$bridge_name" &>/dev/null 2>&1; then
          local phys_items=()
          for iface in $(ip -o link show | awk -F': ' '{print $2}' \
              | grep -Ev '^(lo|vmbr|tap|veth|fwbr|fwpr|fwln)' | grep -v '@'); do
            phys_items+=("$iface" "$(cat /sys/class/net/${iface}/address 2>/dev/null || echo unknown)")
          done
          local phys_sel=""
          wt_menu phys_sel "Physical NIC for ${bridge_name}:" "${phys_items[@]}"
          { echo "auto ${bridge_name}"
            echo "iface ${bridge_name} inet manual"
            echo "  bridge_ports ${phys_sel}"
            echo "  bridge_stp off"; echo "  bridge_fd 0"
          } > "/etc/network/interfaces.d/${bridge_name}"
          ifup "$bridge_name" 2>/dev/null || true
        fi
        EXISTING_BRIDGES+=("$bridge_name")
      else
        bridge_name="$b_sel"
      fi
    else
      usb_iface="${nic_type#usb:}"
      nic_type="usb"
      _session_claimed+=("$usb_iface")
    fi

    local ip_cidr=""
    while true; do
      wt_input ip_cidr "${vm_label} vNIC${nic_num} — Static IP/prefix (e.g. 10.0.1.10/24):" ""
      [[ "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
      wt_msg "Invalid format. Example: 10.0.1.10/24"
    done

    local gw="" is_dr="no"
    if ! $dr_assigned; then
      if wt_yesno "Use vNIC${nic_num} (${ip_cidr}) as the default route?\n\nThis NIC carries internet traffic."; then
        is_dr="yes"; dr_assigned=true
        wt_input gw "Default gateway:" ""
      fi
    fi

    NIC_TYPES+=("$nic_type"); NIC_BRIDGES+=("$bridge_name")
    NIC_USBS+=("$usb_iface"); NIC_IPS+=("$ip_cidr")
    NIC_GWS+=("$gw");         NIC_DR+=("$is_dr")

    wt_yesno "Add another NIC to ${vm_label}?" || break
    nic_num=$(( nic_num + 1 ))
  done
}

# =============================================================================
# Welcome
# =============================================================================
wt_msg "Welcome to Ride Status Proxmox Deploy

Host: ${PROXMOX_NODE}
Storage: OS=${DISK_STORAGE}  CI=${CI_STORAGE}

Creates a VM, installs Docker, and starts Ride Status services.
All settings collected now — no prompts during deployment."

# =============================================================================
# VM role selection
# =============================================================================
VM_ROLE=""
wt_menu VM_ROLE "Which VM should be created?" \
  "manage" "Management Plane — ridestatus-manage" \
  "server" "Park Board Server — ridestatus-server"

[[ -z "$VM_ROLE" ]] && { echo "Cancelled."; exit 0; }

# =============================================================================
# VM config
# =============================================================================
next_vmid=300
while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${next_vmid}/status" &>/dev/null 2>&1; do
  next_vmid=$(( next_vmid + 1 ))
done

case "$VM_ROLE" in
  manage) default_ram=2 default_disk=20 default_host="ridestatus-manage" ;;
  server) default_ram=4 default_disk=64 default_host="ridestatus-server" ;;
esac

VMID="" VM_RAM="" VM_CORES="" VM_DISK="" VM_HOST=""
wt_input VMID     "VM ID:"              "$next_vmid"
wt_input VM_RAM   "RAM (GB):"           "$default_ram"
wt_input VM_CORES "CPU cores:"          "2"
wt_input VM_DISK  "Disk (GB):"          "$default_disk"
wt_input VM_HOST  "Hostname:"           "$default_host"

collect_nics "$VM_HOST"
declare -a VM_NIC_TYPES=("${NIC_TYPES[@]}")
declare -a VM_NIC_BRIDGES=("${NIC_BRIDGES[@]}")
declare -a VM_NIC_USBS=("${NIC_USBS[@]}")
declare -a VM_NIC_IPS=("${NIC_IPS[@]}")
declare -a VM_NIC_GWS=("${NIC_GWS[@]}")
declare -a VM_NIC_DR=("${NIC_DR[@]}")
VM_IP="${VM_NIC_IPS[0]%%/*}"

# =============================================================================
# Role-specific config
# =============================================================================
PARK_NAME="" PARK_TZ="" API_KEY="" BOOTSTRAP_TOKEN=""
WEATHER_API_KEY="" WEATHER_ZIP="" ALERT_EMAIL=""
SMTP_HOST="" SMTP_PORT="587" SMTP_USER="" SMTP_PASS=""
PROXMOX_API_HOST="" PROXMOX_API_PORT="8006"
PROXMOX_API_USER="" PROXMOX_API_PASS="" PROXMOX_API_NODE=""

if [[ "$VM_ROLE" == "server" ]]; then
  wt_input PARK_NAME       "Park name:"                       "My Park"
  wt_input PARK_TZ         "Timezone:"                        "America/Chicago"
  wt_input WEATHER_API_KEY "WeatherAPI.com key (blank=skip):" ""
  wt_input WEATHER_ZIP     "Weather ZIP code:"                "00000"
  wt_input ALERT_EMAIL     "Alert email (optional):"          ""
  wt_input SMTP_HOST       "SMTP host (optional):"            ""
  if [[ -n "$SMTP_HOST" ]]; then
    wt_input    SMTP_PORT "SMTP port:"     "587"
    wt_input    SMTP_USER "SMTP username:" ""
    wt_password SMTP_PASS "SMTP password:"
  fi
  API_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  BOOTSTRAP_TOKEN=$(python3 -c "import secrets,string; \
    print(''.join(secrets.choice(string.ascii_uppercase+'0123456789') for _ in range(8)))")
fi

if [[ "$VM_ROLE" == "manage" ]]; then
  # NOTE: SERVER_URL and SERVER_API_KEY are not collected here — the park board
  # server does not exist yet. They are left blank in .env and filled in later.
  wt_msg "Proxmox API Credentials\n\nThe management plane uses the Proxmox API to provision new VMs.\nEnter the credentials for this Proxmox host."
  wt_input    PROXMOX_API_HOST "Proxmox API host (IP of this host):" "$(hostname -I | awk '{print $1}')"
  wt_input    PROXMOX_API_PORT "Proxmox API port:"                   "8006"
  wt_input    PROXMOX_API_USER "Proxmox API user (e.g. root@pam):"   "root@pam"
  wt_password PROXMOX_API_PASS "Proxmox API password:"
  wt_input    PROXMOX_API_NODE "Proxmox node name:"                  "${PROXMOX_NODE}"
fi

# =============================================================================
# Confirm
# =============================================================================
_summary="VM ${VMID} — ${VM_HOST} (${VM_ROLE})\n"
_summary+="RAM: ${VM_RAM}GB  CPU: ${VM_CORES}  Disk: ${VM_DISK}GB\n"
for i in "${!VM_NIC_TYPES[@]}"; do
  _dr=""; [[ "${VM_NIC_DR[$i]}" == "yes" ]] && _dr=" [GW=${VM_NIC_GWS[$i]}]"
  _summary+="  vNIC$((i+1)): ${VM_NIC_IPS[$i]}${_dr}\n"
done
[[ -n "$PARK_NAME" ]] && _summary+="\nPark: ${PARK_NAME}  TZ: ${PARK_TZ}"

wt_yesno "Confirm deployment:\n\n${_summary}\n\nProceed?" \
  || { echo "Cancelled."; exit 0; }

# =============================================================================
# Ubuntu cloud image
# =============================================================================
header "Ubuntu Image"
if [[ -f "$UBUNTU_IMG_PATH" ]]; then
  info "Ubuntu 24.04 cloud image cached"
else
  info "Downloading Ubuntu 24.04 cloud image (~600MB)..."
  mkdir -p "$(dirname "$UBUNTU_IMG_PATH")"
  wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL" \
    || die "Download failed"
  ok "Image downloaded"
fi

# =============================================================================
# Write cloud-init snippet
# =============================================================================
SNIPPET_FILE="${SNIPPET_DIR}/ridestatus-userdata-${VMID}.yaml"
cat > "$SNIPPET_FILE" <<YAML
#cloud-config
users:
  - name: ridestatus
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${DEPLOY_PUBKEY_CONTENT}
      - ${ADMIN_SSH_PUBKEY}
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
YAML

# =============================================================================
# Create VM
# =============================================================================
header "Creating VM ${VMID}"
RAM_MB=$(( VM_RAM * 1024 ))

qm create "$VMID" --name "$VM_HOST" --memory "$RAM_MB" --cores "$VM_CORES" \
  --cpu cputype=host --ostype l26 --agent enabled=1 --serial0 socket --vga serial0

IMG_COPY="${_WORK_DIR}/vm${VMID}.img"
step "Copying base image..."
cp "$UBUNTU_IMG_PATH" "$IMG_COPY"
qm importdisk "$VMID" "$IMG_COPY" "$DISK_STORAGE" --format qcow2
rm -f "$IMG_COPY"

qm set "$VMID" --scsihw virtio-scsi-pci \
  --scsi0 "${DISK_STORAGE}:vm-${VMID}-disk-0,discard=on" --boot order=scsi0
qm resize "$VMID" scsi0 "${VM_DISK}G"

# NICs
br_idx=0; usb_slot=0
for i in "${!VM_NIC_TYPES[@]}"; do
  if [[ "${VM_NIC_TYPES[$i]}" == "bridge" ]]; then
    qm set "$VMID" --net${br_idx} "virtio,bridge=${VM_NIC_BRIDGES[$i]}"
    br_idx=$(( br_idx+1 ))
  else
    bp="${USB_NIC_BUS[${VM_NIC_USBS[$i]}]:-}"
    if [[ -n "$bp" ]]; then
      qm set "$VMID" --usb${usb_slot} "host=${bp}"
    else
      qm set "$VMID" --usb${usb_slot} "host=${USB_NIC_VP[${VM_NIC_USBS[$i]}]}"
    fi
    usb_slot=$(( usb_slot+1 ))
  fi
done

# Cloud-init IP config
qm set "$VMID" --ide2 "${CI_STORAGE}:cloudinit"
ipcfg_idx=0
for i in "${!VM_NIC_TYPES[@]}"; do
  [[ "${VM_NIC_TYPES[$i]}" != "bridge" ]] && continue
  gw_part=""
  [[ -n "${VM_NIC_GWS[$i]:-}" ]] && gw_part=",gw=${VM_NIC_GWS[$i]}"
  qm set "$VMID" --ipconfig${ipcfg_idx} "ip=${VM_NIC_IPS[$i]}${gw_part}"
  ipcfg_idx=$(( ipcfg_idx+1 ))
done

qm set "$VMID" --nameserver "8.8.8.8" --ciupgrade 0
qm set "$VMID" --cicustom "user=${CI_STORAGE}:snippets/$(basename "$SNIPPET_FILE")"
qm cloudinit update "$VMID"
ok "VM ${VMID} configured"

qm start "$VMID"
purge_known_host "$VM_IP"
ok "VM ${VMID} started"

# =============================================================================
# Wait for VM
# =============================================================================
wait_agent "$VMID"
wait_ssh "$VM_IP"

# =============================================================================
# Install Docker
# Uses rssh_pipe — no TTY, stdin piping allowed, output streams to terminal.
# =============================================================================
header "Installing Docker"
rssh_pipe "$VM_IP" "sudo bash -s" <<'DOCKER_INSTALL'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker ridestatus
systemctl enable docker
echo "Docker installed"
DOCKER_INSTALL
ok "Docker installed"

# =============================================================================
# Login to ghcr.io
# =============================================================================
if [[ -n "$GITHUB_TOKEN" ]]; then
  header "Logging into ghcr.io"
  step "Authenticating on Proxmox host..."
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u ridestatus --password-stdin 2>/dev/null || true
  step "Authenticating on VM..."
  rssh "$VM_IP" "echo '${GITHUB_TOKEN}' | sudo docker login ghcr.io -u ridestatus --password-stdin"
  ok "Logged into ghcr.io"
fi

# =============================================================================
# Write .env file locally then SCP it
# =============================================================================
header "Deploying ${VM_ROLE}"

ENV_FILE="${_WORK_DIR}/.env"
case "$VM_ROLE" in
  manage)
    SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    PG_PASS=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    cat > "$ENV_FILE" <<ENV
NODE_ENV=production
PORT=3000
SESSION_SECRET=${SESSION_SECRET}
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=ridestatus_manage
POSTGRES_USER=ridestatus
POSTGRES_PASSWORD=${PG_PASS}
PROXMOX_HOST=${PROXMOX_API_HOST}
PROXMOX_PORT=${PROXMOX_API_PORT}
PROXMOX_USER=${PROXMOX_API_USER}
PROXMOX_PASSWORD=${PROXMOX_API_PASS}
PROXMOX_NODE=${PROXMOX_API_NODE}
MANAGE_SSH_KEY_PATH=/home/ridestatus/.ssh/ansible_ridestatus
# Fill in once ridestatus-server is deployed on the park board host:
SERVER_URL=
SERVER_API_KEY=
GITHUB_TOKEN=${GITHUB_TOKEN}
ENV
    ;;
  server)
    PG_PASS=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    cat > "$ENV_FILE" <<ENV
NODE_ENV=production
PORT=3000
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=ridestatus
POSTGRES_USER=ridestatus
POSTGRES_PASSWORD=${PG_PASS}
API_KEY=${API_KEY}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
PARK_NAME=${PARK_NAME}
PARK_TZ=${PARK_TZ}
WEATHER_API_KEY=${WEATHER_API_KEY}
WEATHER_ZIP=${WEATHER_ZIP}
ALERT_EMAIL=${ALERT_EMAIL}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
ENV
    ;;
esac

step "Downloading docker-compose.yml..."
COMPOSE_FILE="${_WORK_DIR}/docker-compose.yml"
curl -fsSL "${COMPOSE_BASE_URL}/${VM_ROLE}/docker-compose.yml" -o "$COMPOSE_FILE" \
  || die "Failed to download docker-compose.yml for ${VM_ROLE}"

step "Copying configuration to VM..."
rssh "$VM_IP" "sudo mkdir -p /opt/ridestatus && sudo chown ridestatus:ridestatus /opt/ridestatus"
rscp "$ENV_FILE"     "$VM_IP" "/opt/ridestatus/.env"
rscp "$COMPOSE_FILE" "$VM_IP" "/opt/ridestatus/docker-compose.yml"
ok "Configuration deployed"

# =============================================================================
# Start services
# rssh_tty — docker compose pull needs a TTY for progress bar rendering.
# =============================================================================
header "Starting Services"
step "Pulling Docker images (this may take a few minutes)..."
rssh_tty "$VM_IP" \
  "cd /opt/ridestatus && sudo docker compose pull && sudo docker compose up -d"
ok "Services started"

# =============================================================================
# Automatic updates (manage role only)
# Uses rssh_pipe — no TTY, stdin piping allowed, output streams to terminal.
# =============================================================================
if [[ "$VM_ROLE" == "manage" ]]; then
  header "Configuring Automatic Updates"

  step "Downloading self-update script..."
  SELF_UPDATE_LOCAL="${_WORK_DIR}/self-update.sh"
  curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "https://api.github.com/repos/RideStatus/ridestatus-manage/contents/backend/scripts/self-update.sh" \
    -o "$SELF_UPDATE_LOCAL" \
    || die "Failed to download self-update.sh"

  step "Installing self-update script and cron job..."
  rscp "$SELF_UPDATE_LOCAL" "$VM_IP" "/tmp/self-update.sh"
  rssh_pipe "$VM_IP" "sudo bash -s" <<'AUTO_UPDATE'
set -e
install -m 0755 /tmp/self-update.sh /opt/ridestatus/self-update.sh
chown root:root /opt/ridestatus/self-update.sh
touch /var/log/ridestatus-self-update.log
chmod 644 /var/log/ridestatus-self-update.log
echo "*/30 * * * * root /opt/ridestatus/self-update.sh >> /var/log/ridestatus-self-update.log 2>&1" \
  > /etc/cron.d/ridestatus-manage-update
chmod 644 /etc/cron.d/ridestatus-manage-update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  unattended-upgrades update-notifier-common
tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'CONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
CONF
tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
systemctl enable --now unattended-upgrades
echo "Automatic updates configured"
AUTO_UPDATE
  ok "Self-update cron installed (every 30 min)"
  ok "unattended-upgrades enabled (security patches, no auto-reboot)"
fi

# =============================================================================
# Wait for dashboard to respond
# =============================================================================
wait_http "http://${VM_IP}:3000"

# =============================================================================
# Done
# =============================================================================
header "Deployment Complete"
echo ""
rssh "$VM_IP" "sudo docker compose -f /opt/ridestatus/docker-compose.yml ps" 2>/dev/null || true
echo ""

if $ADMIN_GENERATED; then
  warn "*** Copy admin SSH key off this Proxmox host ***"
  warn "    ${ADMIN_KEY_PATH}"
fi

if [[ "$VM_ROLE" == "server" ]]; then
  ok "Park board:      http://${VM_IP}:3000"
  ok "Bootstrap token: ${BOOTSTRAP_TOKEN}"
  ok "API key:         ${API_KEY}"
  warn "Save the bootstrap token and API key — you will need them to connect edge nodes"
fi

if [[ "$VM_ROLE" == "manage" ]]; then
  ok "Management UI:  http://${VM_IP}:3000"
  ok "Default login:  admin / admin  (change immediately)"
  ok "Self-update:    runs every 30 min via cron, or use the Dashboard button"
  warn "SERVER_URL and SERVER_API_KEY in /opt/ridestatus/.env are blank."
  warn "Fill them in once the park board server is deployed."
fi
echo ""
