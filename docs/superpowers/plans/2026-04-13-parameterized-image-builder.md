# Parameterized Multi-Cloud Image Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the monolithic single-cloud Packer+Ansible image builder with a parameterized, multi-cloud system producing three image variants (pip, pip-pinned, rpm) from shared infrastructure.

**Architecture:** Single Packer HCL file with `variant` variable selecting playbook and image name via maps. Both GCP (googlecompute) and AWS (amazon-ebs) sources in the same file, selected via `-only`. Three thin Ansible playbooks include shared task files and add variant-specific install steps. A self-contained code_server role provides browser-based VS Code.

**Tech Stack:** Packer HCL, Ansible (YAML playbooks + roles), GitHub Actions, RHEL 9, Jinja2 templates

**Design Spec:** `docs/superpowers/specs/2026-04-13-parameterized-image-builder-design.md`

---

## File Structure

```
packer-ansible-devtools-image/
  ansible-dev-tools.pkr.hcl                    # CREATE - parameterized Packer file (GCP + AWS)

  ansible/
    dev-tools-pip.yml                           # CREATE - pip unpinned variant playbook
    dev-tools-pip-pinned.yml                    # CREATE - pip pinned variant playbook
    dev-tools-rpm.yml                           # CREATE - rpm variant playbook
    tasks/
      base_setup.yml                            # CREATE - shared base setup tasks
      python_setup.yml                          # CREATE - shared Python install tasks
      image_cleanup.yml                         # CREATE - shared end-of-build cleanup
    roles/
      code_server/
        defaults/main.yml                       # CREATE - role defaults
        meta/argument_specs.yml                 # CREATE - input validation
        tasks/
          main.yml                              # CREATE - entrypoint routing
          install.yml                           # CREATE - code-server + nginx install
          configure.yml                         # CREATE - code-server reconfigure
        templates/
          code-server.service.j2                # CREATE - systemd unit
          code-server-nginx.conf.j2             # CREATE - nginx reverse proxy
          settings.json                         # CREATE - VS Code settings
    templates/
      rh-cloud.repo.j2                          # CREATE - GCP RHUI repo config

  .github/
    workflows/
      build-gcp.yml                             # CREATE - GCP build workflow
      build-aws.yml                             # CREATE - AWS build + qcow2 export workflow

  ansible-devtools-packer.hcl                   # DELETE - old Packer file
  ansible-setup.yml                             # DELETE - old monolithic playbook
```

---

## Task 1: Create directory structure

**Files:**
- Create directories: `ansible/tasks/`, `ansible/roles/code_server/defaults/`, `ansible/roles/code_server/meta/`, `ansible/roles/code_server/tasks/`, `ansible/roles/code_server/templates/`, `ansible/templates/`, `.github/workflows/`

- [ ] **Step 1: Create all required directories**

```bash
mkdir -p ansible/tasks \
         ansible/roles/code_server/defaults \
         ansible/roles/code_server/meta \
         ansible/roles/code_server/tasks \
         ansible/roles/code_server/templates \
         ansible/templates \
         .github/workflows
```

- [ ] **Step 2: Verify directory structure**

```bash
find ansible .github -type d | sort
```

Expected output:
```
.github
.github/workflows
ansible
ansible/roles
ansible/roles/code_server
ansible/roles/code_server/defaults
ansible/roles/code_server/meta
ansible/roles/code_server/tasks
ansible/roles/code_server/templates
ansible/tasks
ansible/templates
```

- [ ] **Step 3: Commit**

```bash
git add ansible/.gitkeep .github/.gitkeep 2>/dev/null; true
# Directories without files won't be tracked by git, that's fine.
# They'll be committed with their first file in subsequent tasks.
```

No commit needed here — empty directories aren't tracked by git. They will be committed with their contents.

---

## Task 2: Create code_server role — defaults and argument specs

**Files:**
- Create: `ansible/roles/code_server/defaults/main.yml`
- Create: `ansible/roles/code_server/meta/argument_specs.yml`

Adapted from `tmp/instruqt-leogallego/code_server/`. Changes: rename all `codeserver_*` variables to `code_server_*`, update default version to `4.115.0`, remove workshop-specific variables (`s3_state`, `teardown`, `aap_dir`, `codeserver_rescue_url`), default user to `rhel` instead of `ec2-user`.

- [ ] **Step 1: Create `ansible/roles/code_server/defaults/main.yml`**

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

- [ ] **Step 2: Create `ansible/roles/code_server/meta/argument_specs.yml`**

Stripped down: only `main` and `install` entrypoints. Removed all AWS/workshop parameters (`ec2_name_prefix`, `workshop_dns_zone`, `s3_state`, `student_total`). Removed `teardown` entrypoint.

```yaml
---
argument_specs:
  main:
    short_description: Set up code-server, main entrypoint.
    options:
      code_server_username:
        description: The system user to run code-server as.
        type: str
        required: false
        default: rhel
      code_server_prebuild:
        description: >-
          When true, only reconfigure (configure.yml).
          When false, full install (install.yml).
        type: bool
        required: false
        default: false
  install:
    short_description: Install and configure code-server with nginx.
    options:
      code_server_rpm_url:
        description: URL to the code-server RPM package.
        type: str
        required: false
      code_server_password:
        description: The code-server admin password.
        type: str
        required: false
        default: ansible123!
      code_server_extensions:
        description: List of VS Code extensions to install.
        type: list
        elements: dict
        required: false
      code_server_authentication:
        description: Enable code-server password authentication.
        type: bool
        required: false
        default: false
```

- [ ] **Step 3: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/roles/code_server/defaults/main.yml'))" && echo "defaults OK"
python3 -c "import yaml; yaml.safe_load(open('ansible/roles/code_server/meta/argument_specs.yml'))" && echo "argument_specs OK"
```

Expected: both print OK.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/code_server/defaults/main.yml ansible/roles/code_server/meta/argument_specs.yml
git commit -m "feat: add code_server role defaults and argument specs"
```

---

## Task 3: Create code_server role — templates

