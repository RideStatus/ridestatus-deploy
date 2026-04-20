# Raspberry Pi Setup Guide

This guide covers how to flash and prepare a Raspberry Pi 4 for use as a RideStatus edge node.

## Requirements

- Raspberry Pi 4 (any RAM variant)
- MicroSD card (16GB minimum, 32GB recommended)
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
- USB NIC (for corporate/field network connectivity)

---

## Flashing the SD Card

### 1. Open Raspberry Pi Imager

- **Device**: Raspberry Pi 4
- **OS**: Raspberry Pi OS Lite (64-bit) — under *Raspberry Pi OS (other)*
- **Storage**: Select your SD card

### 2. Open OS Customisation

Click the **Edit Settings** button (or press Ctrl+Shift+X) and configure:

| Setting | Value |
|---------|-------|
| Hostname | `ridestatus` |
| Username | `ridestatus` |
| Password | *(your site password)* |
| Enable SSH | ✓ — Password authentication |
| Locale / Timezone | Set to your local timezone |

> **Important:** The hostname must contain `ridestatus` — this is how the Deploy page scan identifies new Pis on the network.

### 3. Flash

Click **Save**, then **Yes** to apply customisation, then **Yes** to confirm flashing.

---

## Network Behaviour on First Boot

Raspberry Pi OS Bookworm uses **NetworkManager**, which automatically brings up all network interfaces via DHCP on first boot — including the USB NIC. No extra configuration files are needed on the boot partition.

When the Pi boots with the USB NIC connected to the corporate/field network:

- The USB NIC (`enx...`) will request a DHCP address from the RideStatus management server
- The Pi will receive an IP in the provisioning range (e.g. `10.15.140.90`–`10.15.140.99`)
- The Pi will appear in the **Deploy** page scan in the management UI

---

## Provisioning

Once the Pi appears in the Deploy page scan:

1. Click **Provision** next to the Pi
2. Fill in:
   - **Ride Name** — slug (e.g. `batman`)
   - **Display Name** — human name (e.g. `Batman`)
   - **Static IP / Prefix** — permanent IP for this Pi (e.g. `10.15.140.13/25`)
   - **Gateway** — `10.15.140.1`
   - **SSH Password** — the password set in Pi Imager
   - **PLC Protocol / IP / Slot** — PLC connection details
   - **Ride Network NIC** — NIC connected to the PLC network (select from dropdown)
   - **RideStatus Network NIC** — USB NIC connected to the corporate VLAN (select from dropdown)
3. Click **Provision Node**

The management server will SSH into the Pi, install Docker, pull the edge node image, configure the static IP, and register the node. The DHCP lease will expire within 1 hour and the IP will be available for the next Pi.

---

## NIC Identification

The Pi 4 built-in NIC is always `eth0`. The USB NIC is named by NetworkManager based on its MAC address, e.g. `enxc8a362a8bf8a`. The provision form fetches the actual interface names from the Pi automatically — the tech just selects the correct one from the dropdown for each role.

If unsure which is which:
- `eth0` = built-in RJ45 port on the Pi board itself
- `enx...` = USB NIC (plugged into a USB port)

---

## Troubleshooting

**Pi not appearing in scan after booting:**
- Confirm the USB NIC is plugged in and has a link light
- Confirm the Pi has been booted for at least 2 minutes (NetworkManager takes a moment to bring up interfaces)
- Check dnsmasq leases on the manage VM: `cat /var/lib/misc/dnsmasq.leases`
- Try scanning manually from the manage VM: `ping -c1 -I corp0 10.15.140.90` through `.99`

**SSH password rejected during provisioning:**
- Confirm the password matches what was set in Pi Imager
- The password field in the Scan form pre-fills into the Provision form — make sure it wasn't changed

**Pi shows up on old static IP instead of DHCP range:**
- The SD card may not have been freshly flashed — reflash and try again
