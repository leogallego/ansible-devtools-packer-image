# CLAUDE.md

## Project Overview

Parameterized Packer + Ansible image builder for ansible-dev-tools lab environments. Produces a RHEL 9 image with code-server (VS Code in browser) and ansible-dev-tools pre-installed. Targets GCP and AWS, with qcow2 export for RHDP.

## Design Spec

Full design at `docs/superpowers/specs/2026-04-13-parameterized-image-builder-design.md`. Read this before making changes.

## Reference Files

All upstream reference files are in `tmp/` (gitignored). These are the source templates to adapt — do NOT read from external repos.

- `tmp/instruqt-leogallego/` — code_server role (with nginx), pip/rpm playbooks, cleanup tasks, RHUI template
- `tmp/instruqt-ansible/` — RPM playbook variant, EE pull playbook
- `tmp/aap-images/` — Packer HCL patterns, GitHub Actions workflows (GCP + AWS with qcow2 conversion)

See memory file `reference_source_repos.md` for detailed adaptation notes per file.

## Environment Rules

- **Sandboxed environment**: Do NOT read, write, or reference files outside of this project directory. If access to an external path is truly needed, ask the user first and explain why.
- **Temporary files**: Always use the local `tmp/` directory for any temporary files or directories. Never use `/tmp/` or any other system path.
- **Reference files**: All upstream source templates are already in `tmp/`. No need to clone or access external repos. If access to an external path or repo is truly needed, ask the user first and explain why.

## Key Decisions

- **Single parameterized Packer HCL** with `variant` variable (`pip`, `pip-pinned`, `rpm`) and both `googlecompute` + `amazon-ebs` sources
- **Shared Ansible tasks** in `ansible/tasks/` included by thin variant playbooks
- **code_server role** adapted from instruqt-leogallego (with nginx for standalone operation)
- **GitHub Actions** for GCP builds and AWS builds with qcow2 export for RHDP

## Version Defaults

- `ansible-dev-tools` pip: `26.4.1`
- `ansible-dev-tools` rpm: `26.1.0`
- `code-server`: `4.115.0`
