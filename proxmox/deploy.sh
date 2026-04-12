#!/usr/bin/env bash
# =============================================================================
# RideStatus — Proxmox Deploy Script  (v2 — Docker Compose)
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates a RideStatus VM, installs Docker, drops docker-compose.yml + .env,
# and starts services with docker compose up -d.
#
# No bootstrap scripts. No PM2. No Ansible installs. Docker handles everything.
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
SELF_UPDATE_SCRIPT_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-manage/main/backend/scripts/self-update.sh"

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

wt_msg() { dialog --title "RideStatus Deploy" --msgbox "$1" $WT_H $WT_W; }

wt_input() {
  local _v=$1 _p=$2 _d=${3:-}
  dialog --title "RideStatus Deploy" --inputbox "$_p" 10 $WT_W "$_d" 2>"$_DLG_TMP" || true
  local _val; _val=$(cat "$_DLG_TMP")
  [[ -z "$_val" && -n "$_d" ]] && _val="$_d"
  printf -v "$_v" '%s' "$_val"
}

wt_password() {
  local _v=$1 _p=$2
  dialog --title "RideStatus Deploy" --passwordbox "$_p" 10 $WT_W 2>"$_DLG_TMP" || true
  printf -v "$_v" '%s' "$(cat "$_DLG_TMP")"
}

wt_menu() {
  local _v=$1 _p=$2; shift 2
  dialog --title "RideStatus Deploy" --menu "$_p" $WT_H $WT_W 8 "$@" 2>"$_DLG_TMP" || true
  printf -v "$_v" '%s' "$(cat "$_DLG_TMP")"
}

wt_yesno() { dialog --title "RideStatus Deploy" --yesno "$1" 10 $WT_W; }

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
# SSH helpers — try deploy key then admin key
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
      wt_input ip_cidr "${vm_label} vNIC${nic_num} — Static IP/prefix (e.g. 10.250.5.101/19):" ""
      [[ "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
      wt_msg "Invalid format. Example: 10.250.5.101/19"
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
wt_msg "Welcome to RideStatus Proxmox Deploy

Host: ${PROXMOX_NODE}
Storage: OS=${DISK_STORAGE}  CI=${CI_STORAGE}

Creates a VM, installs Docker, and starts RideStatus services.
All settings collected now — no prompts during deployment."

# =============================================================================
# VM role selection
# =============================================================================
VM_ROLE=""
wt_menu VM_ROLE "Which VM should be created?" \
  "manage" "Management Plane — ridestatus-manage (SCADA 1)" \
  "server" "Park Board Server — ridestatus-server (SCADA 2)" \
  "edge"   "Edge Node — ridestatus-ride (VM-based edge node)"

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
  edge)   default_ram=2 default_disk=20 default_host="ridestatus-edge"   ;;
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
WEATHER_API_KEY="" WEATHER_ZIP="" ALERT_EMAIL="" ALERT_SMS=""
SMTP_HOST="" SMTP_PORT="587" SMTP_USER="" SMTP_PASS=""
GITHUB_TOKEN=""

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

if [[ "$VM_ROLE" == "manage" || "$VM_ROLE" == "edge" ]]; then
  wt_password GITHUB_TOKEN "GitHub token (for pulling private images, or blank):"
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
# =============================================================================
header "Installing Docker"
rssh_tty "$VM_IP" "bash -s" <<'DOCKER_INSTALL'
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
# Write .env file locally then SCP it
# =============================================================================
header "Deploying ${VM_ROLE}"

ENV_FILE="${_WORK_DIR}/.env"
case "$VM_ROLE" in
  manage)
    cat > "$ENV_FILE" <<ENV
NODE_ENV=production
PORT=3000
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=ridestatus_manage
POSTGRES_USER=ridestatus
POSTGRES_PASSWORD=$(python3 -c "import secrets; print(secrets.token_hex(16))")
GITHUB_TOKEN=${GITHUB_TOKEN}
ENV
    ;;
  server)
    cat > "$ENV_FILE" <<ENV
NODE_ENV=production
PORT=3000
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DB=ridestatus
POSTGRES_USER=ridestatus
POSTGRES_PASSWORD=$(python3 -c "import secrets; print(secrets.token_hex(16))")
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
  edge)
    cat > "$ENV_FILE" <<ENV
