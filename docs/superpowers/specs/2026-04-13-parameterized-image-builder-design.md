# Parameterized Ansible Dev-Tools Image Builder

## Overview

Replace the current single-file packer + monolithic playbook with a parameterized build system that produces three image variants (pip, pip-pinned, rpm) from shared infrastructure. The image provides a browser-based Ansible development environment using code-server (VS Code) with ansible-dev-tools pre-installed on RHEL 9.

## Goals

- Single parameterized Packer HCL file — select variant via `-var="variant=pip"`, cloud target via `-only`
- Multi-cloud support: GCP (googlecompute) and AWS (amazon-ebs) sources in the same file
- GitHub Actions CI/CD: GCP workflow + AWS workflow with qcow2 export for RHDP
- Shared Ansible tasks extracted into reusable includes — no duplication across variants
- Self-contained code_server role adapted for standalone use (no instruqt/workshop dependencies)
- Clean image hygiene (cleanup tasks adapted from upstream)
- Sensible defaults, all configuration driven by variables

## Non-Goals

- EE pulling during image build (keep separate, requires registry credentials)
- AAP controller installation

---

## Repository Structure

```
packer-ansible-devtools-image/
  ansible-dev-tools.pkr.hcl              # single parameterized packer file (GCP + AWS sources)

  ansible/
    dev-tools-pip.yml                     # playbook: pip unpinned variant
    dev-tools-pip-pinned.yml              # playbook: pip pinned variant
    dev-tools-rpm.yml                     # playbook: rpm variant
    tasks/
      base_setup.yml                      # shared: user, sshd, test environment
      python_setup.yml                    # shared: python 3.11/3.12 pip install
      image_cleanup.yml                   # shared: end-of-build image hygiene
    roles/
      code_server/
        defaults/main.yml
        meta/argument_specs.yml
        tasks/
          main.yml
          install.yml                     # was codeserver.yml
          configure.yml                   # was codeserver_always.yml
        templates/
          code-server.service.j2
          code-server-nginx.conf.j2       # was nginx_instruqt.conf
          settings.json
    templates/
      rh-cloud.repo.j2                   # GCP RHUI repo configuration

  .github/
    workflows/
      build-gcp.yml                      # GCP image build (all variants)
      build-aws.yml                      # AWS image build + qcow2 export for RHDP
```

---

## Packer HCL Design

Single file `ansible-dev-tools.pkr.hcl` with both GCP and AWS sources. A `variant` variable drives image name and playbook selection via maps. Cloud target is selected via `-only`.

### Required Plugins

```hcl
packer {
    required_plugins {
        ansible = {
            version = ">= v1.1.2"
            source  = "github.com/hashicorp/ansible"
        }
        googlecompute = {
            version = ">= v1.1.6"
            source  = "github.com/hashicorp/googlecompute"
        }
        amazon = {
            version = ">= v1.3.0"
            source  = "github.com/hashicorp/amazon"
        }
    }
}
```

### Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `variant` | string | `"pip"` | Build variant: `pip`, `pip-pinned`, or `rpm` |
| `image_name` | string | `null` | Override auto-generated image name |
| `ssh_username` | string | `"rhel"` | SSH user for provisioning |
| `ansible_vars_file` | string | `null` | Extra Ansible vars file to pass |
| **GCP** | | | |
| `project_id` | string | `"red-hat-mbu"` | GCP project ID |
| `zone` | string | `"us-east1-d"` | GCP zone |
| `gcp_machine_type` | string | `"n1-standard-2"` | GCP build VM size |
| **AWS** | | | |
| `aws_region` | string | `"us-east-1"` | AWS region |
| `aws_instance_type` | string | `"t3.medium"` | AWS build instance type |

### Locals

```hcl
locals {
    image_names = {
        pip        = "ansible-dev-tools-pip"
        pip-pinned = "ansible-dev-tools-pip-pinned"
        rpm        = "ansible-dev-tools-rpm"
    }
    playbooks = {
        pip        = "dev-tools-pip.yml"
        pip-pinned = "dev-tools-pip-pinned.yml"
        rpm        = "dev-tools-rpm.yml"
    }
    timestamp           = formatdate("YYYYMMDD", timestamp())
    resolved_image_name = coalesce(var.image_name, "${local.image_names[var.variant]}-${local.timestamp}")
    resolved_playbook   = local.playbooks[var.variant]

    extra_args = concat(
        ["-e", "ansible_python_interpreter=/usr/bin/python3"],
        var.ansible_vars_file != null
            ? ["-e", var.ansible_vars_file]
            : ["--scp-extra-args", "'-O'"]
    )
}
```

