#!/usr/bin/env bash
# =============================================================================
# RideStatus — Proxmox Deploy Script
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates RideStatus Server VM and/or Ansible Controller VM.
#
# Flow:
#   1. dialog TUI collects ALL configuration up front.
#   2. VMs are created and bootstrap scripts run non-interactively via env vars.
#   3. The only remaining interactive step is the GitHub deploy key
#      "Press Enter" — which works reliably since it runs with a direct TTY.
#
# Usage: bash /tmp/deploy.sh   (download first, then run — dialog needs TTY)
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
[[ $EUID -eq 0 ]] || die "This script must be run as root."
command -v pvesh     >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v pvesm     >/dev/null 2>&1 || die "pvesm not found — is this a Proxmox host?"
command -v qm        >/dev/null 2>&1 || die "qm not found — is this a Proxmox host?"
command -v dialog    >/dev/null 2>&1 || die "dialog not found (apt install dialog)"
command -v ssh       >/dev/null 2>&1 || die "ssh not found"
command -v scp       >/dev/null 2>&1 || die "scp not found"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
command -v python3   >/dev/null 2>&1 || die "python3 not found"
command -v curl      >/dev/null 2>&1 || die "curl not found"
command -v jq        >/dev/null 2>&1 || die "jq not found (apt install jq)"

PROXMOX_NODE=$(hostname)
ADMIN_KEY_PATH="/root/ridestatus-admin-key"
BOOTSTRAP_BASE_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap"
ANSIBLE_KEY_SERVER_PORT=9876

# Temp file for dialog output — avoids $() subshell which loses the TTY
_DLG_TMP=$(mktemp /tmp/ridestatus-dlg-XXXXXX)

# =============================================================================
# dialog helpers
# All use $_DLG_TMP instead of $() to preserve the controlling terminal.
# =============================================================================
WT_H=20; WT_W=72

wt_msg() {
  dialog --title "RideStatus Deploy" --msgbox "$1" $WT_H $WT_W
}

wt_input() {
  local _varname=$1 _prompt=$2 _default=${3:-}
  dialog --title "RideStatus Deploy" --inputbox "$_prompt" 10 $WT_W "$_default" \
    2>"$_DLG_TMP" || true
  local _val
  _val=$(cat "$_DLG_TMP")
  [[ -z "$_val" && -n "$_default" ]] && _val="$_default"
  printf -v "$_varname" '%s' "$_val"
}

wt_password() {
  local _varname=$1 _prompt=$2
  dialog --title "RideStatus Deploy" --passwordbox "$_prompt" 10 $WT_W \
    2>"$_DLG_TMP" || true
  local _val
  _val=$(cat "$_DLG_TMP")
  printf -v "$_varname" '%s' "$_val"
}

wt_menu() {
  local _varname=$1 _prompt=$2; shift 2
  dialog --title "RideStatus Deploy" --menu "$_prompt" $WT_H $WT_W 8 "$@" \
    2>"$_DLG_TMP" || true
  local _val
  _val=$(cat "$_DLG_TMP")
  printf -v "$_varname" '%s' "$_val"
}

wt_yesno() {
  dialog --title "RideStatus Deploy" --yesno "$1" 10 $WT_W
}

# =============================================================================
# Detect storage
# =============================================================================
storage_json() { pvesh get /storage --output-format json 2>/dev/null || echo '[]'; }

find_lvm_storage() {
  if pvesm status --storage "local-lvm" &>/dev/null 2>&1; then echo "local-lvm"; return; fi
  storage_json | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    if 'images' in s.get('content',''):
        print(s.get('storage','')); break
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
        print(s.get('storage','')); sys.exit(0)
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
  local new="${cur:+${cur},}${ctype}"
  pvesm set "$storage" --content "$new" || die "Failed to enable ${ctype} on ${storage}"
}

DISK_STORAGE=$(find_lvm_storage)
[[ -n "$DISK_STORAGE" ]] || die "No images-capable storage found"
CI_STORAGE=$(find_dir_storage)
[[ -n "$CI_STORAGE" ]] || die "No directory-type storage found"
ensure_content_type "$CI_STORAGE" "images"
ensure_content_type "$CI_STORAGE" "snippets"
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# =============================================================================
# Detect USB NICs
# =============================================================================
declare -A USB_NIC_MAC=()
declare -A USB_NIC_BUS=()
declare -A USB_NIC_VP=()
declare -a FREE_USB_NICS=()
declare -A USB_BUS_CLAIMED=()

