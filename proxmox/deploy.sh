#!/usr/bin/env bash
# =============================================================================
# RideStatus — Proxmox Deploy Script
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates RideStatus Server VM and/or Ansible Controller VM.
# Walks the tech through NIC topology, VM IDs, and resource sizing.
# After VM creation, SSHs in and runs the appropriate bootstrap script.
#
# Usage: bash proxmox/deploy.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m';  YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';      RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { err "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# Prompt with a default value. Usage: prompt_default VAR "Question" "default"
prompt_default() {
  local -n _var=$1
  local msg=$2 def=$3
  read -rp "$(echo -e "${BOLD}${msg}${RESET} [${def}]: ")" _var
  _var=${_var:-$def}
}

# Prompt with no default (required). Usage: prompt_required VAR "Question"
prompt_required() {
  local -n _var=$1
  local msg=$2
  while true; do
    read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" _var
    [[ -n "$_var" ]] && break
    warn "This field is required."
  done
}

# Numbered menu. Usage: pick_menu VAR "Prompt" "opt1" "opt2" ...
pick_menu() {
  local -n _pick=$1
  local msg=$2; shift 2
  local opts=("$@")
  echo -e "${BOLD}${msg}${RESET}"
  for i in "${!opts[@]}"; do
    echo "  $((i+1))) ${opts[$i]}"
  done
  while true; do
    read -rp "Choice: " _pick
    if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#opts[@]} )); then
      _pick=$(( _pick - 1 ))  # return 0-based index
      break
    fi
    warn "Enter a number between 1 and ${#opts[@]}."
  done
}

# yes/no prompt. Usage: confirm "Question"  → returns 0 for yes, 1 for no
confirm() {
  local ans
  while true; do
    read -rp "$(echo -e "${BOLD}$1${RESET} [y/n]: ")" ans
    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) warn "Please answer y or n."
    esac
  done
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
header "RideStatus Proxmox Deploy"

[[ $EUID -eq 0 ]] || die "This script must be run as root."
command -v pvesh >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v qm    >/dev/null 2>&1 || die "qm not found — is this a Proxmox host?"
command -v lsusb >/dev/null 2>&1 || die "lsusb not found (install usbutils: apt install usbutils)"

PROXMOX_NODE=$(hostname)
info "Proxmox node: ${PROXMOX_NODE}"

# -----------------------------------------------------------------------------
# Detect onboard NICs and existing bridges
# -----------------------------------------------------------------------------
header "Detecting Network Interfaces"

# All network interfaces, excluding loopback and virtual Proxmox bridges
mapfile -t ALL_IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '^vmbr' | grep -v '^tap' | grep -v '^veth' | grep -v '^fwbr' | grep -v '^fwpr')

# Existing Linux bridges
mapfile -t EXISTING_BRIDGES < <(brctl show 2>/dev/null | awk 'NR>1 && $1!="" {print $1}' || true)

echo ""
info "Physical interfaces found:"
for iface in "${ALL_IFACES[@]}"; do
  mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
  state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
  # Check if USB-attached
  is_usb=""
  if readlink -f "/sys/class/net/${iface}/device" 2>/dev/null | grep -q '/usb'; then
    is_usb=" [USB]"
  fi
  echo "  ${iface}  MAC=${mac}  state=${state}${is_usb}"
done

# -----------------------------------------------------------------------------
# Enumerate USB NICs and determine which are already passed through
# -----------------------------------------------------------------------------
header "USB NIC Detection"

declare -A USB_NIC_VENDOR_PRODUCT   # iface → vendor:product
declare -A USB_NIC_CLAIMED_BY       # vendor:product → vmid (if claimed)
declare -a FREE_USB_NICS            # array of iface names that are free

# Build USB NIC map
for iface in "${ALL_IFACES[@]}"; do
  syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
  if echo "$syspath" | grep -q '/usb'; then
    # Extract vendor:product from sysfs
    vp=$(cat "$(echo "$syspath" | sed 's|/[^/]*$||')/idVendor" 2>/dev/null || true)
    pp=$(cat "$(echo "$syspath" | sed 's|/[^/]*$||')/idProduct" 2>/dev/null || true)
    if [[ -n "$vp" && -n "$pp" ]]; then
      USB_NIC_VENDOR_PRODUCT["$iface"]="${vp}:${pp}"
    fi
  fi
