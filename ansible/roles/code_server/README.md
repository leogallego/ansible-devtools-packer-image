# code_server

Install and configure [code-server](https://github.com/coder/code-server) (VS Code in the browser) with an nginx reverse proxy.

## Requirements

- RHEL 9 (or compatible) target host
- `become: true` at the play level (the role requires root for package installation and systemd)

## Role Variables

All user-facing variables are defined in `defaults/main.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `code_server_version` | `"4.115.0"` | Version of code-server to install |
| `code_server_rpm_url` | GitHub release URL built from version | URL to the code-server RPM package |
| `code_server_username` | `"rhel"` | System user to run code-server as |
| `code_server_password` | `"ansible123!"` | code-server admin password |
| `code_server_prebuild` | `false` | When `true`, skip install and only reconfigure |
| `code_server_authentication` | `false` | Enable code-server password authentication |
| `code_server_extensions` | Ansible + Markdown extensions | List of VS Code extensions to install |

### Extensions format

```yaml
code_server_extensions:
  # Install from marketplace by name
  - name: redhat.ansible

  # Install from a downloaded file
  - filename: my-extension.vsix

  # Download and install from URL
  - download_url: https://example.com/extension.vsix
    filename: extension.vsix
```

## Entrypoints

| Entrypoint | Description |
|------------|-------------|
| `main` | Routes to `install` or `configure` based on `code_server_prebuild` |
| `install` | Full installation: code-server RPM, systemd service, VS Code settings, extensions, nginx |
| `configure` | Reconfigures the systemd service file and restarts code-server (for runtime use) |

## Idempotency

**Partially idempotent.** The install entrypoint is designed for single-use during image builds. The configure entrypoint is idempotent and safe to run multiple times.

## Rollback

No automated rollback is provided. To remove code-server manually:

```bash
systemctl disable --now code-server
dnf remove code-server
rm -f /etc/systemd/system/code-server.service
rm -f /etc/nginx/default.d/vscode.conf
systemctl restart nginx
```

## Example Playbook

```yaml
---
- name: Install code-server
  hosts: all
  become: true
  tasks:
    - name: Install and configure code-server
      ansible.builtin.include_role:
        name: code_server
      vars:
        code_server_username: "student"
        code_server_password: "my_password"
        code_server_authentication: true
```

Reconfigure an existing installation at runtime:

```yaml
---
- name: Reconfigure code-server
  hosts: all
  become: true
  tasks:
    - name: Update code-server configuration
      ansible.builtin.include_role:
        name: code_server
      vars:
        code_server_prebuild: true
        code_server_username: "student"
        code_server_password: "new_password"
        code_server_authentication: true
```

## License

GPL-3.0-or-later