Image names are date-stamped by default (e.g. `ansible-dev-tools-pip-20260413`). Override with `-var="image_name=custom-name"`.

### Sources

**GCP:**
```hcl
source "googlecompute" "ansible-dev-tools" {
    project_id          = var.project_id
    source_image_family = "rhel-9"
    ssh_username        = var.ssh_username
    zone                = var.zone
    machine_type        = var.gcp_machine_type
    image_name          = local.resolved_image_name
}
```

**AWS:**
```hcl
source "amazon-ebs" "ansible-dev-tools" {
    region        = var.aws_region
    source_ami_filter {
        filters = {
            name                = "RHEL-9*_HVM-*-x86_64-*-GP*"
            root-device-type    = "ebs"
            virtualization-type = "hvm"
        }
        most_recent = true
        owners      = ["309956199498"]  # Red Hat
    }
    instance_type = var.aws_instance_type
    ssh_username  = "ec2-user"
    ami_name      = local.resolved_image_name
}
```

Note: AWS uses `ec2-user` for SSH (RHEL AMI default), not `rhel`. The ansible provisioner receives the user from packer's communicator automatically.

### Build

Single build block referencing both sources. Packer runs whichever source is selected via `-only`:

```hcl
build {
    sources = [
        "sources.googlecompute.ansible-dev-tools",
        "sources.amazon-ebs.ansible-dev-tools"
    ]

    provisioner "shell" {
        inline = [
            "sudo dnf install -y openssh-server",
            "sudo systemctl restart sshd"
        ]
    }

    provisioner "ansible" {
        playbook_file   = "${path.root}/ansible/${local.resolved_playbook}"
        user            = var.ssh_username
        extra_arguments = local.extra_args
    }
}
```

### Validation

```hcl
variable "variant" {
    validation {
        condition     = contains(["pip", "pip-pinned", "rpm"], var.variant)
        error_message = "variant must be one of: pip, pip-pinned, rpm"
    }
}
```

### Usage

```bash
# GCP
packer build -only='googlecompute.*' -var="variant=pip" .
packer build -only='googlecompute.*' -var="variant=pip-pinned" .
packer build -only='googlecompute.*' -var="variant=rpm" .

# AWS
packer build -only='amazon-ebs.*' -var="variant=pip" .
packer build -only='amazon-ebs.*' -var="variant=rpm" -var="aws_region=us-east-1" .

# Custom image name
packer build -only='googlecompute.*' -var="variant=pip" -var="image_name=my-custom-name" .
```

---

## Ansible Playbook Design

Three thin playbooks that include shared tasks and add their variant-specific install method.

### Shared Tasks

#### `tasks/base_setup.yml`

Common setup included by all three variants:

1. Install `python3-pip` and `rsync` via `ansible.builtin.dnf`
2. Install `passlib` via `ansible.builtin.pip`
3. Configure `rhel` user (shell, password, wheel group)
4. Create test directory `/home/rhel/test/` with sample inventory and playbook
5. Enable SSHD password authentication and restart SSHD
6. Install and configure code_server role

The `rhel` user password defaults to a variable `code_server_password` (default `ansible123!`). The test inventory credentials match.

#### `tasks/python_setup.yml`

Python environment setup:

1. Install `python3.11-pip` and `python3.12-pip` via `ansible.builtin.dnf`
2. Verify Python version (with `changed_when: false`)

No `alternatives` manipulation — pip variant playbooks use `pip3.11` explicitly; rpm variant gets Python from the AAP repo packages.

#### `tasks/image_cleanup.yml`

End-of-build image hygiene (adapted from upstream `10_image_cleanup.yml`):

1. Remove build-artifact users (keep only `rhel` and configurable list)
2. Disable `dnf-automatic` timer
3. Set `download_updates = no` and `apply_updates = no` in `/etc/dnf/automatic.conf`
4. Apply GCP RHUI repo config from `rh-cloud.repo.j2` template
5. Refresh dnf cache
6. Remove AAP installer repo and directory (if present, guarded by `when`)
7. Clean `/tmp/ansible*` directories
8. Remove bash history
9. Logout of container registries (for `rhel` user and `root`)

### Variant Playbooks

All three follow the same structure. Each defines `ansible_dev_tools_version` with its variant-appropriate default:

