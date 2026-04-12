#!/usr/bin/env bash
# =============================================================================
# RideStatus — Proxmox Deploy Script
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates RideStatus Server VM and/or Ansible Controller VM.
#
# SSH approach:
#   A temporary ed25519 keypair is generated at startup and injected into
#   cloud-init alongside the tech's admin key. The script uses the temp key
#   for bootstrap SSH connections, falling back to the admin key if needed
#   (e.g. when re-running against VMs already booted from a prior run).
#   The fallback only triggers on SSH auth failure (exit 255), not on remote
#   script errors — preventing bootstrap scripts from running twice.
#   The temp key is deleted on exit.
#
# Cloud-init approach:
#   Uses --cicustom user= to supply a full cloud-config snippet written to
#   /var/lib/vz/snippets/. IMPORTANT: when --cicustom user= is set, Proxmox's
#   native --ciuser and --sshkeys are silently ignored by cloud-init — the
#   snippet IS the entire user-data. Therefore the snippet must handle user
#   creation, SSH key injection, AND qemu-guest-agent installation.
#   Network config (--ipconfig, --nameserver) lives in a separate Proxmox
#   "network-data" section and is NOT affected by --cicustom user=.
#   After all qm set calls, `qm cloudinit update` rebuilds the ISO before
#   the VM starts. pvesh JSON is used throughout for storage inspection.
#
# USB NIC naming:
#   After each VM boots, the QEMU guest agent is queried for real NIC names.
#   Any USB passthrough NIC netplan placeholders are patched in-place.
#
# Bootstrap script delivery:
#   Bootstrap scripts are downloaded to a temp file on the remote VM before
#   execution. This keeps stdin free for interactive prompts (/dev/tty reads)
#   and avoids the pipe-to-sudo TTY issue where sudo may reject or misbehave
#   when its script arrives on stdin, even with NOPASSWD and -t -t SSH flags.
#
# NIC configuration:
#   Each vNIC has two properties:
#     1. Connection type — Bridge (shared Proxmox bridge) or USB NIC passthrough
#        (exclusive to this VM, preserves the USB adapter's fixed MAC address).
#        USB passthrough is recommended when the switch port uses Cisco port
#        security or any other single-MAC enforcement policy.
#     2. Network label — free text description shown in the summary (e.g.
#        "Ride Network", "Office Network", "Management VLAN"). Labels are for
#        the installer's reference only and have no effect on behavior.
#   One NIC is designated as the default route. That NIC's interface name is
#   passed to server.sh as RS_DEFAULT_ROUTE_NIC_HINT so it can be pre-populated
#   in the .env for outbound services (internet updates, SMTP alerts, weather).
#   RideStatus services listen on all interfaces — there are no network-role
#   restrictions. Edge nodes can connect from any attached network.
#
# USB bus path detection:
#   The sysfs path for USB NICs on modern kernels routes through a PCI segment
#   before the USB hub: e.g.
#     /sys/devices/pci0000:00/0000:00:08.1/0000:2d:00.3/usb4/4-2/4-2:2.0
#   The Proxmox passthrough identifier is the port path after the usbN/ segment
#   (e.g. "4-2"), NOT the segment immediately after /devices/. The regex
#   `usb\d+/\K[\d]+-[\d.]+(?=/)` extracts this correctly.
#
# Usage: bash proxmox/deploy.sh
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

prompt_default() {
  local -n _var=$1; local msg=$2 def=$3
  read -rp "$(echo -e "${BOLD}${msg}${RESET} [${def}]: ")" _var
  _var=${_var:-$def}
}

prompt_required() {
  local -n _var=$1; local msg=$2
  while true; do
    read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" _var
    [[ -n "$_var" ]] && break
    warn "This field is required."
  done
}

pick_menu() {
  local -n _pick=$1; local msg=$2; shift 2; local opts=("$@")
  echo -e "${BOLD}${msg}${RESET}"
  for i in "${!opts[@]}"; do echo "  $((i+1))) ${opts[$i]}"; done
  while true; do
    read -rp "Choice: " _pick
    if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#opts[@]} )); then
      _pick=$(( _pick - 1 )); break
    fi
    warn "Enter a number between 1 and ${#opts[@]}."
  done
}

confirm() {
  local ans
  while true; do
    read -rp "$(echo -e "${BOLD}$1${RESET} [y/n]: ")" ans
    case "$ans" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; *) warn "Please answer y or n." ;; esac
  done
}

# Helper: read MAC for an interface
iface_mac() { cat "/sys/class/net/${1}/address" 2>/dev/null || echo "unknown"; }

# Helper: get all storage config as JSON via pvesh (reliable, no awk)
storage_json() { pvesh get /storage --output-format json 2>/dev/null || echo '[]'; }

# Helper: purge an IP from /root/.ssh/known_hosts so manual SSH works cleanly
# after a VM is recreated at the same IP.
purge_known_host() {
  local ip=$1
  if [[ -f /root/.ssh/known_hosts ]]; then
    ssh-keygen -f /root/.ssh/known_hosts -R "$ip" &>/dev/null || true
  fi
}