NODE_ENV=production
GITHUB_TOKEN=${GITHUB_TOKEN}
ENV
    ;;
esac

# Download docker-compose.yml for this role
COMPOSE_FILE="${_WORK_DIR}/docker-compose.yml"
curl -fsSL "${COMPOSE_BASE_URL}/${VM_ROLE}/docker-compose.yml" -o "$COMPOSE_FILE" \
  || die "Failed to download docker-compose.yml for ${VM_ROLE}"

# SCP both files to VM
rssh "$VM_IP" "mkdir -p /opt/ridestatus"
rscp "$ENV_FILE"     "$VM_IP" "/opt/ridestatus/.env"
rscp "$COMPOSE_FILE" "$VM_IP" "/opt/ridestatus/docker-compose.yml"
rssh "$VM_IP" "chown -R ridestatus:ridestatus /opt/ridestatus"
ok "Files deployed"

# =============================================================================
# Start services
# =============================================================================
header "Starting Services"
rssh_tty "$VM_IP" \
  "cd /opt/ridestatus && sudo docker compose pull && sudo docker compose up -d"
ok "Services started"

# =============================================================================
# Automatic updates (manage role only)
# Self-update script + cron every 30 min + unattended-upgrades for OS patches
# =============================================================================
if [[ "$VM_ROLE" == "manage" ]]; then
  header "Configuring Automatic Updates"

  # Download self-update script and SCP to VM
  SELF_UPDATE_LOCAL="${_WORK_DIR}/self-update.sh"
  curl -fsSL "$SELF_UPDATE_SCRIPT_URL" -o "$SELF_UPDATE_LOCAL" \
    || die "Failed to download self-update.sh"
  rscp "$SELF_UPDATE_LOCAL" "$VM_IP" "/tmp/self-update.sh"

  rssh_tty "$VM_IP" "bash -s" <<'AUTO_UPDATE'
set -e
export DEBIAN_FRONTEND=noninteractive

# Install self-update script
sudo install -m 0755 /tmp/self-update.sh /opt/ridestatus/self-update.sh
sudo chown root:root /opt/ridestatus/self-update.sh

# Create log file
sudo touch /var/log/ridestatus-self-update.log
sudo chmod 644 /var/log/ridestatus-self-update.log

# Cron job: run self-update every 30 minutes
echo "*/30 * * * * root /opt/ridestatus/self-update.sh >> /var/log/ridestatus-self-update.log 2>&1" \
  | sudo tee /etc/cron.d/ridestatus-manage-update > /dev/null
sudo chmod 644 /etc/cron.d/ridestatus-manage-update

# Install unattended-upgrades for automatic OS security patches
apt-get install -y --no-install-recommends unattended-upgrades update-notifier-common

# Configure unattended-upgrades: security patches only, auto-clean, no auto-reboot
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'CONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
CONF

# Enable daily auto-upgrade
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF

sudo systemctl enable --now unattended-upgrades
echo "Automatic updates configured"
AUTO_UPDATE
  ok "Self-update cron installed (every 30 min)"
  ok "unattended-upgrades enabled (security patches, no auto-reboot)"
fi

# =============================================================================
# Done
# =============================================================================
header "Deployment Complete"
ok "VM ${VMID} (${VM_HOST}) — ${VM_IP}"
echo ""
rssh "$VM_IP" "docker compose -f /opt/ridestatus/docker-compose.yml ps" 2>/dev/null || true
echo ""

if $ADMIN_GENERATED; then
  warn "*** Copy admin SSH key off this Proxmox host ***"
  warn "    ${ADMIN_KEY_PATH}"
fi

if [[ "$VM_ROLE" == "server" ]]; then
  ok "Park board: http://${VM_IP}:3000"
  ok "Bootstrap token: ${BOOTSTRAP_TOKEN}"
  ok "API key: ${API_KEY}"
  warn "Save the bootstrap token and API key — you will need them for edge nodes"
fi

if [[ "$VM_ROLE" == "manage" ]]; then
  ok "Management UI: http://${VM_IP}:3000"
  ok "Default login: admin / admin  (change immediately)"
  ok "Self-update: runs every 30 min via cron, or use the Dashboard button"
fi
echo ""