```yaml
---
- name: Build ansible-dev-tools image (VARIANT)
  hosts: all
  gather_facts: true
  become: true
  vars:
    code_server_password: 'ansible123!'
    ansible_dev_tools_version: "26.4.1"  # pip variants
    # ansible_dev_tools_version: "26.1.0"  # rpm variant
  tasks:
    - name: Include base setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/base_setup.yml"

    - name: Include Python setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/python_setup.yml"

    # --- variant-specific tasks here ---

    - name: Include image cleanup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/image_cleanup.yml"
```

#### `dev-tools-pip.yml` (pip unpinned)

Variant-specific block:

```yaml
    - name: Install ansible-dev-tools via pip
      ansible.builtin.pip:
        name: ansible-dev-tools
        state: present
        executable: pip3.11
```

#### `dev-tools-pip-pinned.yml` (pip pinned)

Variant-specific block:

```yaml
    - name: Install ansible-dev-tools via pip (pinned)
      ansible.builtin.pip:
        name: "ansible-dev-tools=={{ ansible_dev_tools_version }}"
        state: present
        executable: pip3.11
```

Variable `ansible_dev_tools_version` defaults to `26.4.1` (pip) or `26.1.0` (rpm), overridable via extra vars or the Packer `ansible_vars_file`.

#### `dev-tools-rpm.yml` (rpm)

Variant-specific block:

```yaml
    - name: Copy AAP bundle
      ansible.builtin.copy:
        src: /tmp/aap.tar.gz
        dest: /tmp/aap.tar.gz

    - name: Create AAP install directory
      ansible.builtin.file:
        path: /tmp/aap_install
        state: directory

    - name: Extract AAP bundle
      ansible.builtin.unarchive:
        src: /tmp/aap.tar.gz
        dest: /tmp/aap_install
        remote_src: true
        extra_opts: ['--strip-components=1', '--show-stored-names']

    - name: Create AAP yum repository
      ansible.builtin.yum_repository:
        name: aap_installer
        description: AAP Installer Repository
        baseurl: "file:///tmp/aap_install/bundle/packages/el9/repos"
        gpgcheck: false

    - name: Install ansible-dev-tools via RPM
      ansible.builtin.dnf:
        name:
          - "ansible-dev-tools-{{ ansible_dev_tools_version | default('26.1.0') }}"
          - ansible-core
          - podman
        state: present
```

The RPM variant requires `aap.tar.gz` to be available at `/tmp/aap.tar.gz` on the build host. A preliminary localhost play copies it from the playbook directory. The cleanup tasks will remove the AAP repo and install directory from the final image.

---

## Code Server Role Design

Adapted from `instruqt-leogallego` version. Includes nginx reverse proxy for standalone operation.

### Renamed files

| Old name | New name | Reason |
|----------|----------|--------|
| `codeserver.yml` | `install.yml` | Descriptive of purpose |
| `codeserver_always.yml` | `configure.yml` | Descriptive of purpose |
| `nginx_instruqt.conf` | `code-server-nginx.conf.j2` | Remove instruqt branding, add `.j2` extension |
| `codeserver_username` | `code_server_username` | Snake case consistency with role name |
| `codeserver_password` | `code_server_password` | Snake case consistency |
| `codeserver_url` | `code_server_rpm_url` | Clarify it's the RPM download URL |
| `codeserver_extensions` | `code_server_extensions` | Snake case consistency |
| `codeserver_prebuild` | `code_server_prebuild` | Snake case consistency |
| `codeserver_authentication` | `code_server_authentication` | Snake case consistency |

### `defaults/main.yml`

```yaml
---
code_server_version: "4.115.0"
code_server_rpm_url: >-
  https://github.com/coder/code-server/releases/download/v{{ code_server_version }}/code-server-{{ code_server_version }}-amd64.rpm
code_server_username: "{{ username | default('rhel') }}"
code_server_password: "{{ admin_password | default('ansible123!') }}"
code_server_prebuild: false
code_server_authentication: false

code_server_extensions:
  - name: redhat.ansible
  - name: shd101wyy.markdown-preview-enhanced
```

Notable changes from upstream:
- `code_server_version` variable drives the RPM URL (default `4.115.0`)
- Default user changed from `ec2-user` to `rhel`
- Variable names use `code_server_` prefix consistently
- Removed `s3_state`, `teardown`, `aap_dir`, `codeserver_rescue_url`

### `meta/argument_specs.yml`

Stripped down to relevant entrypoints only (`main` and `install`). Removed all AWS/workshop-specific parameters (`ec2_name_prefix`, `workshop_dns_zone`, `s3_state`, `student_total`). Removed `teardown` entrypoint entirely.

### `tasks/install.yml`

