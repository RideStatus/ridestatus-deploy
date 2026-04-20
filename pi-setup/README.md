# Ride Status — Raspberry Pi Setup Guide

This guide covers how to prepare a Raspberry Pi 4 for use as a Ride Status edge node.

---

## Requirements

- Raspberry Pi 4 (any RAM variant)
- MicroSD card (16GB minimum, 32GB recommended)
- USB NIC (ASIX AX88179 or compatible) for the RideStatus corporate VLAN
- A computer with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) installed

---

## Step 1 — Flash the SD Card

1. Open **Raspberry Pi Imager**
2. **Choose Device**: Raspberry Pi 4
3. **Choose OS**: Raspberry Pi OS Lite (64-bit) — under *Raspberry Pi OS (other)*
4. **Choose Storage**: select your SD card
5. Click **Next**, then click **Edit Settings** when prompted

### OS Customisation Settings

| Setting | Value |
|---------|-------|
| Hostname | `ridestatus-ride` |
| Username | `ridestatus` |
| Password | `RideControl` |
| Enable SSH | Yes — Password authentication |
| Locale / Timezone | Set as appropriate for your region |

> **Important:** The hostname must be `ridestatus-ride`. The Deploy page scans
> for devices with `ridestatus` in their hostname to discover new Pis.

6. Click **Save**, then **Yes** to apply customisation
7. Confirm the flash and wait for it to complete

---

## Step 2 — Insert and Boot

1. Insert the SD card into the Pi
2. Connect the USB NIC to a USB 3.0 port (blue port) on the Pi
3. Connect the USB NIC to the RideStatus corporate VLAN switch port
4. Power on the Pi

The Pi will boot and both NICs will come up via DHCP automatically:
- `eth0` — built-in NIC (ride/PLC network, or unconnected)
- `enx...` — USB NIC (RideStatus corporate VLAN)

The USB NIC will receive a DHCP lease from the `ridestatus-manage` server
in the range `10.15.140.90`–`10.15.140.99`.

> **Note:** First boot takes 2–3 minutes while the system initializes and SSH starts.

---

## Step 3 — Provision via Management UI

1. Open the Ride Status Management UI at `http://10.15.140.101:3000`
2. Go to **Deploy**
3. Enter the SSH password (`RideControl`) and the DHCP subnet (`10.15.140.88/29`)
4. Click **Scan** — the new Pi will appear with hostname `ridestatus-ride`
5. Click **Provision** and fill in:
   - **Ride Name**: lowercase slug (e.g. `batman`)
   - **Display Name**: human-readable name (e.g. `Batman`)
   - **Static IP**: permanent IP for this Pi on the corporate VLAN (e.g. `10.15.140.13/25`)
   - **Gateway**: `10.15.140.1`
   - **PLC Protocol**: select appropriate protocol
   - **PLC IP**: IP address of the PLC on the ride network
   - **Ride Network NIC**: select `eth0` (built-in, connected to PLC network) or the USB NIC if wired differently
   - **RideStatus Network NIC**: select the `enx...` USB NIC (or `eth0` if wired differently)
6. Click **Provision Node**

Provisioning takes 5–10 minutes. The Pi will:
- Get a permanent static IP set via netplan
- Have Docker installed
- Pull and start the `ridestatus-ride` container
- Register in the management database

After provisioning the Pi will appear green on the Dashboard.

---

## NIC Notes

- Pi OS Bookworm uses **NetworkManager** which brings up all NICs (including USB) automatically
- The USB NIC is named using its MAC address (e.g. `enxc8a362a8bf8a`) — the exact name varies per device
- The NIC dropdowns in the Provision form show the actual interfaces on the Pi — no need to guess names
- At some rides `eth0` is the ride/PLC network; at others the USB NIC may be the ride network and `eth0` is RideStatus — select accordingly in the provision form

---

## Troubleshooting

**Pi doesn't appear in scan after boot:**
- Wait 3 minutes and scan again — first boot is slow
- Check the USB NIC has a link light
- Confirm the switch port is on the RideStatus VLAN and not port-locked to a different MAC
- Check dnsmasq leases on manage VM: `cat /var/lib/misc/dnsmasq.leases`

**SSH refused:**
- Confirm SSH was enabled in Pi Imager customisation
- Confirm hostname was set to `ridestatus-ride`
- Try connecting manually: `ssh ridestatus@<ip>`

**Provisioning fails at Docker pull:**
- The corporate VLAN requires internet access to pull from GHCR
- Confirm internet routing is working: `curl https://github.com` from the Pi
- If internet is not available on the VLAN, raise a network ticket
