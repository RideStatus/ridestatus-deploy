# ridestatus-deploy

> **Public** — Proxmox VM bootstrap & deployment automation for RideStatus edge nodes and server VMs.

See [docs/](docs/) for full documentation.

## Repository Structure

```
ridestatus-deploy/
├── bootstrap/
│   ├── ride-node.sh          # Bootstrap script for a Ride Edge Node VM
│   ├── server.sh             # Bootstrap script for the Aggregation Server VM
│   └── common.sh             # Shared functions (logging, Node.js install, firewall)
├── proxmox/
│   ├── create-ride-vm.sh     # Proxmox CLI wrapper: creates & provisions a Ride VM
│   ├── create-server-vm.sh   # Proxmox CLI wrapper: creates & provisions the Server VM
│   └── vm-defaults.conf      # Default VM sizing (CPU, RAM, disk) — edit per park
├── config/
│   ├── ride-node.env.example # Environment variable template for a Ride Edge Node
│   └── server.env.example    # Environment variable template for the Server
└── docs/
    └── proxmox-setup.md      # One-time Proxmox host prerequisites
```

## Quick Start

```bash
# Provision the Aggregation Server
cp config/server.env.example config/server.env
# Edit config/server.env with your park's values
bash proxmox/create-server-vm.sh --config config/server.env

# Provision a Ride Edge Node (repeat per ride)
cp config/ride-node.env.example config/ride-node.env
# Edit: set RIDE_NAME, PLC_IP, PLC_PROTOCOL, SERVER_HOST, etc.
bash proxmox/create-ride-vm.sh --config config/ride-node.env
```

## VM Sizing Defaults

| Role              | vCPUs | RAM   | Disk  |
|-------------------|-------|-------|-------|
| Ride Edge Node    | 2     | 2 GB  | 20 GB |
| Aggregation Server| 4     | 8 GB  | 60 GB |

## Security Notes

- **Never commit real `.env` files.** Only commit `.env.example` templates.
- The Aggregation Server API port should NOT be exposed to the public internet.
- PostgreSQL should only listen on the management VLAN interface.

## License

MIT