Same as upstream `codeserver.yml` with:
- Updated variable names (`code_server_*`)
- Nginx install + config deployment included (from instruqt-leogallego)
- Template renamed to `code-server-nginx.conf.j2`
- Dropped commented-out blockinfile task

### `tasks/configure.yml`

Same as upstream `codeserver_always.yml` with updated variable names.

### `tasks/main.yml`

Routes to `install.yml` or `configure.yml` based on `code_server_prebuild`.

### Templates

- `code-server.service.j2` — unchanged (updated variable names)
- `code-server-nginx.conf.j2` — same proxy config, renamed, removed instruqt markers, uses `ansible_managed` comment
- `settings.json` — unchanged (ansible-lint enabled, FQCN mode, dark theme, `.yml` mapped to ansible)

### Teardown

Dropped entirely. DNS cleanup is not relevant for image building.

---

## GitHub Actions CI/CD

### `build-gcp.yml` — GCP Image Build

Triggered via `workflow_dispatch`. Matrix strategy over variants.

```yaml
on:
  workflow_dispatch:
    inputs:
      variant:
        description: 'Build variant'
        required: true
        type: choice
        options: ['pip', 'pip-pinned', 'rpm']
        default: 'pip'
```

Steps:
1. Checkout repository
2. Authenticate to GCP (`google-github-actions/auth@v2` with `GCLOUD_SA_KEY` secret)
3. Set up Packer (`hashicorp/setup-packer@main`)
4. `packer init`
5. `packer validate`
6. `packer build -only='googlecompute.gcp' -var="variant=$VARIANT" -force .`

Secrets required: `GCLOUD_SA_KEY`

### `build-aws.yml` — AWS Image Build + qcow2 Export for RHDP

Triggered via `workflow_dispatch`. Builds an AMI, exports it to S3 as raw, converts to qcow2, then cleans up all intermediate AWS resources.

```yaml
on:
  workflow_dispatch:
    inputs:
      variant:
        description: 'Build variant'
        required: true
        type: choice
        options: ['pip', 'pip-pinned', 'rpm']
        default: 'pip'
```

Steps:

1. **Checkout + auth** — authenticate to AWS (`aws-actions/configure-aws-credentials@v4`)
2. **Packer build** — `packer build -only='amazon-ebs.aws' -var="variant=$VARIANT" -force .`
3. **Rename AMI** — copy AMI with a versioned name (`ansible-dev-tools-$VARIANT-YYYYMMDD`), delete the temporary AMI
4. **Export AMI to S3** — `aws ec2 export-image` as raw format to S3 bucket (AWS does not support direct qcow2 export)
5. **Wait for export** — poll `aws ec2 describe-export-image-tasks` until completed (timeout 2h)
6. **Convert raw to qcow2** — spin up a temporary EC2 instance (RHEL 9, t3.medium, 100GB volume):
   - Install `qemu-img` and `awscli`
   - Download raw from S3
   - `qemu-img convert -f raw -O qcow2 -c` (compressed qcow2)
   - Upload qcow2 to S3 (`s3://bucket/ansible-dev-tools/variant/name.qcow2`)
   - Delete raw file from S3
7. **Cleanup** — terminate converter instance, deregister AMI, delete snapshots, remove SSH key and security group
8. **Summary** — output final S3 URL of qcow2

Secrets required: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `S3_BUCKET_NAME`

Final artifact for RHDP: `s3://$S3_BUCKET/ansible-dev-tools/$VARIANT/ansible-dev-tools-$VARIANT-YYYYMMDD.qcow2`

---

## Files to Delete

- `ansible-devtools-packer.hcl` — replaced by `ansible-dev-tools.pkr.hcl`
- `ansible-setup.yml` — replaced by 3 variant playbooks under `ansible/`

---

## Open Considerations

1. **EE pulling**: Not included in the image build. Can be added as a separate playbook later if registry credentials are available.
2. **RHUI template**: `rh-cloud.repo.j2` is GCP-specific (uses `rhui.googlecloud.com`). AWS RHEL AMIs come with their own RHUI config, so the cleanup task should only apply this template on GCP builds. This can be guarded by a variable or by detecting the cloud provider via `ansible_facts`.
3. **`aap.tar.gz` for RPM variant**: The RPM variant requires this file to exist. The playbook expects it at `{{ playbook_dir }}/aap.tar.gz`. This is a prerequisite the user must provide.
4. **AWS SSH user**: AWS RHEL AMIs use `ec2-user`, not `rhel`. The packer `amazon-ebs` source handles this via its own `ssh_username`, but the Ansible playbook needs to account for the different username when configuring the lab user.
