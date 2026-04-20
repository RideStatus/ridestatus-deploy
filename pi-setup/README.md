# Pi Setup Guide

This guide covers how to prepare a Raspberry Pi 4 for use as a RideStatus edge node.

## Hardware Requirements

- Raspberry Pi 4 (any RAM variant)
- MicroSD card (16GB minimum, 32GB recommended)
- USB Ethernet adapter (ASIX AX88179 or compatible) for the corporate/field network
- Built-in Ethernet (`eth0`) for the ride/PLC network

## OS

**Raspberry Pi OS Lite (64-bit, Bookworm)** 
Do not use the Ubuntu Raspberry Pi image — USB NICs do not reliably start on first boot.

## Flashing the SD Card

1. Download and open **Raspberry Pi Imager**
2. Choose **Raspberry Pi 4** as the device
3. Choose **Raspberry Pi OS Lite (64-bit)** as the OS
4. Choose your SD card
5. Click the **gear icon** (OS Customisation) and set:

   | Setting | Value |
   |---------|-------|
   | Hostname | `ridestatus` |
   | Username | `ridestatus` |
   | Password | `RideControl` |
   | Enable SSH | Yes — Password authentication |

6. Click **Save**, then **Write**

## How It Works

Raspberry Pi OS Bookworm uses **NetworkManager**, which automatically creates DHCP connection profiles for all detected network interfaces — including the USB Ethernet adapter — on first boot. No additional network configuration files are needed.

When the Pi boots with both NICs connected:
- `eth0` (built-in) will request a DHCP address from whatever server is on the ride/PLC network
- The USB NIC (`enx...`) will request a DHCP address from the RideStatus management server (`ridestatus-manage`) on the corporate VLAN, receiving an IP in the provisioning range (`10.15.140.90–99`)

The hostname `ridestatus` is what allows the Deploy page to discover the Pi during a network scan.

## Provisioning

Once the Pi is booted and connected to both networks:

1. In the RideStatus management UI, go to **Deploy**
2. Enter the corporate VLAN subnet (e.g. `10.15.140.0/25`) and the SSH password (`RideControl`)
3. Click **Scan** — the Pi will appear with hostname `ridestatus` and its DHCP address
4. Click **Provision**, fill in the ride name, static IP, PLC details, and NIC assignments
5. The provisioner will SSH in, set a static IP, install Docker, pull the edge image, and register the node

## NIC Assignment During Provisioning

The provisioning form will show a dropdown of actual interface names from the Pi. Select:
- **Ride Network NIC**: the interface connected to the PLC (`eth0` on most Pis, but verify)
- **RideStatus Network NIC**: the USB NIC connected to the corporate VLAN (`enx...`)

The USB NIC name is based on its MAC address and will look like `enxc8a362a8bf8a`. The dropdown will show the actual name — just pick the one that isn’t `eth0`.

## Notes

- The provisioning process installs the admin SSH key so subsequent access uses key-based auth
- After provisioning the Pi’s static IP is set via netplan on the RideStatus NIC
- The DHCP lease (temporary IP) will expire after 1 hour and free up the slot for the next Pi
- Do not set a static IP in Pi Imager — leave networking as DHCP so the Pi is discoverable
