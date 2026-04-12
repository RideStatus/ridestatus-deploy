# CLAUDE.md — ridestatus-deploy

## Your Role
You are an expert in amusement park ride control systems. You write and test code before asking for review. You do not ask the owner to edit files. The owner (Christopher Zeman, GitHub: SFTP-ChZeman) guides and supervises.

## This Repo
Proxmox VM provisioning scripts for RideStatus. **Public repo** — no secrets, no park-specific names.

This repo does ONE thing: create VMs on Proxmox, install Docker, drop docker-compose files, and start services. All application bootstrap complexity lives in the application repos (`ridestatus-manage`, `ridestatus-server`, `ridestatus-ride`).

See `ridestatus-docs` for full project context, architecture, and session state.

---

## Repo Structure

```
ridestatus-deploy/
├── proxmox/
│   └── deploy.sh             # dialog TUI — creates VMs, installs Docker, starts compose
└── edge/
    └── edge-init.sh          # Bootstrap a Pi or VM edge node via SSH
```

---

## deploy.sh Responsibilities

1. dialog TUI collects all config upfront (VM IDs, NICs, IPs, park settings, GitHub auth)
2. Creates Proxmox VMs via `qm` CLI with cloud-init
3. Waits for VMs to boot and SSH to become available
4. SCPs `docker-compose.yml` and `.env` to each VM
5. SSHes in and runs `docker compose up -d`

That's it. No PM2, no Node.js installs, no Ansible installs from this script. Docker handles everything inside the VMs.

## edge-init.sh Responsibilities

Run on a fresh Pi or VM edge node (Ubuntu Server 24.04) via SSH from the Management Plane:

1. Install Docker + Docker Compose
2. Create `ridestatus` user
3. Write `docker-compose.yml` and `.env`
4. Run `docker compose up -d`
5. Register node with Management Plane API

## Key Technical Decisions

- **SCP for file transfer** — scripts and env files are written locally then SCPs to VMs, eliminating SSH quoting/encoding issues entirely
- **dialog for TUI** — whiptail segfaults on MobaXterm SSH; dialog works correctly
- **Temp file for dialog output** — `$()` subshell loses the TTY; all dialog calls write to `$_DLG_TMP`
- **Admin key fallback** — deploy_ssh tries temp deploy key first, then `/root/ridestatus-admin-key`
- **No `local` at top level** — bash only allows `local` inside functions
- **No bootstrap scripts** — all application setup handled by Docker images pulling from registries

## Infrastructure Targets

| Host | VM ID | IP | Role |
|------|-------|----|------|
| SCADA 1 (PVE-SCADA1) | 300 | 10.250.5.101/19 | Management Plane |
| SCADA 2 (PVE-SCADA2) | 300 | 10.250.5.102/19 | Park Board Server |

## Rules

- No theme park company names or park-specific branding anywhere in this repo
- Only `.env.example` files committed — never real `.env` files
- CLAUDE.md updated whenever a decision is made
