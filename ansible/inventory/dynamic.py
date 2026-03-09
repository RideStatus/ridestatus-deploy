#!/usr/bin/env python3
# =============================================================================
# RideStatus — Dynamic Ansible Inventory
# Fetches registered nodes from the RideStatus server API.
#
# Usage:
#   ansible-playbook -i inventory/dynamic.py playbooks/deploy.yml
#
# Required env vars (or set in /etc/ridestatus/ansible.env):
#   RIDESTATUS_SERVER_HOST  — server VM dept IP (e.g. 10.15.140.101)
#   RIDESTATUS_SERVER_PORT  — API port (default: 3100)
#   RIDESTATUS_API_KEY      — X-Api-Key header value
#
# The script sources /home/ridestatus/.env if env vars are not set.
# =============================================================================

import json
import os
import sys
import urllib.request
import urllib.error

ENV_FILE = '/home/ridestatus/.env'

def load_env_file(path):
    """Load KEY=VALUE pairs from a .env file into os.environ (no overwrite)."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k and k not in os.environ:
                    os.environ[k] = v
    except FileNotFoundError:
        pass

def fetch_nodes(host, port, api_key):
    url = f'http://{host}:{port}/api/v1/nodes'
    req = urllib.request.Request(url, headers={
        'X-Api-Key': api_key,
        'Accept': 'application/json',
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        print(f'[dynamic.py] ERROR: could not reach {url}: {e}', file=sys.stderr)
        return []

def build_inventory(nodes):
    inventory = {
        '_meta': {'hostvars': {}},
        'all': {'children': ['edge_nodes', 'ungrouped']},
        'edge_nodes': {'hosts': []},
    }

    for node in nodes:
        # Use the dept/RideStatus NIC IP as Ansible host
        dept_ip = node.get('ridestatus_nic_ip') or node.get('dept_ip')
        ride_name = node.get('ride_name', '')

        if not dept_ip or not ride_name:
            continue

        # Sanitise ride name to a valid Ansible hostname key
        host_key = ride_name.lower().replace(' ', '_').replace('-', '_')

        inventory['edge_nodes']['hosts'].append(host_key)
        inventory['_meta']['hostvars'][host_key] = {
            'ansible_host': dept_ip,
            'ride_name':    ride_name,
            'ride_nic_ip':  node.get('ride_nic_ip', ''),
            'node_id':      node.get('id', ''),
            'last_seen':    node.get('last_seen', ''),
        }

    return inventory

def main():
    load_env_file(ENV_FILE)

    host    = os.environ.get('RIDESTATUS_SERVER_HOST') or os.environ.get('SERVER_HOST', '')
    port    = os.environ.get('RIDESTATUS_SERVER_PORT') or os.environ.get('SERVER_PORT', '3100')
    api_key = os.environ.get('RIDESTATUS_API_KEY')    or os.environ.get('SERVER_API_KEY', '')

    if not host or not api_key:
        print('[dynamic.py] ERROR: RIDESTATUS_SERVER_HOST and RIDESTATUS_API_KEY must be set',
              file=sys.stderr)
        print(json.dumps({'_meta': {'hostvars': {}}, 'edge_nodes': {'hosts': []}}))
        sys.exit(0)

    if '--list' in sys.argv or len(sys.argv) == 1:
        nodes = fetch_nodes(host, port, api_key)
        print(json.dumps(build_inventory(nodes), indent=2))
    elif '--host' in sys.argv:
        # Per-host vars already embedded in _meta — return empty dict
        print(json.dumps({}))
    else:
        print(json.dumps({'_meta': {'hostvars': {}}, 'edge_nodes': {'hosts': []}}))

if __name__ == '__main__':
    main()