done

# Check all existing VM configs for usb passthrough entries
if [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -gt 0 ]]; then
  mapfile -t ALL_VMIDS < <(pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true)
  for vmid in "${ALL_VMIDS[@]}"; do
    vm_config=$(pvesh get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" --output-format json 2>/dev/null || true)
    # Extract any usb\d entries
    while IFS= read -r usb_entry; do
      vp=$(echo "$usb_entry" | grep -o 'host=[0-9a-f]*:[0-9a-f]*' | sed 's/host=//' || true)
      [[ -n "$vp" ]] && USB_NIC_CLAIMED_BY["$vp"]="$vmid"
    done < <(echo "$vm_config" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done
fi

# Build free USB NIC list
for iface in "${!USB_NIC_VENDOR_PRODUCT[@]}"; do
  vp=${USB_NIC_VENDOR_PRODUCT[$iface]}
  if [[ -z "${USB_NIC_CLAIMED_BY[$vp]:-}" ]]; then
    FREE_USB_NICS+=("$iface")
  fi
done

if [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -eq 0 ]]; then
  info "No USB NICs detected on this host."
elif [[ ${#FREE_USB_NICS[@]} -eq 0 ]]; then
  warn "USB NICs found but all are already passed through to existing VMs."
  warn "USB passthrough will not be offered as an option."
else
  info "Free USB NICs available for passthrough:"
  for iface in "${FREE_USB_NICS[@]}"; do
    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
    vp=${USB_NIC_VENDOR_PRODUCT[$iface]}
    echo "  ${iface}  MAC=${mac}  vendor:product=${vp}"
  done
fi

# -----------------------------------------------------------------------------
# Which VMs to create
# -----------------------------------------------------------------------------
header "VM Selection"

CREATE_SERVER=false
CREATE_ANSIBLE=false

pick_idx=0
pick_menu pick_idx "Which VMs should be created on this host?" \
  "RideStatus Server only" \
  "Ansible Controller only" \
  "Both"

case $pick_idx in
  0) CREATE_SERVER=true ;;
  1) CREATE_ANSIBLE=true ;;
  2) CREATE_SERVER=true; CREATE_ANSIBLE=true ;;
esac

$CREATE_SERVER && info "Will create: RideStatus Server VM"
$CREATE_ANSIBLE && info "Will create: Ansible Controller VM"

# Track which USB NICs have been claimed during this session
declare -a SESSION_CLAIMED_USB=()

# -----------------------------------------------------------------------------
# NIC configuration helper
# Called once per VM. Populates arrays of vNIC configs.
# Usage: configure_vm_nics <vm_label>
#   Sets VM_NICS_TYPE[]  ("bridge" or "usb")
#       VM_NICS_LABEL[]  (free-text network label)
#       VM_NICS_BRIDGE[] (bridge name if type=bridge)
#       VM_NICS_USB[]    (iface name if type=usb)
#       VM_NICS_IP[]     (static IP/prefix e.g. 10.0.0.5/24)
#       VM_NICS_GW[]     (gateway or "")
#       VM_NICS_DNS[]    (DNS server)
# -----------------------------------------------------------------------------
configure_vm_nics() {
  local vm_label=$1
  VM_NICS_TYPE=();  VM_NICS_LABEL=(); VM_NICS_BRIDGE=()
  VM_NICS_USB=();   VM_NICS_IP=();    VM_NICS_GW=(); VM_NICS_DNS=()

  local nic_num=1
  while true; do
    echo ""
    echo -e "${BOLD}--- ${vm_label}: vNIC${nic_num} ---${RESET}"

    # Network label
    local net_label
    prompt_required net_label "What network does vNIC${nic_num} connect to? (e.g. Department, Corporate VLAN, Ride Network)"

    # Connection method
    local method_opts=("Bridge to onboard NIC (shared, no MAC isolation)")
    # Only offer USB passthrough if free USB NICs remain
    local available_usb=()
    for u in "${FREE_USB_NICS[@]}"; do
      local already=false
      for c in "${SESSION_CLAIMED_USB[@]:-}"; do
        [[ "$c" == "$u" ]] && already=true && break
      done
      $already || available_usb+=("$u")
    done
    [[ ${#available_usb[@]} -gt 0 ]] && method_opts+=("USB NIC passthrough (exclusive, stable MAC)")

    local method_idx=0
    pick_menu method_idx "How should vNIC${nic_num} connect?" "${method_opts[@]}"

    local nic_type bridge_name usb_iface ip_cidr gw dns

    if [[ $method_idx -eq 0 ]]; then
      # ---- Bridge to onboard ----
      nic_type="bridge"

      # List existing bridges and offer to create a new one
      local bridge_opts=()
      for b in "${EXISTING_BRIDGES[@]:-}"; do bridge_opts+=("$b (existing)"); done
      bridge_opts+=("Create a new bridge")

      local b_idx=0
      pick_menu b_idx "Which bridge?" "${bridge_opts[@]}"

      if (( b_idx < ${#EXISTING_BRIDGES[@]:-0} )); then
        bridge_name=${EXISTING_BRIDGES[$b_idx]}
      else
        # New bridge
        local new_bridge_name
        # Suggest next available vmbr name
        local next_num=0
        while ip link show "vmbr${next_num}" &>/dev/null; do (( next_num++ )); done
        prompt_default new_bridge_name "New bridge name" "vmbr${next_num}"
        bridge_name=$new_bridge_name

        # Which physical NIC to attach to this bridge
        local onboard_iface
        echo "Available physical interfaces:"
        for iface in "${ALL_IFACES[@]}"; do
          echo "  ${iface}"
        done
        prompt_required onboard_iface "Physical NIC to attach to ${bridge_name}"
        # Store for later bridge creation
        BRIDGE_IFACE_MAP["$bridge_name"]="$onboard_iface"
        EXISTING_BRIDGES+=("$bridge_name")
      fi

    else
      # ---- USB NIC passthrough ----
      nic_type="usb"

      if [[ ${#available_usb[@]} -eq 1 ]]; then
        usb_iface=${available_usb[0]}
        info "Using only available free USB NIC: ${usb_iface}"
      else
        local usb_opts=()
        for u in "${available_usb[@]}"; do
          local mac; mac=$(cat "/sys/class/net/${u}/address" 2>/dev/null || echo "unknown")
          local vp=${USB_NIC_VENDOR_PRODUCT[$u]}
          usb_opts+=("${u}  MAC=${mac}  (${vp})")
        done
        local usb_idx=0
        pick_menu usb_idx "Which USB NIC?" "${usb_opts[@]}"
        usb_iface=${available_usb[$usb_idx]}
      fi

      SESSION_CLAIMED_USB+=("$usb_iface")
      ok "Reserved ${usb_iface} for ${vm_label} vNIC${nic_num}"
    fi

    # IP / subnet
    prompt_required ip_cidr "Static IP and prefix for ${net_label} (e.g. 10.15.140.101/25)"

    # Gateway — only for one NIC (the default route NIC)
    gw=""
    if confirm "Is this the default-route NIC for ${vm_label}?"; then
      prompt_required gw "Default gateway"
    fi

    # DNS
    prompt_default dns "DNS server" "8.8.8.8"

    # Store
    VM_NICS_TYPE+=("$nic_type")
    VM_NICS_LABEL+=("$net_label")
    VM_NICS_BRIDGE+=("${bridge_name:-}")
    VM_NICS_USB+=("${usb_iface:-}")
    VM_NICS_IP+=("$ip_cidr")
    VM_NICS_GW+=("$gw")
    VM_NICS_DNS+=("$dns")

    (( nic_num++ ))
    confirm "Add another NIC to ${vm_label}?" || break
  done
}

# Bridge → physical NIC map (populated during NIC config)
declare -A BRIDGE_IFACE_MAP

# -----------------------------------------------------------------------------
# Configure Server VM
# -----------------------------------------------------------------------------
if $CREATE_SERVER; then
  header "RideStatus Server VM — NIC Configuration"
  configure_vm_nics "Server VM"
  SERVER_NICS_TYPE=("${VM_NICS_TYPE[@]}")
  SERVER_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  SERVER_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}")
  SERVER_NICS_USB=("${VM_NICS_USB[@]}")
  SERVER_NICS_IP=("${VM_NICS_IP[@]}")
  SERVER_NICS_GW=("${VM_NICS_GW[@]}")
  SERVER_NICS_DNS=("${VM_NICS_DNS[@]}")
fi

# -----------------------------------------------------------------------------
# Configure Ansible VM
# -----------------------------------------------------------------------------
if $CREATE_ANSIBLE; then
  header "Ansible Controller VM — NIC Configuration"
  configure_vm_nics "Ansible VM"
  ANSIBLE_NICS_TYPE=("${VM_NICS_TYPE[@]}")
  ANSIBLE_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  ANSIBLE_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}")
  ANSIBLE_NICS_USB=("${VM_NICS_USB[@]}")
  ANSIBLE_NICS_IP=("${VM_NICS_IP[@]}")
  ANSIBLE_NICS_GW=("${VM_NICS_GW[@]}")
  ANSIBLE_NICS_DNS=("${VM_NICS_DNS[@]}")
fi

# -----------------------------------------------------------------------------
# VM IDs
# -----------------------------------------------------------------------------
header "VM IDs"

next_free_vmid() {
  local id=100
  while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${id}/status" &>/dev/null 2>&1; do
    (( id++ ))
  done
  echo $id
}

pick_vmid() {
  local -n _vmid=$1
  local label=$2
  local suggested; suggested=$(next_free_vmid)
  while true; do
    prompt_default _vmid "VM ID for ${label}" "$suggested"
    if pvesh get "/nodes/${PROXMOX_NODE}/qemu/${_vmid}/status" &>/dev/null 2>&1; then
      warn "VM ID ${_vmid} is already in use."
      suggested=$(next_free_vmid)
      warn "Next available ID: ${suggested}"
    else
      break
    fi
  done
}

if $CREATE_SERVER;  then pick_vmid SERVER_VMID  "RideStatus Server"; fi
if $CREATE_ANSIBLE; then pick_vmid ANSIBLE_VMID "Ansible Controller"; fi

# -----------------------------------------------------------------------------
# VM resources and hostnames
# -----------------------------------------------------------------------------
header "VM Resources"

if $CREATE_SERVER; then
  prompt_default SERVER_RAM   "Server VM RAM (GB)"   "4"
  prompt_default SERVER_CORES "Server VM CPU cores"  "2"
  prompt_default SERVER_DISK  "Server VM disk (GB)"  "32"
  prompt_default SERVER_HOST  "Server VM hostname"   "ridestatus-server"
fi

if $CREATE_ANSIBLE; then
  prompt_default ANSIBLE_RAM   "Ansible VM RAM (GB)"  "2"
  prompt_default ANSIBLE_CORES "Ansible VM CPU cores" "2"
  prompt_default ANSIBLE_DISK  "Ansible VM disk (GB)" "20"
  prompt_default ANSIBLE_HOST  "Ansible VM hostname"  "ridestatus-ansible"
fi

# SSH public key for cloud-init (tech's key, so they can SSH into the VMs)
prompt_required ADMIN_SSH_PUBKEY "Admin SSH public key (paste the full public key line)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
header "Summary — Review Before Proceeding"

print_vm_summary() {
  local label=$1 vmid=$2 hostname=$3 ram=$4 cores=$5 disk=$6
  local -n nics_type=$7 nics_label=$8 nics_bridge=$9 nics_usb=${10} nics_ip=${11} nics_gw=${12}
  echo -e "  ${BOLD}${label}${RESET}"
  echo "    VM ID:    ${vmid}"
  echo "    Hostname: ${hostname}"
  echo "    RAM:      ${ram}GB    Cores: ${cores}    Disk: ${disk}GB"
  for i in "${!nics_type[@]}"; do
    local conn=""
    if [[ "${nics_type[$i]}" == "bridge" ]]; then
      conn="bridge=${nics_bridge[$i]}"
    else
      conn="USB passthrough=${nics_usb[$i]} (${USB_NIC_VENDOR_PRODUCT[${nics_usb[$i]}]:-unknown})"
    fi
    local gw_str=""
    [[ -n "${nics_gw[$i]:-}" ]] && gw_str="  GW=${nics_gw[$i]}"
    echo "    vNIC$((i+1)):   ${nics_label[$i]}  IP=${nics_ip[$i]}${gw_str}  [${conn}]"
  done
}

echo ""
if $CREATE_SERVER; then
  print_vm_summary "RideStatus Server" "$SERVER_VMID" "$SERVER_HOST" "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    SERVER_NICS_TYPE SERVER_NICS_LABEL SERVER_NICS_BRIDGE SERVER_NICS_USB SERVER_NICS_IP SERVER_NICS_GW
fi
echo ""
if $CREATE_ANSIBLE; then
  print_vm_summary "Ansible Controller" "$ANSIBLE_VMID" "$ANSIBLE_HOST" "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_LABEL ANSIBLE_NICS_BRIDGE ANSIBLE_NICS_USB ANSIBLE_NICS_IP ANSIBLE_NICS_GW
fi

echo ""
warn "This will create VMs and modify network configuration on this Proxmox host."
read -rp "$(echo -e "${BOLD}Type 'yes' to proceed or anything else to abort: ${RESET}")" final_confirm
[[ "$final_confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# -----------------------------------------------------------------------------
# Helper: create Linux bridge if it doesn't exist
# -----------------------------------------------------------------------------
ensure_bridge() {
  local bridge=$1
  if ! ip link show "$bridge" &>/dev/null; then
    local phys=${BRIDGE_IFACE_MAP[$bridge]:-}
    info "Creating bridge ${bridge}" "${phys:+(attached to ${phys})}"
    # Write persistent Proxmox network config
    local net_conf="/etc/network/interfaces.d/${bridge}"
    {
      echo "auto ${bridge}"
      echo "iface ${bridge} inet manual"
      echo "  bridge_ports ${phys:-none}"
      echo "  bridge_stp off"
      echo "  bridge_fd 0"
    } > "$net_conf"
    ifup "$bridge" || true
    ok "Bridge ${bridge} created"
  else
    info "Bridge ${bridge} already exists — skipping"
  fi
}

# -----------------------------------------------------------------------------
# Helper: download Ubuntu 24.04 cloud image
# -----------------------------------------------------------------------------
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"

ensure_ubuntu_image() {
  if [[ -f "$UBUNTU_IMG_PATH" ]]; then
    info "Ubuntu 24.04 cloud image already cached at ${UBUNTU_IMG_PATH}"
  else
    info "Downloading Ubuntu 24.04 cloud image..."
    mkdir -p "$(dirname "$UBUNTU_IMG_PATH")"
    wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL" || die "Failed to download Ubuntu image"
    ok "Image downloaded"
  fi
}

# -----------------------------------------------------------------------------
# Helper: build cloud-init network config for a VM
# Returns a multi-line string written to a temp file
# Usage: build_cloud_init_network <tmpfile> nics_ip[] nics_gw[] nics_dns[]
# -----------------------------------------------------------------------------
build_cloud_init_userdata() {
  local outfile=$1 hostname=$2 ssh_pubkey=$3
  cat > "$outfile" <<EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
users:
  - name: ridestatus
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_pubkey}
package_update: true
packages:
  - curl
  - git
  - ca-certificates
runcmd:
  - mkdir -p /home/ridestatus/.ssh
  - chown -R ridestatus:ridestatus /home/ridestatus
EOF
}

# -----------------------------------------------------------------------------
# Helper: create and start a VM
# -----------------------------------------------------------------------------
create_vm() {
  local vmid=$1 hostname=$2 ram_gb=$3 cores=$4 disk_gb=$5
  local -n cn_type=$6 cn_bridge=$7 cn_usb=$8 cn_ip=$9 cn_gw=${10} cn_dns=${11}

  info "Creating VM ${vmid} (${hostname})..."

  local ram_mb=$(( ram_gb * 1024 ))
  local storage="local-lvm"

  # Create base VM
  qm create "$vmid" \
    --name "$hostname" \
    --memory "$ram_mb" \
    --cores "$cores" \
    --cpu cputype=host \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket --vga serial0

  # Import cloud image disk
  local img_copy="/tmp/ridestatus-vm${vmid}.img"
  cp "$UBUNTU_IMG_PATH" "$img_copy"
  qm importdisk "$vmid" "$img_copy" "$storage" --format qcow2
  rm -f "$img_copy"

  # Attach disk and set boot order
  qm set "$vmid" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${storage}:vm-${vmid}-disk-0,discard=on" \
    --boot order=scsi0

  # Resize disk
  qm resize "$vmid" scsi0 "${disk_gb}G"

  # Attach vNICs
  for i in "${!cn_type[@]}"; do
    if [[ "${cn_type[$i]}" == "bridge" ]]; then
      qm set "$vmid" --net${i} "virtio,bridge=${cn_bridge[$i]}"
    else
      # USB passthrough NIC — attach USB device; NIC appears inside VM via passthrough
      local vp=${USB_NIC_VENDOR_PRODUCT[${cn_usb[$i]}]:-}
      [[ -z "$vp" ]] && die "Cannot find vendor:product for USB NIC ${cn_usb[$i]}"
      qm set "$vmid" --usb${i} "host=${vp}"
      # Note: no --net entry for USB passthrough — the NIC appears directly in the VM
    fi
  done

  # Build cloud-init userdata
  local ci_userdata="/tmp/ridestatus-ci-${vmid}-user.yaml"
  build_cloud_init_userdata "$ci_userdata" "$hostname" "$ADMIN_SSH_PUBKEY"

  # Build cloud-init network config (static IPs)
  local ci_network="/tmp/ridestatus-ci-${vmid}-net.yaml"
  {
    echo "version: 2"
    echo "ethernets:"
    local eth_idx=0
    for i in "${!cn_type[@]}"; do
      # For bridged NICs, the VM sees a virtio NIC (ens18, ens19, etc.)
      # For USB passthrough, the NIC name inside the VM is unpredictable —
      # we use match by mac address which cloud-init supports.
      # We can't know the USB NIC's MAC from the host before the VM boots,
      # so we fall back to eth${eth_idx} and note that the tech may need
      # to adjust the interface name post-boot for USB passthrough NICs.
      local iface_name="ens$((18 + i))"
      if [[ "${cn_type[$i]}" == "usb" ]]; then
        iface_name="eth${eth_idx}"  # best-effort; may need manual adjustment
      fi
      local ip=${cn_ip[$i]}
      local gw=${cn_gw[$i]:-}
      local dns=${cn_dns[$i]:-8.8.8.8}
      echo "  ${iface_name}:"
      echo "    addresses: [${ip}]"
      [[ -n "$gw" ]] && echo "    gateway4: ${gw}"
      echo "    nameservers:"
      echo "      addresses: [${dns}]"
      (( eth_idx++ ))
    done
  } > "$ci_network"

  # Create cloud-init drive and attach
  local ci_storage_path="/var/lib/vz/snippets"
  mkdir -p "$ci_storage_path"
  cp "$ci_userdata"  "${ci_storage_path}/vm-${vmid}-user.yaml"
  cp "$ci_network"   "${ci_storage_path}/vm-${vmid}-net.yaml"
  rm -f "$ci_userdata" "$ci_network"

  qm set "$vmid" \
    --ide2 local:cloudinit \
    --cicustom "user=local:snippets/vm-${vmid}-user.yaml,network=local:snippets/vm-${vmid}-net.yaml"

  ok "VM ${vmid} configured"
}

# -----------------------------------------------------------------------------
# Helper: wait for SSH to become available on a VM
# -----------------------------------------------------------------------------
wait_for_ssh() {
  local ip=$1 max_wait=180 elapsed=0
  # Strip prefix length if present
  ip=${ip%%/*}
  info "Waiting for SSH on ${ip} (up to ${max_wait}s)..."
  while (( elapsed < max_wait )); do
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
      "ridestatus@${ip}" 'exit 0' &>/dev/null && { ok "SSH available on ${ip}"; return 0; }
    sleep 5
    (( elapsed += 5 ))
    echo -n "."
  done
  echo ""
  die "Timed out waiting for SSH on ${ip}"
}

# Find the first NIC IP for a VM (used for SSH connection)
first_ip() {
  local -n _nics_ip=$1
  echo "${_nics_ip[0]}"
}

# -----------------------------------------------------------------------------
# Helper: run bootstrap script inside a VM via SSH
# -----------------------------------------------------------------------------
BOOTSTRAP_BASE_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap"

run_bootstrap() {
  local ip=$1 script=$2
  ip=${ip%%/*}
  info "Running ${script} on ${ip}..."
  ssh -o StrictHostKeyChecking=no "ridestatus@${ip}" \
    "curl -fsSL '${BOOTSTRAP_BASE_URL}/${script}' | sudo bash" || {
    echo ""
    err "Bootstrap failed for ${script} on ${ip}."
    err "To retry manually, SSH to ridestatus@${ip} and run:"
    err "  curl -fsSL '${BOOTSTRAP_BASE_URL}/${script}' | sudo bash"
    return 1
  }
  ok "${script} completed on ${ip}"
}

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------
header "Creating Bridges"

for bridge in "${!BRIDGE_IFACE_MAP[@]}"; do
  ensure_bridge "$bridge"
done

ensure_ubuntu_image

if $CREATE_SERVER; then
  header "Creating RideStatus Server VM (${SERVER_VMID})"
  create_vm "$SERVER_VMID" "$SERVER_HOST" "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    SERVER_NICS_TYPE SERVER_NICS_BRIDGE SERVER_NICS_USB SERVER_NICS_IP SERVER_NICS_GW SERVER_NICS_DNS
  qm start "$SERVER_VMID"
  ok "VM ${SERVER_VMID} started"
fi

if $CREATE_ANSIBLE; then
  header "Creating Ansible Controller VM (${ANSIBLE_VMID})"
  create_vm "$ANSIBLE_VMID" "$ANSIBLE_HOST" "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_BRIDGE ANSIBLE_NICS_USB ANSIBLE_NICS_IP ANSIBLE_NICS_GW ANSIBLE_NICS_DNS
  qm start "$ANSIBLE_VMID"
  ok "VM ${ANSIBLE_VMID} started"
fi

# Wait for SSH, then run bootstrap scripts
if $CREATE_SERVER; then
  server_ip=$(first_ip SERVER_NICS_IP)
  wait_for_ssh "$server_ip"
  run_bootstrap "$server_ip" "server.sh" || true
fi

if $CREATE_ANSIBLE; then
  ansible_ip=$(first_ip ANSIBLE_NICS_IP)
  wait_for_ssh "$ansible_ip"
  run_bootstrap "$ansible_ip" "ansible.sh" || true
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
header "Deployment Complete"

$CREATE_SERVER  && ok "RideStatus Server VM ${SERVER_VMID}  (${SERVER_HOST})  — $(first_ip SERVER_NICS_IP | sed 's|/.*||')"
$CREATE_ANSIBLE && ok "Ansible Controller VM ${ANSIBLE_VMID} (${ANSIBLE_HOST}) — $(first_ip ANSIBLE_NICS_IP | sed 's|/.*||')"

echo ""
info "Next steps:"
info "  1. Verify VMs are accessible via the Proxmox web UI"
info "  2. For any USB passthrough NICs, confirm the interface name inside the VM"
info "     (cloud-init uses eth0/eth1 as best-effort — adjust /etc/netplan/*.yaml if needed)"
info "  3. Run bootstrap/edge-init.sh on each ride edge node"
echo ""