_detect_usb_nics() {
  mapfile -t ALL_IFACES < <(
    ip -o link show | awk -F': ' '{print $2}' \
    | grep -v '^lo$' | grep -v '@' \
    | grep -Ev '^(vmbr|tap|veth|fwbr|fwpr|fwln)'
  )

  for iface in "${ALL_IFACES[@]}"; do
    local syspath
    syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
    [[ -z "$syspath" ]] && continue
    echo "$syspath" | grep -q '/usb' || continue

    local usb_dir vp=""
    usb_dir=$(echo "$syspath" | sed 's|/[^/]*$||')
    while [[ "$usb_dir" =~ /usb ]]; do
      local v p
      v=$(cat "${usb_dir}/idVendor"  2>/dev/null || true)
      p=$(cat "${usb_dir}/idProduct" 2>/dev/null || true)
      if [[ -n "$v" && -n "$p" ]]; then vp="${v}:${p}"; break; fi
      usb_dir=$(dirname "$usb_dir")
    done
    [[ -z "$vp" ]] && continue

    local bp
    bp=$(echo "$syspath" | grep -oP 'usb\d+/\K[\d]+-[\d.]+(?=/)' | head -1 || true)
    [[ -z "$bp" ]] && continue

    USB_NIC_MAC["$iface"]=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
    USB_NIC_BUS["$iface"]="$bp"
    USB_NIC_VP["$iface"]="$vp"
  done

  mapfile -t VMIDS < <(
    pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null \
    | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true
  )
  for vmid in "${VMIDS[@]}"; do
    local cfg
    cfg=$(pvesh get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" --output-format json 2>/dev/null || true)
    while IFS= read -r entry; do
      local raw
      raw=$(echo "$entry" | grep -o 'host=[^ ",]*' | sed 's/host=//' || true)
      [[ -z "$raw" ]] && continue
      echo "$raw" | grep -qP '^\d+-[\d.]+$' && USB_BUS_CLAIMED["$raw"]="$vmid"
    done < <(echo "$cfg" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done

  for iface in "${!USB_NIC_VP[@]}"; do
    local bp="${USB_NIC_BUS[$iface]}"
    [[ -z "${USB_BUS_CLAIMED[$bp]:-}" ]] && FREE_USB_NICS+=("$iface")
  done
}

_detect_usb_nics

mapfile -t EXISTING_BRIDGES < <(
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' | grep -v '@' || true
)

# =============================================================================
# Temporary deploy keypair
# =============================================================================
DEPLOY_KEY_DIR=$(mktemp -d /tmp/ridestatus-deploy-XXXXXX)
DEPLOY_KEY="${DEPLOY_KEY_DIR}/id_ed25519"
DEPLOY_PUBKEY="${DEPLOY_KEY}.pub"
ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "ridestatus-deploy-temp" -q
DEPLOY_PUBKEY_CONTENT=$(cat "$DEPLOY_PUBKEY")

cleanup() {
  rm -rf "$DEPLOY_KEY_DIR"
  rm -f "$_DLG_TMP"
  rm -f "${SNIPPET_DIR}/ridestatus-userdata-"*.yaml 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# Welcome
# =============================================================================
wt_msg "Welcome to RideStatus Proxmox Deploy

Host: ${PROXMOX_NODE}
Storage: OS=${DISK_STORAGE}  CI=${CI_STORAGE}

This wizard collects all settings before making any changes.
Use Tab to navigate, Space/Enter to select."

# =============================================================================
# VM selection
# =============================================================================
CREATE_ANSIBLE=false
CREATE_SERVER=false
VM_SEL=""
wt_menu VM_SEL "Which VMs should be created on this host?" \
  "both"    "Ansible Controller + RideStatus Server (recommended)" \
  "ansible" "Ansible Controller only" \
  "server"  "RideStatus Server only"

[[ "$VM_SEL" == "both" || "$VM_SEL" == "ansible" ]] && CREATE_ANSIBLE=true
[[ "$VM_SEL" == "both" || "$VM_SEL" == "server"  ]] && CREATE_SERVER=true

# =============================================================================
# NIC configuration helper
# =============================================================================
declare -a NIC_TYPES=() NIC_LABELS=() NIC_BRIDGES=() NIC_USBS=()
declare -a NIC_MACS=() NIC_IPS=() NIC_GWS=() NIC_DNSS=() NIC_DR=()
_session_claimed=()

collect_nics() {
  local vm_label=$1
  NIC_TYPES=(); NIC_LABELS=(); NIC_BRIDGES=(); NIC_USBS=()
  NIC_MACS=(); NIC_IPS=(); NIC_GWS=(); NIC_DNSS=(); NIC_DR=()
  local dr_assigned=false
  local nic_num=1

  while true; do
    local net_label=""
    wt_input net_label "${vm_label} vNIC${nic_num} — Network label:" "Ride Control"
    [[ -z "$net_label" ]] && net_label="Network ${nic_num}"

    local available_usb=()
    for u in "${FREE_USB_NICS[@]:-}"; do
      local skip=false
      for c in "${_session_claimed[@]:-}"; do [[ "$c" == "$u" ]] && skip=true && break; done
      $skip || available_usb+=("$u")
    done

    local nic_type=""
    if [[ ${#available_usb[@]} -gt 0 ]]; then
      local conn_items=("bridge" "Shared bridge (Proxmox-assigned MAC)")
      for u in "${available_usb[@]}"; do
        conn_items+=("usb:${u}" "USB passthrough: ${u}  MAC=${USB_NIC_MAC[$u]}  bus=${USB_NIC_BUS[$u]}")
      done
      wt_menu nic_type "${vm_label} vNIC${nic_num} (${net_label}) — Connection type:" "${conn_items[@]}"
    else
      nic_type="bridge"
      wt_msg "No free USB NICs available — vNIC${nic_num} will use a bridge."
    fi

    local bridge_name="" usb_iface="" nic_mac=""

    if [[ "$nic_type" == "bridge" ]]; then
      local b_items=()
      for b in "${EXISTING_BRIDGES[@]:-}"; do b_items+=("$b" "Existing bridge"); done
      b_items+=("new" "Create a new bridge")
      local b_sel=""
      wt_menu b_sel "${vm_label} vNIC${nic_num} — Select bridge:" "${b_items[@]}"
      if [[ "$b_sel" == "new" ]]; then
        local next_num=0
        while ip link show "vmbr${next_num}" &>/dev/null 2>&1; do next_num=$(( next_num+1 )); done
        wt_input bridge_name "New bridge name:" "vmbr${next_num}"
        local phys_items=()
        for iface in $(ip -o link show | awk -F': ' '{print $2}' \
            | grep -Ev '^(lo|vmbr|tap|veth|fwbr|fwpr|fwln)' | grep -v '@'); do
          phys_items+=("$iface" "$(cat /sys/class/net/${iface}/address 2>/dev/null || echo unknown)")
        done
        local phys_sel=""
        wt_menu phys_sel "Physical NIC for ${bridge_name}:" "${phys_items[@]}"
        if ! ip link show "$bridge_name" &>/dev/null 2>&1; then
          { echo "auto ${bridge_name}"
            echo "iface ${bridge_name} inet manual"
            echo "  bridge_ports ${phys_sel}"
            echo "  bridge_stp off"
            echo "  bridge_fd 0"
          } > "/etc/network/interfaces.d/${bridge_name}"
          ifup "$bridge_name" 2>/dev/null || true
        fi
        EXISTING_BRIDGES+=("$bridge_name")
      else
        bridge_name="$b_sel"
      fi
      nic_mac="virtio"
    else
      usb_iface="${nic_type#usb:}"
      nic_type="usb"
      nic_mac="${USB_NIC_MAC[$usb_iface]:-unknown}"
      _session_claimed+=("$usb_iface")
    fi

    local ip_cidr=""
    while true; do
      wt_input ip_cidr "${vm_label} vNIC${nic_num} (${net_label}) — Static IP/prefix:" ""
      [[ "$ip_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
      wt_msg "Invalid format. Enter IP/prefix like 10.250.5.101/19"
    done

    local gw="" dns="8.8.8.8" is_dr="no"
    if ! $dr_assigned; then
      if wt_yesno "Use vNIC${nic_num} (${net_label}, ${ip_cidr}) as the default route for ${vm_label}?

This NIC handles internet traffic (updates, alerts, weather)."; then
        is_dr="yes"
        dr_assigned=true
        wt_input gw "Default gateway:" ""
      fi
    fi
    wt_input dns "DNS server for vNIC${nic_num}:" "8.8.8.8"

    NIC_TYPES+=("$nic_type");    NIC_LABELS+=("$net_label")
    NIC_BRIDGES+=("$bridge_name"); NIC_USBS+=("$usb_iface")
    NIC_MACS+=("$nic_mac");      NIC_IPS+=("$ip_cidr")
    NIC_GWS+=("$gw");            NIC_DNSS+=("$dns")
    NIC_DR+=("$is_dr")

    wt_yesno "Add another NIC to ${vm_label}?" || break
    nic_num=$(( nic_num + 1 ))
  done
}

# =============================================================================
# Ansible VM config
# =============================================================================
ANSIBLE_VMID="" ANSIBLE_RAM="2" ANSIBLE_CORES="2" ANSIBLE_DISK="20" ANSIBLE_HOST="ridestatus-ansible"
declare -a A_NIC_TYPES=() A_NIC_LABELS=() A_NIC_BRIDGES=() A_NIC_USBS=()
declare -a A_NIC_MACS=() A_NIC_IPS=() A_NIC_GWS=() A_NIC_DNSS=() A_NIC_DR=()

if $CREATE_ANSIBLE; then
  next_vmid=300
  while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${next_vmid}/status" &>/dev/null 2>&1; do
    next_vmid=$(( next_vmid + 1 ))
  done
  wt_input ANSIBLE_VMID "Ansible Controller VM ID:"  "$next_vmid"
  wt_input ANSIBLE_RAM   "Ansible VM RAM (GB):"       "2"
  wt_input ANSIBLE_CORES "Ansible VM CPU cores:"      "2"
  wt_input ANSIBLE_DISK  "Ansible VM disk (GB):"      "20"
  wt_input ANSIBLE_HOST  "Ansible VM hostname:"       "ridestatus-ansible"

  collect_nics "Ansible VM"
  A_NIC_TYPES=("${NIC_TYPES[@]}");    A_NIC_LABELS=("${NIC_LABELS[@]}")
  A_NIC_BRIDGES=("${NIC_BRIDGES[@]}"); A_NIC_USBS=("${NIC_USBS[@]}")
  A_NIC_MACS=("${NIC_MACS[@]}");      A_NIC_IPS=("${NIC_IPS[@]}")
  A_NIC_GWS=("${NIC_GWS[@]}");        A_NIC_DNSS=("${NIC_DNSS[@]}")
  A_NIC_DR=("${NIC_DR[@]}")
fi

# =============================================================================
# Server VM config
# =============================================================================
SERVER_VMID="" SERVER_RAM="4" SERVER_CORES="2" SERVER_DISK="64" SERVER_HOST="ridestatus-server"
declare -a S_NIC_TYPES=() S_NIC_LABELS=() S_NIC_BRIDGES=() S_NIC_USBS=()
declare -a S_NIC_MACS=() S_NIC_IPS=() S_NIC_GWS=() S_NIC_DNSS=() S_NIC_DR=()
SERVER_DR_IDX=-1

if $CREATE_SERVER; then
  next_vmid=300
  while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${next_vmid}/status" &>/dev/null 2>&1; do
    next_vmid=$(( next_vmid + 1 ))
  done
  wt_input SERVER_VMID   "RideStatus Server VM ID:"   "$next_vmid"
  wt_input SERVER_RAM    "Server VM RAM (GB):"         "4"
  wt_input SERVER_CORES  "Server VM CPU cores:"        "2"
  wt_input SERVER_DISK   "Server VM disk (GB):"        "64"
  wt_input SERVER_HOST   "Server VM hostname:"         "ridestatus-server"

  collect_nics "Server VM"
  S_NIC_TYPES=("${NIC_TYPES[@]}");    S_NIC_LABELS=("${NIC_LABELS[@]}")
  S_NIC_BRIDGES=("${NIC_BRIDGES[@]}"); S_NIC_USBS=("${NIC_USBS[@]}")
  S_NIC_MACS=("${NIC_MACS[@]}");      S_NIC_IPS=("${NIC_IPS[@]}")
  S_NIC_GWS=("${NIC_GWS[@]}");        S_NIC_DNSS=("${NIC_DNSS[@]}")
  S_NIC_DR=("${NIC_DR[@]}")
  for i in "${!S_NIC_DR[@]}"; do
    [[ "${S_NIC_DR[$i]}" == "yes" ]] && SERVER_DR_IDX=$i && break
  done
fi

# =============================================================================
# Park configuration (server only)
# =============================================================================
PARK_NAME="My Park" PARK_TZ="America/Chicago"
WEATHER_API_KEY="" WEATHER_ZIP="00000"
ALERT_EMAIL="" ALERT_SMS=""
SMTP_HOST="" SMTP_PORT="587" SMTP_USER="" SMTP_PASS=""

if $CREATE_SERVER; then
  wt_input PARK_NAME       "Park name:"                              "My Park"
  wt_input PARK_TZ         "Timezone (e.g. America/Chicago):"        "America/Chicago"
  wt_input WEATHER_API_KEY "WeatherAPI.com key (blank to skip):"     ""
  wt_input WEATHER_ZIP     "Weather ZIP code:"                       "00000"
  wt_input ALERT_EMAIL     "Alert email address (optional):"         ""
  wt_input ALERT_SMS       "Alert SMS address (optional):"           ""
  wt_input SMTP_HOST       "SMTP host (optional):"                   ""
  wt_input SMTP_PORT       "SMTP port:"                              "587"
  wt_input SMTP_USER       "SMTP username (optional):"               ""
  if [[ -n "$SMTP_HOST" ]]; then
    wt_password SMTP_PASS "SMTP password:"
  fi
fi

# =============================================================================
# GitHub access
# =============================================================================
GITHUB_AUTH_METHOD="deploy_key"
GITHUB_USER="" GITHUB_PAT=""

wt_menu GITHUB_AUTH_METHOD "GitHub access for private repos:" \
  "deploy_key" "Deploy key — SSH key scoped to RideStatus repos (recommended)" \
  "pat"        "Personal access token (PAT) — simpler, enter once"

if [[ "$GITHUB_AUTH_METHOD" == "pat" ]]; then
  wt_input    GITHUB_USER "GitHub username:" ""
  wt_password GITHUB_PAT  "GitHub PAT:"
fi

# =============================================================================
# Admin SSH key
# =============================================================================
ADMIN_SSH_PUBKEY="" ADMIN_GENERATED=false

if [[ -f "${ADMIN_KEY_PATH}.pub" ]]; then
  ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
  wt_msg "Using existing admin SSH key:\n${ADMIN_KEY_PATH}"
else
  wt_input ADMIN_SSH_PUBKEY "Paste SSH public key (blank to auto-generate):" ""
  if [[ -z "$ADMIN_SSH_PUBKEY" ]]; then
    ssh-keygen -t ed25519 -f "$ADMIN_KEY_PATH" -N "" -C "ridestatus-admin" -q
    ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
    ADMIN_GENERATED=true
    wt_msg "Admin SSH key generated:\n${ADMIN_KEY_PATH}\n\nCopy the private key to your PC after deployment."
  fi
fi

# =============================================================================
# Summary + confirm
# =============================================================================
_summary=""
if $CREATE_ANSIBLE; then
  _summary+="ANSIBLE CONTROLLER  (VM ${ANSIBLE_VMID})\n"
  _summary+="  ${ANSIBLE_HOST}  RAM:${ANSIBLE_RAM}GB  CPU:${ANSIBLE_CORES}  Disk:${ANSIBLE_DISK}GB\n"
  for i in "${!A_NIC_TYPES[@]}"; do
    _c="" _d=""
    [[ "${A_NIC_TYPES[$i]}" == "bridge" ]] && _c="bridge=${A_NIC_BRIDGES[$i]}" \
      || _c="USB=${A_NIC_USBS[$i]}(${USB_NIC_BUS[${A_NIC_USBS[$i]}]:-?})"
    [[ "${A_NIC_DR[$i]}" == "yes" ]] && _d=" [GW=${A_NIC_GWS[$i]}]"
    _summary+="  vNIC$((i+1)): ${A_NIC_LABELS[$i]}  ${A_NIC_IPS[$i]}  ${_c}${_d}\n"
  done
  _summary+="\n"
fi
if $CREATE_SERVER; then
  _summary+="RIDESTATUS SERVER  (VM ${SERVER_VMID})\n"
  _summary+="  ${SERVER_HOST}  RAM:${SERVER_RAM}GB  CPU:${SERVER_CORES}  Disk:${SERVER_DISK}GB\n"
  for i in "${!S_NIC_TYPES[@]}"; do
    _c="" _d=""
    [[ "${S_NIC_TYPES[$i]}" == "bridge" ]] && _c="bridge=${S_NIC_BRIDGES[$i]}" \
      || _c="USB=${S_NIC_USBS[$i]}(${USB_NIC_BUS[${S_NIC_USBS[$i]}]:-?})"
    [[ "${S_NIC_DR[$i]}" == "yes" ]] && _d=" [GW=${S_NIC_GWS[$i]}]"
    _summary+="  vNIC$((i+1)): ${S_NIC_LABELS[$i]}  ${S_NIC_IPS[$i]}  ${_c}${_d}\n"
  done
  _summary+="  Park: ${PARK_NAME}  TZ: ${PARK_TZ}\n\n"
fi
_summary+="GitHub: ${GITHUB_AUTH_METHOD}\n"
_summary+="Storage: OS=${DISK_STORAGE}  CI=${CI_STORAGE}"

wt_yesno "Review configuration:\n\n${_summary}\n\nProceed with deployment?" \
  || { echo "Aborted."; exit 0; }

# =============================================================================
# SSH helpers
# =============================================================================
iface_mac() { cat "/sys/class/net/${1}/address" 2>/dev/null || echo "unknown"; }
purge_known_host() {
  [[ -f /root/.ssh/known_hosts ]] && ssh-keygen -f /root/.ssh/known_hosts -R "$1" &>/dev/null || true
}
first_ip() { local -n _f=$1; echo "${_f[0]%%/*}"; }

# SSH using deploy key first, admin key as fallback
_ssh_opts() { echo "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes"; }

deploy_ssh() {
  local tty_flag=false
  [[ "${1:-}" == "-t" ]] && tty_flag=true && shift
  local ip=$1; shift
  local extra_opts=""
  $tty_flag && extra_opts="-t -t" || extra_opts="-o BatchMode=yes"

  # Try deploy key first, then admin key
  for key in "$DEPLOY_KEY" "$ADMIN_KEY_PATH"; do
    [[ -f "$key" ]] || continue
    # shellcheck disable=SC2086
    if ssh -i "$key" $(_ssh_opts) $extra_opts "ridestatus@${ip}" "$@" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

wait_for_ssh() {
  local ip=$1 elapsed=0
  info "Waiting for SSH on ${ip}..."
  while (( elapsed < 300 )); do
    deploy_ssh "$ip" 'exit 0' && { ok "SSH ready on ${ip}"; return 0; }
    sleep 5; elapsed=$(( elapsed+5 )); echo -n "."
  done
  echo ""; die "Timed out waiting for SSH on ${ip}"
}

wait_for_agent() {
  local vmid=$1 elapsed=0
  info "Waiting for guest agent on VM ${vmid}..."
  while (( elapsed < 900 )); do
    qm guest cmd "$vmid" ping &>/dev/null 2>&1 && { ok "Guest agent ready"; return 0; }
    sleep 10; elapsed=$(( elapsed+10 ))
    (( elapsed % 60 == 0 )) && echo " ${elapsed}s" || echo -n "."
  done
  echo ""; die "Timed out waiting for guest agent on VM ${vmid}"
}

# =============================================================================
# VM creation
# =============================================================================
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"

ensure_ubuntu_image() {
  if [[ -f "$UBUNTU_IMG_PATH" ]]; then
    info "Ubuntu 24.04 cloud image already cached"
  else
    info "Downloading Ubuntu 24.04 cloud image..."
    mkdir -p "$(dirname "$UBUNTU_IMG_PATH")"
    wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL" \
      || die "Failed to download Ubuntu image"
    ok "Image downloaded"
  fi
}

write_snippet() {
  local vmid=$1 deploy_key=$2 admin_key=$3
  local f="${SNIPPET_DIR}/ridestatus-userdata-${vmid}.yaml"
  cat > "$f" <<YAML
#cloud-config
users:
  - name: ridestatus
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${deploy_key}
      - ${admin_key}
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
YAML
  echo "$f"
}

create_vm() {
  local vmid=$1 hostname=$2 ram_gb=$3 cores=$4 disk_gb=$5
  local -n cv_type=$6 cv_bridge=$7 cv_usb=$8 cv_ip=$9 cv_gw=${10} cv_dns=${11}

  info "Creating VM ${vmid} (${hostname})..."
  local ram_mb=$(( ram_gb * 1024 ))

  qm create "$vmid" --name "$hostname" --memory "$ram_mb" --cores "$cores" \
    --cpu cputype=host --ostype l26 --agent enabled=1 --serial0 socket --vga serial0

  local img_copy="/tmp/ridestatus-vm${vmid}.img"
  cp "$UBUNTU_IMG_PATH" "$img_copy"
  qm importdisk "$vmid" "$img_copy" "$DISK_STORAGE" --format qcow2
  rm -f "$img_copy"

  qm set "$vmid" --scsihw virtio-scsi-pci \
    --scsi0 "${DISK_STORAGE}:vm-${vmid}-disk-0,discard=on" --boot order=scsi0
  qm resize "$vmid" scsi0 "${disk_gb}G"

  local br_idx=0 usb_slot=0
  for i in "${!cv_type[@]}"; do
    if [[ "${cv_type[$i]}" == "bridge" ]]; then
      qm set "$vmid" --net${br_idx} "virtio,bridge=${cv_bridge[$i]}"
      br_idx=$(( br_idx+1 ))
    else
      local bp="${USB_NIC_BUS[${cv_usb[$i]}]:-}"
      if [[ -n "$bp" ]]; then
        qm set "$vmid" --usb${usb_slot} "host=${bp}"
      else
        qm set "$vmid" --usb${usb_slot} "host=${USB_NIC_VP[${cv_usb[$i]}]}"
      fi
      usb_slot=$(( usb_slot+1 ))
    fi
  done

  qm set "$vmid" --ide2 "${CI_STORAGE}:cloudinit"

  local ipcfg_idx=0
  for i in "${!cv_type[@]}"; do
    [[ "${cv_type[$i]}" != "bridge" ]] && continue
    local gw_part=""
    [[ -n "${cv_gw[$i]:-}" ]] && gw_part=",gw=${cv_gw[$i]}"
    qm set "$vmid" --ipconfig${ipcfg_idx} "ip=${cv_ip[$i]}${gw_part}"
    ipcfg_idx=$(( ipcfg_idx+1 ))
  done

  qm set "$vmid" --nameserver "${cv_dns[0]:-8.8.8.8}" --ciupgrade 0

  local snip
  snip=$(write_snippet "$vmid" "$DEPLOY_PUBKEY_CONTENT" "$ADMIN_SSH_PUBKEY")
  qm set "$vmid" --cicustom "user=${CI_STORAGE}:snippets/$(basename "$snip")"
  qm cloudinit update "$vmid"
  ok "VM ${vmid} configured"
}

fix_usb_nic_names() {
  local vmid=$1
  local -n fnn_type=$2 fnn_usb=$3 fnn_ip=$4

  local has_usb=false
  for t in "${fnn_type[@]}"; do [[ "$t" == "usb" ]] && has_usb=true && break; done
  $has_usb || return 0

  info "Querying guest agent for NIC names in VM ${vmid}..."
  local ga_json
  ga_json=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)
  [[ -z "$ga_json" ]] && { warn "No NIC data from guest agent"; return 0; }

  declare -A ga_map=()
  while IFS= read -r line; do
    local n m
    n=$(echo "$line" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('name',''))" 2>/dev/null || true)
    m=$(echo "$line" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('hardware-address','').lower())" 2>/dev/null || true)
    [[ -n "$n" && -n "$m" ]] && ga_map["$m"]="$n"
  done < <(echo "$ga_json" | python3 -c \
    "import sys,json;[print(json.dumps(x)) for x in json.load(sys.stdin).get('result',[])]" 2>/dev/null || true)

  [[ ${#ga_map[@]} -eq 0 ]] && { warn "Guest agent returned no NIC data"; return 0; }

  local usb_slot=0
  declare -A real_names=()
  local needs_fix=false
  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" != "usb" ]] && continue
    local hm; hm=$(iface_mac "${fnn_usb[$i]}" | tr '[:upper:]' '[:lower:]')
    local rn="${ga_map[$hm]:-}" ph="usb-placeholder-${usb_slot}"
    if [[ -n "$rn" && "$rn" != "$ph" ]]; then real_names["$ph"]="$rn"; needs_fix=true; fi
    usb_slot=$(( usb_slot+1 ))
  done

  $needs_fix || { ok "NIC names correct"; return 0; }

  local ssh_ip=""
  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" == "bridge" ]] && { ssh_ip="${fnn_ip[$i]%%/*}"; break; }
  done
  [[ -z "$ssh_ip" ]] && ssh_ip="${fnn_ip[0]%%/*}"

  local sed_args=()
  for ph in "${!real_names[@]}"; do sed_args+=(-e "s/${ph}/${real_names[$ph]}/g"); done

  deploy_ssh "$ssh_ip" "
    set -e
    f=\$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    [[ -z \"\$f\" ]] && exit 1
    sudo sed -i ${sed_args[*]} \"\$f\"
    sudo netplan apply
  " && ok "Netplan patched" || warn "Netplan patch failed — check USB NIC names manually"
}

# =============================================================================
# Bootstrap runner
# Writes env file locally then SCPs it — avoids SSH key timing/quoting issues.
# =============================================================================
run_bootstrap() {
  local ip=$1 script=$2 env_vars=${3:-}
  info "Running ${script} on ${ip}..."

  local remote_script="/tmp/ridestatus-bs-$$.sh"
  local remote_env="/tmp/ridestatus-env-$$.sh"
  local local_script local_env
  local_script=$(mktemp /tmp/ridestatus-local-script-XXXXXX.sh)
  local_env=$(mktemp /tmp/ridestatus-local-env-XXXXXX.sh)

  # Download bootstrap script locally first
  curl -fsSL -H "Cache-Control: no-cache" \
    "${BOOTSTRAP_BASE_URL}/${script}?$(date +%s)" -o "$local_script" \
    || { err "Failed to download ${script}"; rm -f "$local_script" "$local_env"; return 1; }

  # Write env file locally (no quoting issues at all)
  if [[ -n "$env_vars" ]]; then
    printf '%s\n' "$env_vars" | sed 's/^/export /' > "$local_env"
  fi

  # SCP both files to the VM using available key
  local scp_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o IdentitiesOnly=yes -o BatchMode=yes"
  local scp_ok=false
  for key in "$DEPLOY_KEY" "$ADMIN_KEY_PATH"; do
    [[ -f "$key" ]] || continue
    # shellcheck disable=SC2086
    if scp $scp_opts -i "$key" "$local_script" "ridestatus@${ip}:${remote_script}" 2>/dev/null; then
      if [[ -n "$env_vars" ]]; then
        # shellcheck disable=SC2086
        scp $scp_opts -i "$key" "$local_env" "ridestatus@${ip}:${remote_env}" 2>/dev/null || true
      fi
      scp_ok=true
      break
    fi
  done
  rm -f "$local_script" "$local_env"

  if ! $scp_ok; then
    err "Failed to SCP files to ${ip}"
    return 1
  fi

  # Execute with TTY
  if [[ -n "$env_vars" ]]; then
    deploy_ssh -t "$ip" sudo bash -c \
      ". '${remote_env}' && bash '${remote_script}'; rm -f '${remote_script}' '${remote_env}'"
  else
    deploy_ssh -t "$ip" sudo bash "${remote_script}"
  fi
  local rc=$?

  deploy_ssh "$ip" "rm -f '${remote_script}' '${remote_env}'" 2>/dev/null || true

  if [[ $rc -ne 0 ]]; then
    err "Bootstrap failed for ${script} on ${ip} (exit ${rc})"
    err "Retry: ssh -i ${ADMIN_KEY_PATH} ridestatus@${ip}"
    return 1
  fi
  ok "${script} completed on ${ip}"
}

# =============================================================================
# Build env strings for bootstrap scripts
# =============================================================================
_build_ansible_env() {
  local extra="${1:-}"
  local env="RS_GITHUB_AUTH=${GITHUB_AUTH_METHOD}"
  if [[ "$GITHUB_AUTH_METHOD" == "pat" ]]; then
    env+=$'\n'"RS_GITHUB_USER=${GITHUB_USER}"
    env+=$'\n'"RS_GITHUB_PAT=${GITHUB_PAT}"
  fi
  [[ -n "$extra" ]] && env+=$'\n'"${extra}"
  echo "$env"
}

_build_server_env() {
  local extra="${1:-}"
  local api_key bootstrap_token
  api_key=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  bootstrap_token=$(python3 -c "import secrets,string; \
    print(''.join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(8)))")

  local dr_iface="ens18"
  [[ $SERVER_DR_IDX -ge 0 ]] && dr_iface="net${SERVER_DR_IDX}"

  local env="RS_GITHUB_AUTH=${GITHUB_AUTH_METHOD}"
  if [[ "$GITHUB_AUTH_METHOD" == "pat" ]]; then
    env+=$'\n'"RS_GITHUB_USER=${GITHUB_USER}"
    env+=$'\n'"RS_GITHUB_PAT=${GITHUB_PAT}"
  fi
  env+=$'\n'"RS_PARK_NAME=${PARK_NAME}"
  env+=$'\n'"RS_PARK_TZ=${PARK_TZ}"
  env+=$'\n'"RS_API_KEY=${api_key}"
  env+=$'\n'"RS_BOOTSTRAP_TOKEN=${bootstrap_token}"
  env+=$'\n'"RS_WEATHER_API_KEY=${WEATHER_API_KEY}"
  env+=$'\n'"RS_WEATHER_ZIP=${WEATHER_ZIP}"
  env+=$'\n'"RS_ALERT_EMAIL=${ALERT_EMAIL}"
  env+=$'\n'"RS_ALERT_SMS=${ALERT_SMS}"
  env+=$'\n'"RS_SMTP_HOST=${SMTP_HOST}"
  env+=$'\n'"RS_SMTP_PORT=${SMTP_PORT}"
  env+=$'\n'"RS_SMTP_USER=${SMTP_USER}"
  env+=$'\n'"RS_SMTP_PASS=${SMTP_PASS}"
  env+=$'\n'"RS_DEFAULT_ROUTE_IFACE=${dr_iface}"
  [[ -n "$extra" ]] && env+=$'\n'"${extra}"
  echo "$env"
}

# =============================================================================
# Create VMs
# =============================================================================
header "Creating VMs"
ensure_ubuntu_image

if $CREATE_ANSIBLE; then
  header "Creating Ansible Controller VM (${ANSIBLE_VMID})"
  create_vm "$ANSIBLE_VMID" "$ANSIBLE_HOST" "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    A_NIC_TYPES A_NIC_BRIDGES A_NIC_USBS A_NIC_IPS A_NIC_GWS A_NIC_DNSS
  qm start "$ANSIBLE_VMID"
  purge_known_host "$(first_ip A_NIC_IPS)"
  ok "VM ${ANSIBLE_VMID} started"
fi

if $CREATE_SERVER; then
  header "Creating RideStatus Server VM (${SERVER_VMID})"
  create_vm "$SERVER_VMID" "$SERVER_HOST" "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    S_NIC_TYPES S_NIC_BRIDGES S_NIC_USBS S_NIC_IPS S_NIC_GWS S_NIC_DNSS
  qm start "$SERVER_VMID"
  purge_known_host "$(first_ip S_NIC_IPS)"
  ok "VM ${SERVER_VMID} started"
fi

ANSIBLE_IP="" SERVER_IP=""

if $CREATE_ANSIBLE; then
  wait_for_agent "$ANSIBLE_VMID"
  fix_usb_nic_names "$ANSIBLE_VMID" A_NIC_TYPES A_NIC_USBS A_NIC_IPS
  ANSIBLE_IP=$(first_ip A_NIC_IPS)
  wait_for_ssh "$ANSIBLE_IP"
fi

if $CREATE_SERVER; then
  wait_for_agent "$SERVER_VMID"
  fix_usb_nic_names "$SERVER_VMID" S_NIC_TYPES S_NIC_USBS S_NIC_IPS
  SERVER_IP=$(first_ip S_NIC_IPS)
  wait_for_ssh "$SERVER_IP"
fi

# =============================================================================
# Bootstrap
# =============================================================================
if $CREATE_ANSIBLE && $CREATE_SERVER; then
  ansible_key_url="http://${ANSIBLE_IP}:${ANSIBLE_KEY_SERVER_PORT}/ansible_ridestatus.pub"
  server_env=""
  server_env=$(_build_server_env \
    "RS_ANSIBLE_KEY_URL=${ansible_key_url}"$'\n'"RS_ANSIBLE_VM_HOST=${ANSIBLE_IP}")
  ansible_env=""
  ansible_env=$(_build_ansible_env)

  info "Starting server.sh in background..."
  ( run_bootstrap "$SERVER_IP" "server.sh" "$server_env" || true ) &
  SERVER_BS_PID=$!
  run_bootstrap "$ANSIBLE_IP" "ansible.sh" "$ansible_env" || true
  info "Waiting for server.sh..."
  wait "$SERVER_BS_PID" 2>/dev/null || true

elif $CREATE_ANSIBLE; then
  run_bootstrap "$ANSIBLE_IP" "ansible.sh" "$(_build_ansible_env)" || true

elif $CREATE_SERVER; then
  run_bootstrap "$SERVER_IP" "server.sh" "$(_build_server_env)" || true
fi

# =============================================================================
# Done
# =============================================================================
header "Deployment Complete"
$CREATE_ANSIBLE && ok "Ansible Controller VM ${ANSIBLE_VMID} (${ANSIBLE_HOST}) — ${ANSIBLE_IP}"
$CREATE_SERVER  && ok "RideStatus Server VM ${SERVER_VMID} (${SERVER_HOST}) — ${SERVER_IP}"

if $ADMIN_GENERATED; then
  echo ""
  warn "*** IMPORTANT: Copy admin SSH private key off this Proxmox host ***"
  warn "    ${ADMIN_KEY_PATH}"
fi
echo ""
