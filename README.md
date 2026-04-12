# ridestatus-deploy

> **Public** — Proxmox VM provisioning for RideStatus. Creates VMs, installs Docker, and starts services.

---

## How It Works

A single interactive script (`proxmox/deploy.sh`) handles everything:

1. Asks which VM to create (management plane, park board server, or edge node)
2. Collects VM sizing, networking, and role-specific config via a dialog TUI
3. Creates the VM from an Ubuntu 24.04 cloud image
4. Installs Docker on the new VM
5. Drops the correct `docker-compose.yml` and `.env` onto the VM
6. Pulls images from `ghcr.io` and starts services

No bootstrap scripts. No PM2. No manual steps after the script finishes.

---

## Prerequisites

Run on the Proxmox host as root. On a standard Proxmox installation, only two packages may need to be installed:

```bash
apt install -y dialog jq
```

Everything else (`curl`, `wget`, `python3`, `ssh`) is already present on Proxmox (Debian-based).

You will also need:
- A **GitHub personal access token** with `read:packages` scope (to pull images from `ghcr.io/ridestatus`)
- For the **manage** role: the Proxmox API password for `root@pam` (used to fill the `.env` so the management UI can provision VMs)

---

## Usage

Run this on the Proxmox host as root:

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/RideStatus/ridestatus-deploy/contents/proxmox/deploy.sh" \
  -o /tmp/deploy.sh && bash /tmp/deploy.sh
```

The script walks you through everything interactively. No flags, no config files to edit first.

---

## Deployment Order

Always deploy in this order:

| Step | Role | Proxmox Host | VM ID | IP |
|------|------|-------------|-------|----|
| 1 | `manage` — Management Plane | PVE-SCADA1 | 300 | 10.250.5.101/19 |
| 2 | `server` — Park Board Server | PVE-SCADA2 | 300 | 10.250.5.102/19 |
| 3 | `edge` — Edge Node (per ride) | either host | 301+ | assigned per ride |

The management plane must exist before edge nodes are deployed, because it is the tool that deploys them.

---

## Repository Structure

```
ridestatus-deploy/
├── proxmox/
│   └── deploy.sh              # The one script that does everything
└── compose/
    ├── manage/
    │   └── docker-compose.yml  # Pulled by deploy.sh for management plane VM
    ├── server/
    │   └── docker-compose.yml  # Pulled by deploy.sh for park board server VM
    └── edge/
        └── docker-compose.yml  # Pulled by deploy.sh for edge node VMs
```

The `compose/` files are minimal production stacks that reference images from `ghcr.io/ridestatus`. They are downloaded by `deploy.sh` at deploy time and dropped onto the target VM — they are never cloned or edited manually.

---

## VM Sizing Defaults

| Role | RAM | CPU | Disk |
|------|-----|-----|------|
| manage | 2 GB | 2 | 20 GB |
| server | 4 GB | 2 | 64 GB |
| edge | 2 GB | 2 | 20 GB |

---

## After Deployment

**Management Plane** (`manage`):
- UI: `http://10.250.5.101:3000`
- Default login: `admin` / `admin` — **change immediately**
- Self-update runs every 30 minutes via cron, or use the Dashboard button

**Park Board Server** (`server`):
- UI: `http://10.250.5.102:3000`
- The Bootstrap Token and API Key are shown at the end of deploy — save them

**Edge Nodes**: deployed and managed through the Management Plane UI, not by running this script directly.

---

## Security Notes

- `.env` files are never committed — only `.env.example` templates live in application repos
- PostgreSQL listens on the Docker internal network only
- The GitHub token collected during deploy is stored in the VM's `.env` for self-update; it only needs `read:packages` scope
