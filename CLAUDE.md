# CLAUDE.md — ridestatus-deploy

## Your Role
You are an expert in amusement park ride control systems. You write and test code before asking for review. You do not ask the owner to edit files. The owner (Christopher Zeman, GitHub: SFTP-ChZeman) guides and supervises.

## This Repo
Proxmox VM bootstrap and deployment scripts for RideStatus edge nodes and the aggregation server. **Public repo** — no secrets, no park-specific names.

See `ridestatus-docs` for full project context, architecture, and session state.

---

## Repo Structure

```
ridestatus-deploy/
├── proxmox/
│   └── deploy.sh             # Interactive VM provisioner — run on Proxmox host as root
├── bootstrap/
│   ├── ansible.sh            # Ansible Controller VM bootstrap
│   ├── server.sh             # Aggregation Server VM bootstrap
│   ├── edge-init.sh          # Ride Edge Node bootstrap (Pi or VM)
│   ├── migrate-legacy.sh     # Migration from legacy system
│   └── common.sh             # Shared functions
├── ansible/
│   ├── site.yml              # Master playbook
│   ├── ansible.cfg
│   ├── inventory/            # hosts.yml written by server.sh
│   ├── group_vars/
│   ├── host_vars/            # Per-node config written by server API
│   ├── playbooks/            # deploy.yml, healthcheck.yml, update.yml, push_flows.yml
│   └── roles/
└── config/
    ├── ride-node.env.example
    └── server.env.example
```

---

## Key Facts

- `deploy.sh` run once on Proxmox host as root: `bash <(curl -fsSL ...)`
- All bootstrap script URLs use `?$(date +%s)` cache-busting suffix
- VM IDs: Ansible=400, Server=401 (lab; may differ at other sites)
- VM IPs (lab): Ansible=`10.250.30.100`, Server=`10.250.30.101`
- OS username: `ridestatus`, home `/home/ridestatus/`
- Ansible pubkey handoff: one-shot Python HTTP server on port 9876 on Ansible VM
- `--cicustom user=<snippet>` for cloud-init; `qm cloudinit update` before `qm start`

## Session 14 Pending Items

- [ ] **Remove park name picker from server.sh** — replace numbered list with `prompt_required PARK_NAME "Park name"` (white-label cleanup)
- [ ] **Audit all scripts** for theme park company references and remove them

## Rules

- No theme park company names or park-specific branding anywhere in this repo
- Only `.env.example` files committed — never real `.env` files
- CLAUDE.md updated whenever a decision is made