**Files:**
- Create: `ansible/roles/code_server/templates/code-server.service.j2`
- Create: `ansible/roles/code_server/templates/code-server-nginx.conf.j2`
- Create: `ansible/roles/code_server/templates/settings.json`

Adapted from `tmp/instruqt-leogallego/code_server/templates/`. Changes: rename variables from `codeserver_*` to `code_server_*`, rename nginx template from `nginx_instruqt.conf`, add `ansible_managed` comment to templates, remove instruqt markers.

- [ ] **Step 1: Create `ansible/roles/code_server/templates/code-server.service.j2`**

```jinja2
{{ ansible_managed | comment }}
[Unit]
Description=Code Server IDE
After=network.target

[Service]
Type=simple
User={{ code_server_username }}
WorkingDirectory=/home/{{ code_server_username }}
Restart=on-failure
RestartSec=10
{% if code_server_authentication | bool %}
Environment="PASSWORD={{ code_server_password }}"

ExecStart=/bin/code-server
{% else %}
ExecStart=/bin/code-server --auth none
{% endif %}

ExecStop=/bin/kill -s QUIT $MAINPID


[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Create `ansible/roles/code_server/templates/code-server-nginx.conf.j2`**

```jinja2
{{ ansible_managed | comment }}
location /editor/ {
    proxy_pass http://127.0.0.1:8080/;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection upgrade;
    proxy_set_header Accept-Encoding gzip;
    proxy_redirect off;
}
```

- [ ] **Step 3: Create `ansible/roles/code_server/templates/settings.json`**

```json
{
    "git.ignoreLegacyWarning": true,
    "terminal.integrated.experimentalRefreshOnResume": true,
    "window.menuBarVisibility": "visible",
    "git.enableSmartCommit": true,
    "workbench.tips.enabled": false,
    "telemetry.enableTelemetry": false,
    "search.smartCase": true,
    "git.confirmSync": false,
    "ansible.ansibleLint.enabled": true,
    "ansible.ansible.useFullyQualifiedCollectionNames": true,
    "redhat.telemetry.enabled": false,
    "security.workspace.trust.banner": "never",
    "security.workspace.trust.enabled": false,
    "git.autofetch": false,
    "editor.renderWhitespace": "all",
    "workbench.colorTheme": "Default Dark+",
    "files.associations": {
        "*.yml": "ansible"
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/code_server/templates/
git commit -m "feat: add code_server role templates"
```

---

## Task 4: Create code_server role — tasks

**Files:**
- Create: `ansible/roles/code_server/tasks/main.yml`
- Create: `ansible/roles/code_server/tasks/install.yml`
- Create: `ansible/roles/code_server/tasks/configure.yml`

Adapted from `tmp/instruqt-leogallego/code_server/tasks/`. Changes: rename variables, rename task file references, use FQCNs consistently, add `changed_when` to command tasks, use `{{ role_path }}` for includes, remove commented-out blockinfile task and teardown routing.

- [ ] **Step 1: Create `ansible/roles/code_server/tasks/main.yml`**

Routes to install or configure based on `code_server_prebuild`. Uses `{{ role_path }}/tasks/` for explicit paths per CLAUDE.md rules.

```yaml
---
- name: Install code-server for image build
  ansible.builtin.include_tasks:
    file: "{{ role_path }}/tasks/install.yml"
  when: not code_server_prebuild | bool

- name: Reconfigure code-server at runtime
  ansible.builtin.include_tasks:
    file: "{{ role_path }}/tasks/configure.yml"
  when: code_server_prebuild | bool
```

- [ ] **Step 2: Create `ansible/roles/code_server/tasks/install.yml`**

Adapted from `codeserver.yml`. Installs code-server RPM, systemd service, VS Code settings, extensions, nginx. Uses `code_server_*` variable names. FQCNs on all modules. Added `changed_when` to command tasks.

```yaml
---
- name: Install code-server
  ansible.builtin.dnf:
    name:
      - "{{ code_server_rpm_url }}"
    state: present
    disable_gpg_check: true
  register: __code_server_dnf_result
  until: __code_server_dnf_result is not failed
  retries: 30
  delay: 1

- name: Install requests Python package
  ansible.builtin.pip:
    name: requests>=2.14.2

- name: Apply code-server systemd service file
  ansible.builtin.template:
    src: code-server.service.j2
    dest: /etc/systemd/system/code-server.service
    owner: "{{ code_server_username }}"
    group: wheel
    mode: "0744"
    backup: true

- name: Ensure code-server User settings directory exists
  ansible.builtin.file:
    path: "/home/{{ code_server_username }}/.local/share/code-server/User/"
    recurse: true
    state: directory
    owner: "{{ code_server_username }}"
    group: "{{ code_server_username }}"
    mode: "0755"

- name: Apply code-server settings
  ansible.builtin.template:
    src: settings.json
    dest: "/home/{{ code_server_username }}/.local/share/code-server/User/settings.json"
    owner: "{{ code_server_username }}"
    group: "{{ code_server_username }}"
    mode: "0644"
    backup: true

- name: Ensure code-server extensions directory exists
  ansible.builtin.file:
    path: "/home/{{ code_server_username }}/.local/share/code-server/extensions/"
    state: directory
    mode: "0755"
    owner: "{{ code_server_username }}"
    group: "{{ code_server_username }}"

- name: Download custom VS Code extension files
  ansible.builtin.get_url:
    url: "{{ item.download_url }}"
    dest: "/home/{{ code_server_username }}/.local/share/code-server/extensions/"
    owner: "{{ code_server_username }}"
    group: "{{ code_server_username }}"
    mode: "0644"
  loop: "{{ code_server_extensions }}"
  when: item.download_url is defined
  register: __code_server_download_extension
  until: __code_server_download_extension is not failed
  retries: 5

- name: Install custom extensions from local file
  become_user: "{{ code_server_username }}"
  ansible.builtin.command: >-
    /bin/code-server --install-extension
    /home/{{ code_server_username }}/.local/share/code-server/extensions/{{ item.filename }}
  loop: "{{ code_server_extensions }}"
  when: item.filename is defined
  register: __code_server_install_local_ext
  until: __code_server_install_local_ext is not failed
  retries: 5
  changed_when: "'was successfully installed' in __code_server_install_local_ext.stdout | default('')"

- name: Install VS Code Marketplace extensions
  become_user: "{{ code_server_username }}"
  ansible.builtin.command: "/bin/code-server --install-extension {{ item.name }}"
  loop: "{{ code_server_extensions }}"
  when: (item.filename is undefined) or (item.download_url is undefined)
  register: __code_server_install_marketplace_ext
  until: __code_server_install_marketplace_ext is not failed
  retries: 5
  changed_when: "'was successfully installed' in __code_server_install_marketplace_ext.stdout | default('')"

- name: Install nginx server
  ansible.builtin.dnf:
    name: nginx
    state: present

- name: Copy nginx configuration for code-server
  ansible.builtin.template:
    src: code-server-nginx.conf.j2
    dest: /etc/nginx/default.d/vscode.conf
    owner: root
    group: root
    mode: "0644"
    backup: true

- name: Enable and start code-server
  ansible.builtin.systemd:
    name: code-server
    enabled: true
    state: started
    daemon_reload: true

- name: Enable and start nginx
  ansible.builtin.systemd:
    name: nginx
    enabled: true
    state: restarted
    daemon_reload: true
```

- [ ] **Step 3: Create `ansible/roles/code_server/tasks/configure.yml`**

Adapted from `codeserver_always.yml`. Used when `code_server_prebuild: true` — reconfigures the service file and restarts.

```yaml
---
- name: Apply code-server systemd service file
  ansible.builtin.template:
    src: code-server.service.j2
    dest: /etc/systemd/system/code-server.service
    owner: "{{ code_server_username }}"
    group: wheel
    mode: "0744"
    backup: true

- name: Restart code-server
  ansible.builtin.systemd:
    name: code-server
    enabled: true
    state: restarted
    daemon_reload: true
```

- [ ] **Step 4: Verify YAML syntax of all task files**

```bash
for f in ansible/roles/code_server/tasks/*.yml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "$f OK"
done
```

Expected: all three print OK.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/code_server/tasks/
git commit -m "feat: add code_server role tasks (install, configure, main)"
```

---

## Task 5: Create shared task — base_setup.yml

**Files:**
- Create: `ansible/tasks/base_setup.yml`

Adapted from the common setup portions of `tmp/instruqt-leogallego/ansible-dev-tools-setup-pip.yml`. All hardcoded `rhel` references replaced with `{{ lab_user }}`. Password uses `code_server_password` variable. FQCNs on all modules.

- [ ] **Step 1: Create `ansible/tasks/base_setup.yml`**

```yaml
---
- name: Install base packages
  ansible.builtin.dnf:
    name:
      - python3-pip
      - rsync
    state: present

- name: Install passlib Python package
  ansible.builtin.pip:
    name: passlib

- name: Configure lab user '{{ lab_user }}'
  ansible.builtin.user:
    name: "{{ lab_user }}"
    shell: /bin/bash
    password: "{{ code_server_password | password_hash('sha512', 'mysecretsalt') }}"
    groups: wheel
    append: true

- name: Create test directory
  ansible.builtin.file:
    path: "/home/{{ lab_user }}/test"
    state: directory
    owner: "{{ lab_user }}"
    group: "{{ lab_user }}"
    mode: "0755"

- name: Create test inventory
  ansible.builtin.copy:
    dest: "/home/{{ lab_user }}/test/hosts"
    content: |
      [rhel]
      node1 ansible_user={{ lab_user }} ansible_password={{ code_server_password }}
    owner: "{{ lab_user }}"
    group: "{{ lab_user }}"
    mode: "0644"

- name: Create test playbook
  ansible.builtin.copy:
    dest: "/home/{{ lab_user }}/test/test.yml"
    content: |
      ---
      - name: Test playbook
        hosts: rhel
    owner: "{{ lab_user }}"
    group: "{{ lab_user }}"
    mode: "0644"

- name: Enable SSHD password authentication
  ansible.builtin.lineinfile:
    dest: /etc/ssh/sshd_config
    state: present
    regexp: '^PasswordAuthentication'
    line: PasswordAuthentication yes

- name: Restart SSHD
  ansible.builtin.systemd:
    name: sshd
    state: restarted

- name: Install and configure code-server
  ansible.builtin.include_role:
    name: code_server
  vars:
    code_server_username: "{{ lab_user }}"
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/tasks/base_setup.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add ansible/tasks/base_setup.yml
git commit -m "feat: add shared base_setup tasks"
```

---

## Task 6: Create shared task — python_setup.yml

**Files:**
- Create: `ansible/tasks/python_setup.yml`

Installs Python 3.11 and 3.12 with pip. No alternatives manipulation per design spec. FQCNs. `changed_when: false` on verification command.

- [ ] **Step 1: Create `ansible/tasks/python_setup.yml`**

```yaml
---
- name: Install Python 3.11 and 3.12 with pip
  ansible.builtin.dnf:
    name:
      - python3.11
      - python3.11-pip
      - python3.12
      - python3.12-pip
    state: present

- name: Verify Python version
  ansible.builtin.command: python3 --version
  changed_when: false
  register: __python_setup_version

- name: Display Python version
  ansible.builtin.debug:
    msg: "Default Python version: {{ __python_setup_version.stdout }}"
    verbosity: 1
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/tasks/python_setup.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add ansible/tasks/python_setup.yml
git commit -m "feat: add shared python_setup tasks"
```

---

## Task 7: Create shared task — image_cleanup.yml and RHUI template

**Files:**
- Create: `ansible/tasks/image_cleanup.yml`
- Create: `ansible/templates/rh-cloud.repo.j2`

Adapted from `tmp/instruqt-leogallego/common/10_image_cleanup.yml`. Changes: replace `student_username` and `ansible_user` with `lab_user`, guard RHUI template with `when: ansible_facts['system_vendor'] == 'Google'`, guard AAP cleanup with `when`, FQCNs on all modules, use `ansible_facts['distribution_major_version']` in template.

- [ ] **Step 1: Create `ansible/templates/rh-cloud.repo.j2`**

Copied from `tmp/instruqt-leogallego/templates/rh-cloud.repo.j2`. Uses `ansible_facts['distribution_major_version']` bracket notation per CLAUDE.md rules.

```jinja2
{{ ansible_managed | comment }}
[rhui-rhel-{{ ansible_facts['distribution_major_version'] }}-for-x86_64-appstream-rhui-rpms]
name=Red Hat Enterprise Linux {{ ansible_facts['distribution_major_version'] }} for x86_64 - AppStream from RHUI (RPMs)
mirrorlist=https://rhui.googlecloud.com/pulp/mirror/content/dist/rhel{{ ansible_facts['distribution_major_version'] }}/rhui/$releasever/x86_64/appstream/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
sslverify=0
sslclientcert=/etc/pki/rhui/product/content.crt
sslclientkey=/etc/pki/rhui/key.pem

[rhui-rhel-{{ ansible_facts['distribution_major_version'] }}-for-x86_64-baseos-rhui-rpms]
name=Red Hat Enterprise Linux {{ ansible_facts['distribution_major_version'] }} for x86_64 - BaseOS from RHUI (RPMs)
mirrorlist=https://rhui.googlecloud.com/pulp/mirror/content/dist/rhel{{ ansible_facts['distribution_major_version'] }}/rhui/$releasever/x86_64/baseos/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
sslverify=0
sslclientcert=/etc/pki/rhui/product/content.crt
sslclientkey=/etc/pki/rhui/key.pem

[rhui-codeready-builder-for-rhel-{{ ansible_facts['distribution_major_version'] }}-$basearch-rhui-rpms]
name=Red Hat CodeReady Linux Builder for RHEL {{ ansible_facts['distribution_major_version'] }} $basearch (RPMs) from RHUI
mirrorlist=https://rhui.googlecloud.com/pulp/mirror/content/dist/rhel9/rhui/$releasever/$basearch/codeready-builder/os
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
sslverify=1
sslclientcert=/etc/pki/rhui/product/content.crt
sslclientkey=/etc/pki/rhui/key.pem
```

- [ ] **Step 2: Create `ansible/tasks/image_cleanup.yml`**

```yaml
---
- name: Gather current standard users
  ansible.builtin.shell: >-
    set -o pipefail &&
    cut -d: -f1,3 /etc/passwd | grep -E ':[0-9]{4}$' | cut -d: -f1
  changed_when: false
  register: __image_cleanup_standard_users

- name: Remove build-artifact users (keep lab_user, awx, pulp)
  ansible.builtin.user:
    name: "{{ item }}"
    state: absent
    remove: true
  loop: "{{ __image_cleanup_standard_users.stdout_lines }}"
  when:
    - item != lab_user
    - item != "awx"
    - item != "pulp"

- name: Disable dnf-automatic timer
  ansible.builtin.service:
    name: dnf-automatic.timer
    state: stopped

- name: Set download_updates = no in automatic.conf
  ansible.builtin.lineinfile:
    path: /etc/dnf/automatic.conf
    regexp: '^download_updates'
    line: download_updates = no

- name: Set apply_updates = no in automatic.conf
  ansible.builtin.lineinfile:
    path: /etc/dnf/automatic.conf
    regexp: '^apply_updates'
    line: apply_updates = no

- name: Apply GCP RHUI repo configuration
  ansible.builtin.template:
    src: "{{ playbook_dir }}/templates/rh-cloud.repo.j2"
    dest: /etc/yum.repos.d/rh-cloud.repo
    owner: root
    group: root
    mode: "0644"
    backup: true
  when: ansible_facts['system_vendor'] == 'Google'

- name: Refresh dnf cache
  ansible.builtin.command: dnf -y makecache
  register: __image_cleanup_makecache
  changed_when: "'Metadata cache created' in __image_cleanup_makecache.stdout"

- name: Remove AAP installer repo
  ansible.builtin.yum_repository:
    name: aap_installer
    state: absent

- name: Remove AAP install directory
  ansible.builtin.file:
    path: /tmp/aap_install
    state: absent

- name: Find Ansible tmp directories
  ansible.builtin.find:
    paths: /tmp/
    file_type: directory
    patterns: 'ansible*'
  register: __image_cleanup_ansible_temp_dirs

- name: Remove Ansible tmp directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ __image_cleanup_ansible_temp_dirs.files }}"
  when: __image_cleanup_ansible_temp_dirs.files is defined

- name: Remove bash history for lab user
  ansible.builtin.file:
    path: "/home/{{ lab_user }}/.bash_history"
    state: absent

- name: Logout of container registries
  become_user: "{{ item }}"
  ansible.builtin.command: podman logout --all
  loop:
    - "{{ lab_user }}"
    - root
  register: __image_cleanup_podman_logout
  changed_when: __image_cleanup_podman_logout.rc == 0
  failed_when: false
  # Guard: only relevant when EE pulling is added (see GitHub issue #2)
```

- [ ] **Step 3: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/tasks/image_cleanup.yml'))" && echo "cleanup OK"
python3 -c "open('ansible/templates/rh-cloud.repo.j2').read()" && echo "template OK"
```

- [ ] **Step 4: Commit**

```bash
git add ansible/tasks/image_cleanup.yml ansible/templates/rh-cloud.repo.j2
git commit -m "feat: add shared image_cleanup tasks and RHUI template"
```

---

## Task 8: Create variant playbook — dev-tools-pip.yml

**Files:**
- Create: `ansible/dev-tools-pip.yml`

Thin playbook: includes shared tasks, installs ansible-dev-tools via pip (unpinned). Uses `{{ playbook_dir }}/tasks/` paths. Defines `lab_user`, `code_server_password`, `ansible_dev_tools_version` as play vars.

- [ ] **Step 1: Create `ansible/dev-tools-pip.yml`**

```yaml
---
- name: Build ansible-dev-tools image (pip)
  hosts: all
  gather_facts: true
  become: true
  vars:
    lab_user: "rhel"
    code_server_password: 'ansible123!'
    ansible_dev_tools_version: "26.4.1"
  tasks:
    - name: Include base setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/base_setup.yml"

    - name: Include Python setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/python_setup.yml"

    - name: Install ansible-dev-tools via pip
      ansible.builtin.pip:
        name: ansible-dev-tools
        state: present
        executable: pip3.11

    - name: Include image cleanup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/image_cleanup.yml"
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/dev-tools-pip.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add ansible/dev-tools-pip.yml
git commit -m "feat: add pip variant playbook"
```

---

## Task 9: Create variant playbook — dev-tools-pip-pinned.yml

**Files:**
- Create: `ansible/dev-tools-pip-pinned.yml`

Same as pip variant but pins the version using `ansible_dev_tools_version`.

- [ ] **Step 1: Create `ansible/dev-tools-pip-pinned.yml`**

```yaml
---
- name: Build ansible-dev-tools image (pip pinned)
  hosts: all
  gather_facts: true
  become: true
  vars:
    lab_user: "rhel"
    code_server_password: 'ansible123!'
    ansible_dev_tools_version: "26.4.1"
  tasks:
    - name: Include base setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/base_setup.yml"

    - name: Include Python setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/python_setup.yml"

    - name: Install ansible-dev-tools via pip (pinned)
      ansible.builtin.pip:
        name: "ansible-dev-tools=={{ ansible_dev_tools_version }}"
        state: present
        executable: pip3.11

    - name: Include image cleanup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/image_cleanup.yml"
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/dev-tools-pip-pinned.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add ansible/dev-tools-pip-pinned.yml
git commit -m "feat: add pip-pinned variant playbook"
```

---

## Task 10: Create variant playbook — dev-tools-rpm.yml

**Files:**
- Create: `ansible/dev-tools-rpm.yml`

RPM variant. Copies `aap.tar.gz` from playbook dir to target, extracts, creates yum repo, installs packages. Uses `{{ playbook_dir }}/aap.tar.gz` as source (user must place this file before building). Cleanup tasks will remove the AAP repo and install directory from the final image.

- [ ] **Step 1: Create `ansible/dev-tools-rpm.yml`**

```yaml
---
- name: Build ansible-dev-tools image (rpm)
  hosts: all
  gather_facts: true
  become: true
  vars:
    lab_user: "rhel"
    code_server_password: 'ansible123!'
    ansible_dev_tools_version: "26.1.0"
  tasks:
    - name: Include base setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/base_setup.yml"

    - name: Include Python setup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/python_setup.yml"

    - name: Copy AAP bundle to target
      ansible.builtin.copy:
        src: "{{ playbook_dir }}/aap.tar.gz"
        dest: /tmp/aap.tar.gz
        mode: "0644"

    - name: Create AAP install directory
      ansible.builtin.file:
        path: /tmp/aap_install
        state: directory
        mode: "0755"

    - name: Extract AAP bundle
      ansible.builtin.unarchive:
        src: /tmp/aap.tar.gz
        dest: /tmp/aap_install
        remote_src: true
        extra_opts:
          - '--strip-components=1'
          - '--show-stored-names'

    - name: Create AAP yum repository
      ansible.builtin.yum_repository:
        name: aap_installer
        description: AAP Installer Repository
        baseurl: "file:///tmp/aap_install/bundle/packages/el9/repos"
        gpgcheck: false

    - name: Install ansible-dev-tools via RPM
      ansible.builtin.dnf:
        name:
          - "ansible-dev-tools-{{ ansible_dev_tools_version }}"
          - ansible-core
          - podman
        state: present

    - name: Include image cleanup
      ansible.builtin.include_tasks:
        file: "{{ playbook_dir }}/tasks/image_cleanup.yml"
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('ansible/dev-tools-rpm.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add ansible/dev-tools-rpm.yml
git commit -m "feat: add rpm variant playbook"
```

---

## Task 11: Create Packer HCL file

**Files:**
- Create: `ansible-dev-tools.pkr.hcl`

Single parameterized Packer file with both GCP and AWS sources. `variant` variable drives image name and playbook selection via maps. Cloud target selected via `-only`. Adapted from design spec with patterns from `tmp/aap-images/aap.pkr.hcl`.

- [ ] **Step 1: Create `ansible-dev-tools.pkr.hcl`**

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

variable "variant" {
  type    = string
  default = "pip"

  validation {
    condition     = contains(["pip", "pip-pinned", "rpm"], var.variant)
    error_message = "variant must be one of: pip, pip-pinned, rpm"
  }
}

variable "image_name" {
  type    = string
  default = null
}

variable "ssh_username" {
  type    = string
  default = "rhel"
}

variable "ansible_vars_file" {
  type    = string
  default = null
}

# --- GCP variables ---

variable "project_id" {
  type    = string
  default = "red-hat-mbu"
}

variable "zone" {
  type    = string
  default = "us-east1-d"
}

variable "gcp_machine_type" {
  type    = string
  default = "n1-standard-2"
}

# --- AWS variables ---

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_instance_type" {
  type    = string
  default = "t3.medium"
}

# --- Locals ---

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
    ["-e", "ansible_python_interpreter=/usr/bin/python3", "--scp-extra-args", "'-O'"],
    var.ansible_vars_file != null ? ["-e", "@${var.ansible_vars_file}"] : []
  )
}

# --- Sources ---

source "googlecompute" "ansible-dev-tools" {
  project_id          = var.project_id
  source_image_family = "rhel-9"
  ssh_username        = var.ssh_username
  zone                = var.zone
  machine_type        = var.gcp_machine_type
  image_name          = local.resolved_image_name
}

source "amazon-ebs" "ansible-dev-tools" {
  region = var.aws_region
  source_ami_filter {
    filters = {
      name                = "RHEL-9*_HVM-*-x86_64-*-GP*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["309956199498"]
  }
  instance_type = var.aws_instance_type
  ssh_username  = "ec2-user"
  ami_name      = local.resolved_image_name
}

# --- Build ---

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
    extra_arguments = local.extra_args
  }
}
```

- [ ] **Step 2: Verify Packer syntax**

```bash
cd /home/lgallego/github/packer-ansible-devtools-image && packer init . && packer validate -var="variant=pip" .
```

Expected: `The configuration is valid.`

If `packer` is not installed locally, validation will occur in CI. Skip this step.

- [ ] **Step 3: Commit**

```bash
git add ansible-dev-tools.pkr.hcl
git commit -m "feat: add parameterized Packer HCL with GCP and AWS sources"
```

---

## Task 12: Create GitHub Actions workflow — build-gcp.yml

**Files:**
- Create: `.github/workflows/build-gcp.yml`

GCP image build workflow. Triggered via `workflow_dispatch` with variant choice. Steps: checkout, GCP auth, setup Packer, init, validate, build. Adapted from `tmp/aap-images/.github/workflows/build-images.yml`.

- [ ] **Step 1: Create `.github/workflows/build-gcp.yml`**

```yaml
---
name: Build Image (GCP)

on:
  workflow_dispatch:
    inputs:
      variant:
        description: 'Build variant'
        required: true
        type: choice
        options:
          - pip
          - pip-pinned
          - rpm
        default: 'pip'

env:
  PACKER_VERSION: "latest"

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          credentials_json: '${{ secrets.GCLOUD_SA_KEY }}'

      - name: Set up Packer
        uses: hashicorp/setup-packer@main
        with:
          version: ${{ env.PACKER_VERSION }}

      - name: Run packer init
        run: packer init .

      - name: Run packer validate
        run: >-
          packer validate
          -var="variant=${{ github.event.inputs.variant }}"
          .

      - name: Build image
        run: >-
          packer build
          -only='googlecompute.*'
          -var="variant=${{ github.event.inputs.variant }}"
          -force
          .

      - name: Generate build summary
        if: success()
        run: |
          echo "## GCP Image Build Complete" >> $GITHUB_STEP_SUMMARY
          echo "**Variant:** ${{ github.event.inputs.variant }}" >> $GITHUB_STEP_SUMMARY
          echo "**Build Date:** $(date)" >> $GITHUB_STEP_SUMMARY
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-gcp.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-gcp.yml
git commit -m "feat: add GCP image build GitHub Actions workflow"
```

---

## Task 13: Create GitHub Actions workflow — build-aws.yml

**Files:**
- Create: `.github/workflows/build-aws.yml`

AWS image build + qcow2 export workflow. Triggered via `workflow_dispatch` with variant choice. Steps: checkout, AWS auth, Packer build, AMI rename, export to S3 as raw, convert raw to qcow2 on temp EC2 instance, cleanup all AWS resources. Adapted from `tmp/aap-images/.github/workflows/build-images-aws.yml` with simplified variable handling (no AAP components — just variant).

- [ ] **Step 1: Create `.github/workflows/build-aws.yml`**

```yaml
---
name: Build Image (AWS + qcow2)

on:
  workflow_dispatch:
    inputs:
      variant:
        description: 'Build variant'
        required: true
        type: choice
        options:
          - pip
          - pip-pinned
          - rpm
        default: 'pip'

env:
  PACKER_VERSION: "latest"

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ vars.AWS_REGION || 'us-east-1' }}

      - name: Set up Packer
        uses: hashicorp/setup-packer@main
        with:
          version: ${{ env.PACKER_VERSION }}

      - name: Run packer init
        run: packer init .

      - name: Run packer validate
        run: >-
          packer validate
          -var="variant=${{ github.event.inputs.variant }}"
          -var="aws_region=${{ vars.AWS_REGION || 'us-east-1' }}"
          .

      - name: Build AMI
        run: >-
          packer build
          -only='amazon-ebs.*'
          -var="variant=${{ github.event.inputs.variant }}"
          -var="aws_region=${{ vars.AWS_REGION || 'us-east-1' }}"
          -force
          .

      - name: Rename AMI with version
        id: get-ami
        run: |
          VARIANT="${{ github.event.inputs.variant }}"
          REGION="${{ vars.AWS_REGION || 'us-east-1' }}"
          FINAL_NAME="ansible-dev-tools-${VARIANT}-$(date +%Y%m%d)"

          # Find the AMI built by Packer (most recent with matching prefix)
          TEMP_AMI_ID=$(aws ec2 describe-images \
            --owners self \
            --filters "Name=name,Values=ansible-dev-tools-${VARIANT}-*" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text \
            --region "$REGION")

          echo "Found AMI: $TEMP_AMI_ID"

          # Copy AMI with versioned name
          NEW_AMI_ID=$(aws ec2 copy-image \
            --source-image-id "$TEMP_AMI_ID" \
            --source-region "$REGION" \
            --name "$FINAL_NAME" \
            --description "ansible-dev-tools ${VARIANT} built on $(date +%Y-%m-%d)" \
            --region "$REGION" \
            --query 'ImageId' \
            --output text)

          echo "New AMI ID: $NEW_AMI_ID"
          aws ec2 wait image-available --image-ids "$NEW_AMI_ID" --region "$REGION"

          # Delete the temporary AMI
          aws ec2 deregister-image --image-id "$TEMP_AMI_ID" --region "$REGION"

          echo "ami_id=$NEW_AMI_ID" >> $GITHUB_OUTPUT
          echo "final_name=$FINAL_NAME" >> $GITHUB_OUTPUT

      - name: Export AMI to S3 as raw
        id: export-ami
        env:
          AWS_DEFAULT_REGION: ${{ vars.AWS_REGION || 'us-east-1' }}
        run: |
          AMI_ID="${{ steps.get-ami.outputs.ami_id }}"
          S3_BUCKET="${{ vars.S3_BUCKET_NAME || 'ansible-dev-tools-images' }}"
          VARIANT="${{ github.event.inputs.variant }}"
          S3_PREFIX="ansible-dev-tools/${VARIANT}"

          EXPORT_TASK_ID=$(aws ec2 export-image \
            --image-id "$AMI_ID" \
            --disk-image-format raw \
            --s3-export-location S3Bucket="$S3_BUCKET",S3Prefix="$S3_PREFIX/" \
            --description "ansible-dev-tools ${VARIANT} raw export from ${AMI_ID}" \
            --query 'ExportImageTaskId' \
            --output text)

          echo "export_task_id=$EXPORT_TASK_ID" >> $GITHUB_OUTPUT
          echo "Started export task: $EXPORT_TASK_ID"

      - name: Wait for export and convert to qcow2
        id: convert-qcow2
        run: |
          EXPORT_TASK_ID="${{ steps.export-ami.outputs.export_task_id }}"
          S3_BUCKET="${{ vars.S3_BUCKET_NAME || 'ansible-dev-tools-images' }}"
          VARIANT="${{ github.event.inputs.variant }}"
          REGION="${{ vars.AWS_REGION || 'us-east-1' }}"
          FINAL_NAME="${{ steps.get-ami.outputs.final_name }}"
          QCOW2_FILE="${FINAL_NAME}.qcow2"
          QCOW2_S3_KEY="ansible-dev-tools/${VARIANT}/${QCOW2_FILE}"

          # Wait for export (timeout 2h)
          TIMEOUT=7200
          ELAPSED=0
          INTERVAL=60

          while [ $ELAPSED -lt $TIMEOUT ]; do
            STATUS=$(aws ec2 describe-export-image-tasks \
              --export-image-task-ids "$EXPORT_TASK_ID" \
              --query 'ExportImageTasks[0].Status' \
              --output text)

            PROGRESS=$(aws ec2 describe-export-image-tasks \
              --export-image-task-ids "$EXPORT_TASK_ID" \
              --query 'ExportImageTasks[0].Progress' \
              --output text)

            echo "Export status: $STATUS, Progress: $PROGRESS%"

            if [ "$STATUS" = "completed" ]; then
              S3_KEY=$(aws ec2 describe-export-image-tasks \
                --export-image-task-ids "$EXPORT_TASK_ID" \
                --query 'ExportImageTasks[0].S3ExportLocation.S3Prefix' \
                --output text)
              S3_KEY="${S3_KEY}${EXPORT_TASK_ID}.raw"

              echo "Raw export completed: s3://$S3_BUCKET/$S3_KEY"

              RAW_FILE=$(basename "$S3_KEY")

              # Create temporary SSH key for converter instance
              ssh-keygen -t rsa -b 2048 -f /tmp/converter-key -N ""
              chmod 600 /tmp/converter-key

              # Create temporary security group
              TEMP_SG_ID=$(aws ec2 create-security-group \
                --group-name "qcow2-converter-$(date +%s)" \
                --description "Temporary SG for qcow2 conversion" \
                --query 'GroupId' \
                --output text)

              aws ec2 authorize-security-group-ingress \
                --group-id "$TEMP_SG_ID" \
                --protocol tcp \
                --port 22 \
                --cidr 0.0.0.0/0

              KEY_NAME="converter-$(date +%s)"
              aws ec2 import-key-pair \
                --key-name "$KEY_NAME" \
                --public-key-material fileb:///tmp/converter-key.pub

              # Get latest RHEL 9 AMI for converter
              CONVERTER_AMI=$(aws ec2 describe-images \
                --owners 309956199498 \
                --filters "Name=name,Values=RHEL-9*_HVM-*-x86_64-*-GP*" \
                          "Name=state,Values=available" \
                --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
                --output text)

              # User-data to install tools
              printf '%s\n' '#!/bin/bash' 'set -x' 'exec > /var/log/user-data.log 2>&1' 'yum install -y qemu-img awscli' > /tmp/user-data.sh

              # Launch converter instance
              CONVERTER_INSTANCE=$(aws ec2 run-instances \
                --image-id "$CONVERTER_AMI" \
                --instance-type t3.medium \
                --key-name "$KEY_NAME" \
                --security-group-ids "$TEMP_SG_ID" \
                --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
                --user-data file:///tmp/user-data.sh \
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=qcow2-converter},{Key=Purpose,Value=temporary}]" \
                --query 'Instances[0].InstanceId' \
                --output text)

              echo "Launched converter: $CONVERTER_INSTANCE"
              aws ec2 wait instance-running --instance-ids "$CONVERTER_INSTANCE"

              PUBLIC_IP=$(aws ec2 describe-instances \
                --instance-ids "$CONVERTER_INSTANCE" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text)

              # Wait for SSH
              for i in $(seq 1 30); do
                if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i /tmp/converter-key ec2-user@"$PUBLIC_IP" "echo SSH ready" 2>/dev/null; then
                  break
                fi
                if [ "$i" -eq 30 ]; then
                  echo "ERROR: SSH did not become ready"
                  aws ec2 terminate-instances --instance-ids "$CONVERTER_INSTANCE"
                  aws ec2 delete-key-pair --key-name "$KEY_NAME"
                  sleep 30
                  aws ec2 delete-security-group --group-id "$TEMP_SG_ID" || true
                  exit 1
                fi
                sleep 10
              done

              # Wait for tools installation
              for i in $(seq 1 30); do
                if ssh -o StrictHostKeyChecking=no -i /tmp/converter-key ec2-user@"$PUBLIC_IP" "command -v qemu-img && command -v aws" 2>/dev/null; then
                  break
                fi
                if [ "$i" -eq 30 ]; then
                  echo "ERROR: Tools did not install in time"
                  aws ec2 terminate-instances --instance-ids "$CONVERTER_INSTANCE"
                  aws ec2 delete-key-pair --key-name "$KEY_NAME"
                  sleep 30
                  aws ec2 delete-security-group --group-id "$TEMP_SG_ID" || true
                  exit 1
                fi
                sleep 10
              done

              # Run conversion
              echo "Running qcow2 conversion..."
              ssh -o StrictHostKeyChecking=no \
                  -o ServerAliveInterval=30 \
                  -o ServerAliveCountMax=240 \
                  -o TCPKeepAlive=yes \
                  -i /tmp/converter-key ec2-user@"$PUBLIC_IP" \
                  "export AWS_ACCESS_KEY_ID='$AWS_ACCESS_KEY_ID' && \
                   export AWS_SECRET_ACCESS_KEY='$AWS_SECRET_ACCESS_KEY' && \
                   export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION' && \
                   echo 'Downloading raw image...' && \
                   aws s3 cp s3://$S3_BUCKET/$S3_KEY /tmp/$RAW_FILE --no-progress && \
                   echo 'Converting to qcow2...' && \
                   qemu-img convert -f raw -O qcow2 -c /tmp/$RAW_FILE /tmp/$QCOW2_FILE && \
                   rm -f /tmp/$RAW_FILE && \
                   echo 'Uploading qcow2...' && \
                   aws s3 cp /tmp/$QCOW2_FILE s3://$S3_BUCKET/$QCOW2_S3_KEY --no-progress && \
                   rm -f /tmp/$QCOW2_FILE"

              # Cleanup converter
              aws ec2 terminate-instances --instance-ids "$CONVERTER_INSTANCE"
              aws ec2 wait instance-terminated --instance-ids "$CONVERTER_INSTANCE"
              aws ec2 delete-key-pair --key-name "$KEY_NAME"
              rm -f /tmp/converter-key /tmp/converter-key.pub /tmp/user-data.sh
              sleep 30
              aws ec2 delete-security-group --group-id "$TEMP_SG_ID" || true

              # Delete raw file
              aws s3 rm "s3://$S3_BUCKET/$S3_KEY"

              echo "qcow2 available at: s3://$S3_BUCKET/$QCOW2_S3_KEY"
              echo "s3_url=s3://$S3_BUCKET/$QCOW2_S3_KEY" >> $GITHUB_OUTPUT
              break

            elif [ "$STATUS" = "cancelled" ] || [ "$STATUS" = "cancelling" ]; then
              echo "ERROR: Export was cancelled"
              exit 1
            elif [ "$STATUS" = "failed" ]; then
              echo "ERROR: Export failed"
              aws ec2 describe-export-image-tasks --export-image-task-ids "$EXPORT_TASK_ID"
              exit 1
            fi

            sleep $INTERVAL
            ELAPSED=$((ELAPSED + INTERVAL))
          done

          if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "ERROR: Export timed out after 2 hours"
            exit 1
          fi

      - name: Cleanup AWS resources
        if: always()
        run: |
          AMI_ID="${{ steps.get-ami.outputs.ami_id }}"
          REGION="${{ vars.AWS_REGION || 'us-east-1' }}"

          if [ -n "$AMI_ID" ] && [ "$AMI_ID" != "null" ]; then
            SNAPSHOT_IDS=$(aws ec2 describe-images \
              --image-ids "$AMI_ID" \
              --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
              --output text \
              --region "$REGION" || echo "")

            echo "Deregistering AMI: $AMI_ID"
            aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION" || true

            if [ -n "$SNAPSHOT_IDS" ] && [ "$SNAPSHOT_IDS" != "None" ]; then
              for SNAPSHOT_ID in $SNAPSHOT_IDS; do
                if [ "$SNAPSHOT_ID" != "None" ]; then
                  echo "Deleting snapshot: $SNAPSHOT_ID"
                  aws ec2 delete-snapshot --snapshot-id "$SNAPSHOT_ID" --region "$REGION" || true
                fi
              done
            fi
          fi

      - name: Generate build summary
        if: success()
        run: |
          echo "## AWS Image Build Complete" >> $GITHUB_STEP_SUMMARY
          echo "**Variant:** ${{ github.event.inputs.variant }}" >> $GITHUB_STEP_SUMMARY
          echo "**AMI Name:** ${{ steps.get-ami.outputs.final_name }}" >> $GITHUB_STEP_SUMMARY
          echo "**qcow2 Location:** ${{ steps.convert-qcow2.outputs.s3_url }}" >> $GITHUB_STEP_SUMMARY
          echo "**Build Date:** $(date)" >> $GITHUB_STEP_SUMMARY
          echo "" >> $GITHUB_STEP_SUMMARY
          echo "AMI and snapshots have been automatically cleaned up." >> $GITHUB_STEP_SUMMARY
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-aws.yml'))" && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-aws.yml
git commit -m "feat: add AWS image build + qcow2 export GitHub Actions workflow"
```

---

## Task 14: Delete old files and final validation

**Files:**
- Delete: `ansible-devtools-packer.hcl`
- Delete: `ansible-setup.yml`

- [ ] **Step 1: Delete old Packer file**

```bash
git rm ansible-devtools-packer.hcl
```

- [ ] **Step 2: Delete old monolithic playbook**

```bash
git rm ansible-setup.yml
```

- [ ] **Step 3: Validate all playbook YAML syntax**

```bash
for f in ansible/dev-tools-pip.yml ansible/dev-tools-pip-pinned.yml ansible/dev-tools-rpm.yml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "$f OK"
done
```

Expected: all three print OK.

- [ ] **Step 4: Validate Packer HCL (if packer is installed)**

```bash
packer validate -var="variant=pip" . 2>/dev/null && echo "packer OK" || echo "packer not installed locally, validate in CI"
```

- [ ] **Step 5: Verify complete file structure**

```bash
find ansible .github ansible-dev-tools.pkr.hcl -type f | sort
```

Expected output:
```
.github/workflows/build-aws.yml
.github/workflows/build-gcp.yml
ansible-dev-tools.pkr.hcl
ansible/dev-tools-pip-pinned.yml
ansible/dev-tools-pip.yml
ansible/dev-tools-rpm.yml
ansible/roles/code_server/defaults/main.yml
ansible/roles/code_server/meta/argument_specs.yml
ansible/roles/code_server/tasks/configure.yml
ansible/roles/code_server/tasks/install.yml
ansible/roles/code_server/tasks/main.yml
ansible/roles/code_server/templates/code-server-nginx.conf.j2
ansible/roles/code_server/templates/code-server.service.j2
ansible/roles/code_server/templates/settings.json
ansible/tasks/base_setup.yml
ansible/tasks/image_cleanup.yml
ansible/tasks/python_setup.yml
ansible/templates/rh-cloud.repo.j2
```

- [ ] **Step 6: Verify old files are gone**

```bash
test ! -f ansible-devtools-packer.hcl && echo "old HCL deleted" || echo "STILL EXISTS"
test ! -f ansible-setup.yml && echo "old playbook deleted" || echo "STILL EXISTS"
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: remove old monolithic packer and playbook files"
```
