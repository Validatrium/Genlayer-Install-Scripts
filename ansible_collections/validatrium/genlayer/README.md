# Validatrium GenLayer Ansible Collection

This collection installs and manages **GenLayer** validator nodes with:
- versioned installs under `/opt/genlayer/<version>` with a `current` symlink
- generated `configs/node/config.yaml` using your ZKSync endpoints
- validator account creation (one-time) and **encrypted key backup**
- **systemd** service and a **daily backup timer**
- optional WebDriver start via Docker Compose when present

## Content

- Role: `validatrium.genlayer.validator`
- Lookup plugin: `validatrium.genlayer.gl_latest_version` (resolves latest version from GCS)

## Quickstart

Inventory (example):
```ini
[genlayer_nodes]
node1 ansible_host=1.2.3.4
```

Playbook:
```yaml
- hosts: genlayer_nodes
  become: true
  collections:
    - validatrium.genlayer
  roles:
    - role: validator
      vars:
        zksync_http: "https://YOUR-ZKSYNC-HTTP"
        zksync_ws: "wss://YOUR-ZKSYNC-WS"
        genlayer_version: "latest"
        genlayer_password: "CHANGE_ME"
        backup_passphrase: "CHANGE_ME_BACKUP"
```

Run:
```bash
ansible-galaxy collection install ./validatrium-genlayer-1.0.0.tar.gz
ansible-playbook -i inventory.ini playbooks/install.yml
```

## Variables

See `roles/validator/defaults/main.yml`

## License

MIT © Validatrium