# Helper: prompt for a static IP with CIDR prefix.
prompt_ip_cidr() {
  local -n _ipcidr=$1; local label=$2
  while true; do
    prompt_required _ipcidr "Static IP and prefix for ${label} (e.g. 10.15.140.101/25)"
    if [[ "$_ipcidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      local pfx="${_ipcidr##*/}"
      if (( pfx >= 1 && pfx <= 32 )); then
        break
      else
        warn "Prefix length /${pfx} is out of range (1-32). Try again."
        continue
      fi
    elif [[ "$_ipcidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      warn "No prefix length detected. Please enter the subnet mask for ${_ipcidr}."
      local mask
      prompt_required mask "Subnet mask (e.g. 255.255.255.128 or /25)"
      mask="${mask#/}"
      if [[ "$mask" =~ ^[0-9]+$ ]]; then
        local pfx="$mask"
        if (( pfx >= 1 && pfx <= 32 )); then
          _ipcidr="${_ipcidr}/${pfx}"
          break
        else
          warn "Prefix /${pfx} is out of range. Try again."
        fi
      elif [[ "$mask" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local pfx
        pfx=$(python3 -c "
import ipaddress, sys
try:
    n = ipaddress.IPv4Network('0.0.0.0/' + sys.argv[1], strict=False)
    print(n.prefixlen)
except Exception:
    print('')
" "$mask" 2>/dev/null || true)
        if [[ -n "$pfx" ]] && (( pfx >= 1 && pfx <= 32 )); then
          _ipcidr="${_ipcidr}/${pfx}"
          break
        else
          warn "Could not parse subnet mask '${mask}'. Try again."
        fi
      else
        warn "Could not parse '${mask}'. Enter a mask like 255.255.255.0 or a prefix like 24."
      fi
    else
      warn "Expected an IP address like 10.15.140.101 or 10.15.140.101/25. Try again."
    fi
  done
}

# =============================================================================
# Preflight
# =============================================================================
header "RideStatus Proxmox Deploy"

[[ $EUID -eq 0 ]] || die "This script must be run as root."
command -v pvesh    >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v pvesm    >/dev/null 2>&1 || die "pvesm not found — is this a Proxmox host?"
command -v qm       >/dev/null 2>&1 || die "qm not found — is this a Proxmox host?"
command -v lsusb    >/dev/null 2>&1 || die "lsusb not found (apt install usbutils)"
command -v ssh      >/dev/null 2>&1 || die "ssh not found"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
command -v python3  >/dev/null 2>&1 || die "python3 not found"
command -v curl     >/dev/null 2>&1 || die "curl not found"

PROXMOX_NODE=$(hostname)
info "Proxmox node: ${PROXMOX_NODE}"

# =============================================================================
# Detect suitable storages for OS disk, cloud-init drive, and snippets
# =============================================================================
header "Detecting Storage"

get_storage_field() {
  local name=$1 field=$2
  storage_json | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('storage') == '${name}':
        print(s.get('${field}', ''))
        break
" 2>/dev/null || true
}

find_dir_storage() {
  storage_json | python3 -c "
import sys, json
stores = json.load(sys.stdin)
for s in stores:
    if s.get('storage') == 'local' and s.get('type') == 'dir':
        print('local')
        sys.exit(0)
for s in stores:
    if s.get('type') == 'dir':
        print(s.get('storage', ''))
        sys.exit(0)
" 2>/dev/null || true
}

ensure_content_type() {
  local storage=$1 ctype=$2
  local current_content
  current_content=$(get_storage_field "$storage" "content")

  if echo "$current_content" | grep -qw "$ctype"; then
    info "Storage '${storage}' already has '${ctype}' content type"
    return 0
  fi

  info "Enabling '${ctype}' content type on storage '${storage}'..."
  local new_content
  if [[ -n "$current_content" ]]; then
    new_content="${current_content},${ctype}"
  else
    new_content="iso,vztmpl,backup,images,snippets"
  fi

  pvesm set "$storage" --content "$new_content" \
    || die "Failed to enable '${ctype}' content on storage '${storage}'"
  ok "'${ctype}' content type enabled on '${storage}'"
}

DISK_STORAGE=""
CI_STORAGE=""

if pvesm status --storage "local-lvm" &>/dev/null 2>&1; then
  DISK_STORAGE="local-lvm"
  info "OS disk storage: local-lvm"
else
  DISK_STORAGE=$(storage_json | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if 'images' in s.get('content', ''):
        print(s.get('storage', ''))
        break
" 2>/dev/null || true)
  [[ -n "$DISK_STORAGE" ]] || die "No images-capable storage found for OS disk"
  info "OS disk storage: ${DISK_STORAGE} (local-lvm not found)"
fi

CI_STORAGE=$(find_dir_storage)
[[ -n "$CI_STORAGE" ]] || die "No directory-type storage found for cloud-init drive."
ensure_content_type "$CI_STORAGE" "images"
ensure_content_type "$CI_STORAGE" "snippets"
info "Cloud-init / snippets storage: ${CI_STORAGE}"

SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# =============================================================================
# Temporary deploy keypair
# =============================================================================
DEPLOY_KEY_DIR=$(mktemp -d /tmp/ridestatus-deploy-XXXXXX)
DEPLOY_KEY="${DEPLOY_KEY_DIR}/id_ed25519"
DEPLOY_PUBKEY="${DEPLOY_KEY}.pub"

ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "ridestatus-deploy-temp" -q
DEPLOY_PUBKEY_CONTENT=$(cat "$DEPLOY_PUBKEY")
ok "Temporary deploy keypair generated (deleted on exit)"

ADMIN_KEY_PATH="/root/ridestatus-admin-key"

cleanup() {
  rm -rf "$DEPLOY_KEY_DIR"
  rm -f "${SNIPPET_DIR}/ridestatus-userdata-"*.yaml 2>/dev/null || true
}
trap cleanup EXIT

# deploy_ssh [-t] IP [CMD...]
# Tries the temporary deploy key first; falls back to the admin key ONLY on
# SSH authentication failure (exit code 255). Remote script errors (any other
# non-zero exit) are returned as-is without retrying — this prevents bootstrap
# scripts from running twice when a script fails partway through.
#
# Pass -t as the first argument to allocate a pseudo-TTY for the remote
# session. This is required when the remote script uses /dev/tty for
# interactive prompts. Double -t forces TTY allocation even when deploy.sh
# itself has no TTY (e.g. when run via bash <(curl ...)).
#
# In TTY mode stderr is NOT suppressed so interactive output and error
# messages reach the terminal.
deploy_ssh() {
  local tty_flag=false
  if [[ "${1:-}" == "-t" ]]; then
    tty_flag=true
    shift
  fi
  local ip=$1; shift
  local ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
  )
  if $tty_flag; then
    # -t -t: force TTY even when local stdin is not a TTY (bash <(curl ...))
    ssh_opts+=(-t -t)
    # Do NOT suppress stderr in TTY mode — interactive output must reach terminal
    ssh -i "$DEPLOY_KEY" "${ssh_opts[@]}" "ridestatus@${ip}" "$@"
    local exit_code=$?
    if [[ $exit_code -eq 255 ]] && [[ -f "$ADMIN_KEY_PATH" ]]; then
      ssh -i "$ADMIN_KEY_PATH" "${ssh_opts[@]}" "ridestatus@${ip}" "$@"
      return $?
    fi
    return $exit_code
  else
    ssh_opts+=(-o BatchMode=yes)
    local exit_code=0
    ssh -i "$DEPLOY_KEY" "${ssh_opts[@]}" "ridestatus@${ip}" "$@" 2>/dev/null
    exit_code=$?
    if [[ $exit_code -eq 0 ]]; then return 0; fi
    if [[ $exit_code -ne 255 ]]; then return $exit_code; fi
    if [[ -f "$ADMIN_KEY_PATH" ]]; then
      ssh -i "$ADMIN_KEY_PATH" "${ssh_opts[@]}" "ridestatus@${ip}" "$@" 2>/dev/null
      return $?
    fi
    return 1
  fi
}

# =============================================================================
# Detect physical interfaces and bridges
# =============================================================================
header "Detecting Network Interfaces"

mapfile -t ALL_IFACES < <(
  ip -o link show | awk -F': ' '{print $2}' \
  | grep -v '^lo$' \
  | grep -v '@' \
  | grep -Ev '^(vmbr|tap|veth|fwbr|fwpr|fwln)'
)

mapfile -t EXISTING_BRIDGES < <(
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' | grep -v '@' || true
)

echo ""
info "Physical interfaces found:"
for iface in "${ALL_IFACES[@]}"; do
  mac=$(iface_mac "$iface")
  state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
  is_usb=""
  readlink -f "/sys/class/net/${iface}/device" 2>/dev/null | grep -q '/usb' && is_usb=" [USB]"
  echo "  ${iface}  MAC=${mac}  state=${state}${is_usb}"
done

if [[ ${#EXISTING_BRIDGES[@]} -gt 0 ]]; then
  info "Existing Proxmox bridges:"
  for br in "${EXISTING_BRIDGES[@]}"; do
    echo "  ${br}"
  done
fi

# =============================================================================
# Enumerate USB NICs
# =============================================================================
header "USB NIC Detection"

declare -A USB_NIC_VENDOR_PRODUCT=()
declare -A USB_NIC_BUS_PATH=()
declare -A USB_NIC_MAC=()
declare -A USB_BUS_PATH_CLAIMED_BY=()
declare -a FREE_USB_NICS=()

for iface in "${ALL_IFACES[@]}"; do
  syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
  [[ -z "$syspath" ]] && continue
  echo "$syspath" | grep -q '/usb' || continue

  usb_dir=$(echo "$syspath" | sed 's|/[^/]*$||')
  vp=""
  while [[ "$usb_dir" =~ /usb ]]; do
    v=$(cat "${usb_dir}/idVendor"  2>/dev/null || true)
    p=$(cat "${usb_dir}/idProduct" 2>/dev/null || true)
    if [[ -n "$v" && -n "$p" ]]; then
      vp="${v}:${p}"
      break
    fi
    usb_dir=$(dirname "$usb_dir")
  done
  [[ -z "$vp" ]] && continue
  USB_NIC_VENDOR_PRODUCT["$iface"]="$vp"
  USB_NIC_MAC["$iface"]=$(iface_mac "$iface")

  # Extract USB bus path (e.g. "4-2") from the usbN/ segment of the sysfs path.
  # Sysfs paths route through PCI before USB on modern kernels, so the port path
  # is NOT immediately after /devices/. Example path:
  #   /sys/devices/pci0000:00/0000:00:08.1/0000:2d:00.3/usb4/4-2/4-2:2.0
  # The regex matches "4-2" by looking after the usbN/ component.
  bus_path=$(echo "$syspath" | grep -oP 'usb\d+/\K[\d]+-[\d.]+(?=/)' | head -1 || true)
  [[ -n "$bus_path" ]] && USB_NIC_BUS_PATH["$iface"]="$bus_path"
done

if [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -gt 0 ]]; then
  mapfile -t ALL_VMIDS < <(
    pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null \
    | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true
  )

  declare -A VP_TO_BUS_PATHS=()
  for iface in "${!USB_NIC_BUS_PATH[@]}"; do
    local_vp=${USB_NIC_VENDOR_PRODUCT[$iface]:-}
    local_bp=${USB_NIC_BUS_PATH[$iface]}
    [[ -z "$local_vp" ]] && continue
    existing=${VP_TO_BUS_PATHS[$local_vp]:-}
    VP_TO_BUS_PATHS["$local_vp"]="${existing:+$existing }$local_bp"
  done

  for vmid in "${ALL_VMIDS[@]}"; do
    vm_config=$(pvesh get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
                --output-format json 2>/dev/null || true)

    while IFS= read -r usb_entry; do
      raw=$(echo "$usb_entry" | grep -o 'host=[^ ",]*' | sed 's/host=//' || true)
      [[ -z "$raw" ]] && continue

      if echo "$raw" | grep -qP '^\d+-[\d.]+$'; then
        USB_BUS_PATH_CLAIMED_BY["$raw"]="$vmid"
      elif echo "$raw" | grep -qP '^[0-9a-f]{4}:[0-9a-f]{4}$'; then
        known_paths=${VP_TO_BUS_PATHS[$raw]:-}
        for bp in $known_paths; do
          USB_BUS_PATH_CLAIMED_BY["$bp"]="$vmid"
        done
      fi
    done < <(echo "$vm_config" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done
fi

for iface in "${!USB_NIC_VENDOR_PRODUCT[@]}"; do
  bp=${USB_NIC_BUS_PATH[$iface]:-}
  if [[ -z "$bp" ]]; then
    warn "Could not determine bus path for ${iface} — excluding from free list to be safe"
    continue
  fi
  if [[ -z "${USB_BUS_PATH_CLAIMED_BY[$bp]:-}" ]]; then
    FREE_USB_NICS+=("$iface")
  else
    info "USB NIC ${iface} (bus ${bp}, MAC ${USB_NIC_MAC[$iface]:-unknown}) already claimed by VM ${USB_BUS_PATH_CLAIMED_BY[$bp]} — skipping"
  fi
done

if   [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -eq 0 ]]; then
  info "No USB NICs detected."
elif [[ ${#FREE_USB_NICS[@]} -eq 0 ]]; then
  warn "All USB NICs already passed through to existing VMs."
else
  info "Free USB NICs available:"
  for iface in "${FREE_USB_NICS[@]}"; do
    mac=${USB_NIC_MAC[$iface]:-unknown}
    bp=${USB_NIC_BUS_PATH[$iface]:-unknown}
    echo "  ${iface}  MAC=${mac}  bus=${bp}  vendor:product=${USB_NIC_VENDOR_PRODUCT[$iface]}"
  done
fi

# =============================================================================
# VM selection
# =============================================================================
header "VM Selection"

CREATE_SERVER=false
CREATE_ANSIBLE=false
pick_idx=0
pick_menu pick_idx "Which VMs should be created on this host?" \
  "Both (recommended)" \
  "Ansible Controller only" \
  "RideStatus Server only"

case $pick_idx in
  0) CREATE_SERVER=true; CREATE_ANSIBLE=true ;;
  1) CREATE_ANSIBLE=true ;;
  2) CREATE_SERVER=true ;;
esac

$CREATE_ANSIBLE && info "Will create: Ansible Controller VM"
$CREATE_SERVER  && info "Will create: RideStatus Server VM"

declare -a SESSION_CLAIMED_USB=()
declare -A BRIDGE_IFACE_MAP=()

# =============================================================================
# NIC configuration helper
# =============================================================================
DEFAULT_ROUTE_NIC_IDX=-1

configure_vm_nics() {
  local vm_label=$1
  VM_NICS_TYPE=(); VM_NICS_LABEL=(); VM_NICS_BRIDGE=()
  VM_NICS_USB=();  VM_NICS_MAC=();   VM_NICS_IP=(); VM_NICS_GW=(); VM_NICS_DNS=()
  VM_NICS_DEFAULT_ROUTE=()
  DEFAULT_ROUTE_NIC_IDX=-1
  local default_route_assigned=false

  local nic_num=1
  while true; do
    echo ""
    echo -e "${BOLD}--- ${vm_label}: vNIC${nic_num} ---${RESET}"

    echo ""
    local net_label
    prompt_required net_label "Network label for vNIC${nic_num} (e.g. Ride Network, Office Network, Management)"

    echo ""
    echo -e "${BOLD}Connection type for vNIC${nic_num}:${RESET}"
    echo "  Bridge    — VM connects via a shared Proxmox bridge to a physical NIC."
    echo "              Multiple VMs share the same bridge. The VM gets a"
    echo "              Proxmox-generated MAC address."
    echo ""
    echo "  USB NIC   — A USB network adapter is passed directly to this VM."
    echo "  passthrough The VM owns it exclusively and uses the adapter's real,"
    echo "              fixed MAC address. Recommended when the switch port"
    echo "              enforces a single approved MAC (e.g. Cisco port security)."
    echo ""

    local available_usb=()
    for u in "${FREE_USB_NICS[@]:-}"; do
      local already=false
      for c in "${SESSION_CLAIMED_USB[@]:-}"; do
        [[ "$c" == "$u" ]] && already=true && break
      done
      $already || available_usb+=("$u")
    done

    local nic_type="" bridge_name="" usb_iface="" nic_mac=""

    if [[ ${#available_usb[@]} -gt 0 ]]; then
      local conn_opts=("Bridge" "USB NIC passthrough")
      local conn_idx=0
      pick_menu conn_idx "Connection type:" "${conn_opts[@]}"
      if [[ $conn_idx -eq 0 ]]; then
        nic_type="bridge"
      else
        nic_type="usb"
      fi
    else
      nic_type="bridge"
      info "No free USB NICs available — using bridge."
    fi

    if [[ "$nic_type" == "bridge" ]]; then
      local bridge_opts=()
      for b in "${EXISTING_BRIDGES[@]:-}"; do bridge_opts+=("$b (existing)"); done
      bridge_opts+=("Create a new bridge")

      local b_idx=0
      pick_menu b_idx "Which bridge?" "${bridge_opts[@]}"

      local existing_count=${#EXISTING_BRIDGES[@]}
      if (( b_idx < existing_count )); then
        bridge_name=${EXISTING_BRIDGES[$b_idx]}
      else
        local next_num=0
        while ip link show "vmbr${next_num}" &>/dev/null 2>&1; do
          next_num=$(( next_num + 1 ))
        done
        prompt_default bridge_name "New bridge name" "vmbr${next_num}"
        echo "Available physical interfaces:"
        for iface in "${ALL_IFACES[@]}"; do
          echo "  ${iface}  MAC=$(iface_mac "$iface")"
        done
        local onboard_iface
        prompt_required onboard_iface "Physical NIC to attach to ${bridge_name}"
        BRIDGE_IFACE_MAP["$bridge_name"]="$onboard_iface"
        EXISTING_BRIDGES+=("$bridge_name")
      fi
      nic_mac="virtio-generated"

    else
      if [[ ${#available_usb[@]} -eq 1 ]]; then
        usb_iface=${available_usb[0]}
        nic_mac=${USB_NIC_MAC[$usb_iface]:-unknown}
        ok "Using USB NIC: ${usb_iface}  MAC=${nic_mac}  bus=${USB_NIC_BUS_PATH[$usb_iface]:-unknown}"
      else
        local usb_opts=()
        for u in "${available_usb[@]}"; do
          local mac=${USB_NIC_MAC[$u]:-unknown}
          local bp=${USB_NIC_BUS_PATH[$u]:-unknown}
          usb_opts+=("${u}  MAC=${mac}  bus=${bp}  (${USB_NIC_VENDOR_PRODUCT[$u]})")
        done
        local usb_idx=0
        pick_menu usb_idx "Which USB NIC?" "${usb_opts[@]}"
        usb_iface=${available_usb[$usb_idx]}
        nic_mac=${USB_NIC_MAC[$usb_iface]:-unknown}
      fi
      SESSION_CLAIMED_USB+=("$usb_iface")
      ok "Reserved ${usb_iface}  MAC=${nic_mac}  bus=${USB_NIC_BUS_PATH[$usb_iface]:-unknown}  for ${vm_label} vNIC${nic_num}"
    fi

    local ip_cidr="" gw="" dns=""
    prompt_ip_cidr ip_cidr "${net_label}"

    local is_default_route="no"
    if ! $default_route_assigned; then
      echo ""
      echo -e "${BOLD}Default route / internet NIC?${RESET}"
      echo "  One NIC should carry internet traffic — software updates, outbound"
      echo "  alerts, and weather data go out through this interface."
      echo "  Edge nodes can connect to the server from any network."
      if confirm "Use vNIC${nic_num} (${net_label}) as the default route for ${vm_label}?"; then
        is_default_route="yes"
        default_route_assigned=true
        DEFAULT_ROUTE_NIC_IDX=$(( nic_num - 1 ))
        prompt_required gw "Default gateway"
      fi
    else
      info "Default route already assigned to an earlier NIC — skipping for vNIC${nic_num}."
    fi
    prompt_default dns "DNS server" "8.8.8.8"

    VM_NICS_TYPE+=("$nic_type"); VM_NICS_LABEL+=("$net_label")
    VM_NICS_BRIDGE+=("$bridge_name"); VM_NICS_USB+=("$usb_iface")
    VM_NICS_MAC+=("$nic_mac")
    VM_NICS_IP+=("$ip_cidr"); VM_NICS_GW+=("$gw"); VM_NICS_DNS+=("$dns")
    VM_NICS_DEFAULT_ROUTE+=("$is_default_route")

    nic_num=$(( nic_num + 1 ))
    confirm "Add another NIC to ${vm_label}?" || break
  done

  if ! $default_route_assigned; then
    warn "No default route NIC was designated for ${vm_label}."
    warn "The VM will have no internet access until a default route is configured manually."
  fi
}

# =============================================================================
# Collect NIC config
# =============================================================================
if $CREATE_ANSIBLE; then
  header "Ansible Controller VM — NIC Configuration"
  configure_vm_nics "Ansible VM"
  ANSIBLE_NICS_TYPE=("${VM_NICS_TYPE[@]}");   ANSIBLE_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  ANSIBLE_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}"); ANSIBLE_NICS_USB=("${VM_NICS_USB[@]}")
  ANSIBLE_NICS_MAC=("${VM_NICS_MAC[@]}")
  ANSIBLE_NICS_IP=("${VM_NICS_IP[@]}");         ANSIBLE_NICS_GW=("${VM_NICS_GW[@]}")
  ANSIBLE_NICS_DNS=("${VM_NICS_DNS[@]}")
  ANSIBLE_NICS_DEFAULT_ROUTE=("${VM_NICS_DEFAULT_ROUTE[@]}")
fi

if $CREATE_SERVER; then
  header "RideStatus Server VM — NIC Configuration"
  configure_vm_nics "Server VM"
  SERVER_NICS_TYPE=("${VM_NICS_TYPE[@]}");   SERVER_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  SERVER_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}"); SERVER_NICS_USB=("${VM_NICS_USB[@]}")
  SERVER_NICS_MAC=("${VM_NICS_MAC[@]}")
  SERVER_NICS_IP=("${VM_NICS_IP[@]}");         SERVER_NICS_GW=("${VM_NICS_GW[@]}")
  SERVER_NICS_DNS=("${VM_NICS_DNS[@]}")
  SERVER_NICS_DEFAULT_ROUTE=("${VM_NICS_DEFAULT_ROUTE[@]}")
  SERVER_DEFAULT_ROUTE_NIC_IDX=$DEFAULT_ROUTE_NIC_IDX
fi

# =============================================================================
# VM IDs
# =============================================================================
header "VM IDs"

next_free_vmid() {
  local id=100
  while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${id}/status" &>/dev/null 2>&1; do
    id=$(( id + 1 ))
  done
  echo $id
}

pick_vmid() {
  local -n _vmid=$1; local label=$2
  local suggested; suggested=$(next_free_vmid)
  while true; do
    prompt_default _vmid "VM ID for ${label}" "$suggested"
    if pvesh get "/nodes/${PROXMOX_NODE}/qemu/${_vmid}/status" &>/dev/null 2>&1; then
      warn "VM ID ${_vmid} is already in use."
      suggested=$(next_free_vmid); warn "Next available: ${suggested}"
    else
      break
    fi
  done
}

if $CREATE_ANSIBLE; then pick_vmid ANSIBLE_VMID "Ansible Controller"; fi
if $CREATE_SERVER;  then pick_vmid SERVER_VMID  "RideStatus Server"; fi

# =============================================================================
# VM resources and hostnames
# =============================================================================
header "VM Resources"

if $CREATE_ANSIBLE; then
  prompt_default ANSIBLE_RAM   "Ansible VM RAM (GB)"  "2"
  prompt_default ANSIBLE_CORES "Ansible VM CPU cores" "2"
  prompt_default ANSIBLE_DISK  "Ansible VM disk (GB)" "20"
  prompt_default ANSIBLE_HOST  "Ansible VM hostname"  "ridestatus-ansible"
fi

if $CREATE_SERVER; then
  prompt_default SERVER_RAM   "Server VM RAM (GB)"  "4"
  prompt_default SERVER_CORES "Server VM CPU cores" "2"
  prompt_default SERVER_DISK  "Server VM disk (GB)" "64"
  prompt_default SERVER_HOST  "Server VM hostname"  "ridestatus-server"
fi

# =============================================================================
# Admin SSH key
# =============================================================================
header "Admin SSH Key"

ADMIN_GENERATED=false

echo -e "${BOLD}Paste your SSH public key below, or press Enter to generate one automatically.${RESET}"
echo -e "(A generated key will be saved to ${ADMIN_KEY_PATH} on this Proxmox host)"
read -rp "$(echo -e "${BOLD}SSH public key${RESET} [press Enter to generate]: ")" ADMIN_SSH_PUBKEY

if [[ -z "$ADMIN_SSH_PUBKEY" ]]; then
  if [[ -f "${ADMIN_KEY_PATH}.pub" ]]; then
    ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
    ok "Using existing admin key at ${ADMIN_KEY_PATH}"
  else
    ssh-keygen -t ed25519 -f "$ADMIN_KEY_PATH" -N "" -C "ridestatus-admin" -q
    ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
    ADMIN_GENERATED=true
    ok "Admin keypair generated and saved to ${ADMIN_KEY_PATH}"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
header "Summary — Review Before Proceeding"

print_vm_summary() {
  local label=$1 vmid=$2 hostname=$3 ram=$4 cores=$5 disk=$6
  local -n _nt=$7 _nl=$8 _nb=$9 _nu=${10} _nm=${11} _ni=${12} _ng=${13} _nd=${14}
  echo -e "  ${BOLD}${label}${RESET}"
  echo "    VM ID: ${vmid}  Hostname: ${hostname}  RAM: ${ram}GB  Cores: ${cores}  Disk: ${disk}GB"
  for i in "${!_nt[@]}"; do
    local conn=""
    if [[ "${_nt[$i]}" == "bridge" ]]; then
      conn="bridge=${_nb[$i]}  MAC=${_nm[$i]}"
    else
      local bp=${USB_NIC_BUS_PATH[${_nu[$i]}]:-unknown}
      conn="USB passthrough=${_nu[$i]}  MAC=${_nm[$i]}  bus=${bp}"
    fi
    local gw_str=""; [[ -n "${_ng[$i]:-}" ]] && gw_str="  GW=${_ng[$i]}"
    local dr_str=""; [[ "${_nd[$i]:-}" == "yes" ]] && dr_str="  [DEFAULT ROUTE]"
    echo "    vNIC$((i+1)): ${_nl[$i]}  IP=${_ni[$i]}${gw_str}  [${conn}]${dr_str}"
  done
}

echo ""
$CREATE_ANSIBLE && print_vm_summary "Ansible Controller" "$ANSIBLE_VMID" "$ANSIBLE_HOST" \
  "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
  ANSIBLE_NICS_TYPE ANSIBLE_NICS_LABEL ANSIBLE_NICS_BRIDGE \
  ANSIBLE_NICS_USB  ANSIBLE_NICS_MAC   ANSIBLE_NICS_IP ANSIBLE_NICS_GW ANSIBLE_NICS_DEFAULT_ROUTE
echo ""
$CREATE_SERVER  && print_vm_summary "RideStatus Server" "$SERVER_VMID" "$SERVER_HOST" \
  "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
  SERVER_NICS_TYPE SERVER_NICS_LABEL SERVER_NICS_BRIDGE \
  SERVER_NICS_USB  SERVER_NICS_MAC   SERVER_NICS_IP SERVER_NICS_GW SERVER_NICS_DEFAULT_ROUTE

echo ""
info "Storage: OS disk → ${DISK_STORAGE}  |  Cloud-init → ${CI_STORAGE}"
if $ADMIN_GENERATED; then
  info "Admin SSH key: ${ADMIN_KEY_PATH} (private) — copy to your PC after deployment"
  info "              ${ADMIN_KEY_PATH}.pub (public)"
else
  info "Admin SSH key: provided by operator"
fi

echo ""
warn "This will create VMs and modify Proxmox network configuration."
read -rp "$(echo -e "${BOLD}Type 'yes' to proceed: ${RESET}")" final_confirm
[[ "$final_confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# Helpers: bridge, image
# =============================================================================
ensure_bridge() {
  local bridge=$1
  if ! ip link show "$bridge" &>/dev/null 2>&1; then
    local phys=${BRIDGE_IFACE_MAP[$bridge]:-none}
    info "Creating bridge ${bridge} (attached to ${phys})"
    { echo "auto ${bridge}"
      echo "iface ${bridge} inet manual"
      echo "  bridge_ports ${phys}"
      echo "  bridge_stp off"
      echo "  bridge_fd 0"
    } > "/etc/network/interfaces.d/${bridge}"
    ifup "$bridge" 2>/dev/null || true
    ok "Bridge ${bridge} created"
  else
    info "Bridge ${bridge} already exists — skipping"
  fi
}

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

write_userdata_snippet() {
  local vmid=$1 deploy_key=$2 admin_key=$3
  local snippet_file="${SNIPPET_DIR}/ridestatus-userdata-${vmid}.yaml"

  cat > "$snippet_file" <<YAML
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

  echo "$snippet_file"
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

  local bridge_nic_idx=0 usb_slot=0
  for i in "${!cv_type[@]}"; do
    if [[ "${cv_type[$i]}" == "bridge" ]]; then
      qm set "$vmid" --net${bridge_nic_idx} "virtio,bridge=${cv_bridge[$i]}"
      bridge_nic_idx=$(( bridge_nic_idx + 1 ))
    else
      local host_iface=${cv_usb[$i]}
      local bp=${USB_NIC_BUS_PATH[$host_iface]:-}
      if [[ -z "$bp" ]]; then
        local vp=${USB_NIC_VENDOR_PRODUCT[$host_iface]:-}
        [[ -z "$vp" ]] && die "Cannot find bus path or vendor:product for ${host_iface}"
        warn "Bus path unavailable for ${host_iface} — falling back to host=${vp} (may be ambiguous)"
        qm set "$vmid" --usb${usb_slot} "host=${vp}"
      else
        info "Assigning USB NIC ${host_iface} (MAC ${USB_NIC_MAC[$host_iface]:-unknown}) via host=${bp}"
        qm set "$vmid" --usb${usb_slot} "host=${bp}"
      fi
      usb_slot=$(( usb_slot + 1 ))
    fi
  done

  qm set "$vmid" --ide2 "${CI_STORAGE}:cloudinit"

  local ipconfig_idx=0
  for i in "${!cv_type[@]}"; do
    [[ "${cv_type[$i]}" != "bridge" ]] && continue
    local ip="${cv_ip[$i]}"
    local gw_part=""
    [[ -n "${cv_gw[$i]:-}" ]] && gw_part=",gw=${cv_gw[$i]}"
    qm set "$vmid" --ipconfig${ipconfig_idx} "ip=${ip}${gw_part}"
    ipconfig_idx=$(( ipconfig_idx + 1 ))
  done

  qm set "$vmid" --nameserver "${cv_dns[0]:-8.8.8.8}"
  qm set "$vmid" --ciupgrade 0

  local snippet_file
  snippet_file=$(write_userdata_snippet "$vmid" "$DEPLOY_PUBKEY_CONTENT" "$ADMIN_SSH_PUBKEY")
  qm set "$vmid" --cicustom "user=${CI_STORAGE}:snippets/$(basename "$snippet_file")"
  info "Cloud-init user-data snippet written: $(basename "$snippet_file")"

  info "Regenerating cloud-init ISO for VM ${vmid}..."
  qm cloudinit update "$vmid"
  ok "Cloud-init ISO updated for VM ${vmid}"

  ok "VM ${vmid} configured"
}

wait_for_guest_agent() {
  local vmid=$1 max_wait=${2:-900} elapsed=0
  info "Waiting for guest agent on VM ${vmid} (up to ${max_wait}s — first boot may take 10+ min)..."
  while (( elapsed < max_wait )); do
    qm guest cmd "$vmid" ping &>/dev/null 2>&1 && { ok "Guest agent ready on VM ${vmid}"; return 0; }
    sleep 10
    elapsed=$(( elapsed + 10 ))
    if (( elapsed % 60 == 0 )); then
      echo " ${elapsed}s"
    else
      echo -n "."
    fi
  done
  echo ""; die "Timed out waiting for guest agent on VM ${vmid}"
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

  declare -A GA_MAC_TO_NAME=()
  while IFS= read -r line; do
    local name mac
    name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || true)
    mac=$(echo  "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hardware-address','').lower())" 2>/dev/null || true)
    [[ -n "$name" && -n "$mac" ]] && GA_MAC_TO_NAME["$mac"]="$name"
  done < <(echo "$ga_json" | python3 -c \
    "import sys,json; [print(json.dumps(x)) for x in json.load(sys.stdin).get('result',[])]" \
    2>/dev/null || true)

  [[ ${#GA_MAC_TO_NAME[@]} -eq 0 ]] && { warn "Guest agent returned no NIC data"; return 0; }

  local usb_slot=0 needs_fix=false
  declare -A USB_REAL_NAME=()

  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" != "usb" ]] && continue
    local host_iface=${fnn_usb[$i]}
    local host_mac; host_mac=$(iface_mac "$host_iface" | tr '[:upper:]' '[:lower:]')
    local real_name=${GA_MAC_TO_NAME[$host_mac]:-}
    local placeholder="usb-placeholder-${usb_slot}"

    if [[ -z "$real_name" ]]; then
      warn "No guest NIC matched MAC ${host_mac} — ${placeholder} may need manual fix"
    elif [[ "$real_name" != "$placeholder" ]]; then
      info "USB NIC ${host_iface} (MAC ${host_mac}) is '${real_name}' inside VM"
      USB_REAL_NAME["$placeholder"]="$real_name"
      needs_fix=true
    fi
    usb_slot=$(( usb_slot + 1 ))
  done

  $needs_fix || { ok "All NIC names correct — no netplan patch needed"; return 0; }

  local ssh_ip=""
  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" == "bridge" ]] && { ssh_ip="${fnn_ip[$i]%%/*}"; break; }
  done
  [[ -z "$ssh_ip" ]] && ssh_ip="${fnn_ip[0]%%/*}"

  local sed_args=()
  for placeholder in "${!USB_REAL_NAME[@]}"; do
    sed_args+=(-e "s/${placeholder}/${USB_REAL_NAME[$placeholder]}/g")
  done

  deploy_ssh "$ssh_ip" "
    set -e
    f=\$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    [[ -z \"\$f\" ]] && { echo 'No netplan file'; exit 1; }
    sudo sed -i ${sed_args[*]} \"\$f\"
    sudo netplan apply
  " && ok "Netplan patched in VM ${vmid}" \
    || warn "Netplan patch failed — check USB NIC names manually"
}

first_ip() { local -n _fi=$1; echo "${_fi[0]%%/*}"; }

wait_for_ssh() {
  local ip=$1 max_wait=300 elapsed=0
  info "Waiting for SSH on ${ip}..."
  while (( elapsed < max_wait )); do
    deploy_ssh "$ip" 'exit 0' &>/dev/null && { ok "SSH ready on ${ip}"; return 0; }
    sleep 5
    elapsed=$(( elapsed + 5 ))
    echo -n "."
  done
  echo ""; die "Timed out waiting for SSH on ${ip}"
}

# =============================================================================
# Helper: run bootstrap script in a VM via TTY SSH
#
# Downloads the script to a temp file on the remote VM, then executes it.
# Stderr is NOT suppressed in TTY mode so all output reaches the terminal.
# =============================================================================
BOOTSTRAP_BASE_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap"
ANSIBLE_KEY_SERVER_PORT=9876

run_bootstrap() {
  local ip=$1 script=$2 extra_env=${3:-}
  info "Running ${script} on ${ip}..."
  local env_export=""
  [[ -n "$extra_env" ]] && env_export="export ${extra_env}; "
  deploy_ssh -t "$ip" "
    set -e
    _rs_tmp=\$(mktemp /tmp/ridestatus-bootstrap-XXXXXX.sh)
    curl -fsSL -H 'Cache-Control: no-cache' \
      '${BOOTSTRAP_BASE_URL}/${script}?'\$(date +%s) -o \"\$_rs_tmp\"
    ${env_export}sudo -E bash \"\$_rs_tmp\"
    rm -f \"\$_rs_tmp\"
  " || {
    echo ""
    err "Bootstrap failed for ${script} on ${ip}."
    err "To retry: ssh ridestatus@${ip}"
    err "  curl -fsSL -H 'Cache-Control: no-cache' '${BOOTSTRAP_BASE_URL}/${script}?'\$(date +%s) -o /tmp/rs.sh && sudo bash /tmp/rs.sh"
    return 1
  }
  ok "${script} completed on ${ip}"
}

# =============================================================================
# EXECUTE
# =============================================================================

header "Creating Bridges"
for bridge in "${!BRIDGE_IFACE_MAP[@]}"; do ensure_bridge "$bridge"; done

ensure_ubuntu_image

if $CREATE_ANSIBLE; then
  header "Creating Ansible Controller VM (${ANSIBLE_VMID})"
  create_vm "$ANSIBLE_VMID" "$ANSIBLE_HOST" "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_BRIDGE ANSIBLE_NICS_USB \
    ANSIBLE_NICS_IP   ANSIBLE_NICS_GW     ANSIBLE_NICS_DNS
  qm start "$ANSIBLE_VMID"
  purge_known_host "$(first_ip ANSIBLE_NICS_IP)"
  ok "VM ${ANSIBLE_VMID} started"
fi

if $CREATE_SERVER; then
  header "Creating RideStatus Server VM (${SERVER_VMID})"
  create_vm "$SERVER_VMID" "$SERVER_HOST" "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    SERVER_NICS_TYPE SERVER_NICS_BRIDGE SERVER_NICS_USB \
    SERVER_NICS_IP   SERVER_NICS_GW     SERVER_NICS_DNS
  qm start "$SERVER_VMID"
  purge_known_host "$(first_ip SERVER_NICS_IP)"
  ok "VM ${SERVER_VMID} started"
fi

ANSIBLE_IP=""
SERVER_IP=""

if $CREATE_ANSIBLE; then
  wait_for_guest_agent "$ANSIBLE_VMID"
  fix_usb_nic_names "$ANSIBLE_VMID" ANSIBLE_NICS_TYPE ANSIBLE_NICS_USB ANSIBLE_NICS_IP
  ANSIBLE_IP=$(first_ip ANSIBLE_NICS_IP)
  wait_for_ssh "$ANSIBLE_IP"
fi

if $CREATE_SERVER; then
  wait_for_guest_agent "$SERVER_VMID"
  fix_usb_nic_names "$SERVER_VMID" SERVER_NICS_TYPE SERVER_NICS_USB SERVER_NICS_IP
  SERVER_IP=$(first_ip SERVER_NICS_IP)
  wait_for_ssh "$SERVER_IP"
fi

if $CREATE_ANSIBLE && $CREATE_SERVER; then
  ANSIBLE_KEY_URL="http://${ANSIBLE_IP}:${ANSIBLE_KEY_SERVER_PORT}/ansible_ridestatus.pub"
  SERVER_BOOTSTRAP_ENV="ANSIBLE_KEY_URL=${ANSIBLE_KEY_URL} ANSIBLE_VM_HOST=${ANSIBLE_IP}"
  if (( SERVER_DEFAULT_ROUTE_NIC_IDX >= 0 )); then
    SERVER_BOOTSTRAP_ENV+=" RS_DEFAULT_ROUTE_NIC_HINT=net${SERVER_DEFAULT_ROUTE_NIC_IDX}"
  fi

  info "Starting server.sh in background (waiting for Ansible key)..."
  ( run_bootstrap "$SERVER_IP" "server.sh" "$SERVER_BOOTSTRAP_ENV" || true ) &
  SERVER_BOOTSTRAP_PID=$!

  run_bootstrap "$ANSIBLE_IP" "ansible.sh" || true

  info "Waiting for server.sh to complete..."
  wait "$SERVER_BOOTSTRAP_PID" 2>/dev/null || true

elif $CREATE_ANSIBLE; then
  run_bootstrap "$ANSIBLE_IP" "ansible.sh" || true

elif $CREATE_SERVER; then
  SERVER_BOOTSTRAP_ENV=""
  if (( SERVER_DEFAULT_ROUTE_NIC_IDX >= 0 )); then
    SERVER_BOOTSTRAP_ENV="RS_DEFAULT_ROUTE_NIC_HINT=net${SERVER_DEFAULT_ROUTE_NIC_IDX}"
  fi
  run_bootstrap "$SERVER_IP" "server.sh" "$SERVER_BOOTSTRAP_ENV" || true
fi

# =============================================================================
# Done
# =============================================================================
header "Deployment Complete"

$CREATE_ANSIBLE && ok "Ansible Controller VM ${ANSIBLE_VMID} (${ANSIBLE_HOST}) — ${ANSIBLE_IP}"
$CREATE_SERVER  && ok "RideStatus Server VM ${SERVER_VMID}  (${SERVER_HOST})  — ${SERVER_IP}"

echo ""
info "Next steps:"
info "  1. Verify VMs are accessible in the Proxmox web UI"
info "  2. SSH to each VM as ridestatus@<ip> using your admin key"
info "  3. Run bootstrap/edge-init.sh on each ride edge node"
if $ADMIN_GENERATED; then
  echo ""
  warn "*** IMPORTANT: Copy your admin SSH private key off this Proxmox host ***"
  warn "    Private key : ${ADMIN_KEY_PATH}"
  warn "    Public key  : ${ADMIN_KEY_PATH}.pub"
  warn "    Use WinSCP or similar to download ${ADMIN_KEY_PATH} to your PC."
  warn "    In PuTTY/WinSCP, convert it with PuTTYgen if needed (File > Load, Save private key as .ppk)"
fi
echo ""
