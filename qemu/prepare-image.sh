#!/bin/bash
set -euo pipefail

SOURCE="${1:?Usage: $0 <source-qcow2> [output-dir]}"
OUTPUT_DIR="${2:-tmp/prepared}"

IMAGE_NAME=$(basename "$SOURCE")
PREPARED="${OUTPUT_DIR}/${IMAGE_NAME}"

mkdir -p "$OUTPUT_DIR"
echo "Copying ${SOURCE} to ${PREPARED}..."
cp "$SOURCE" "$PREPARED"

echo "Customizing image with virt-customize..."
virt-customize -a "$PREPARED" \
  --run-command 'useradd -m -s /bin/bash -G wheel rhel || true' \
  --password rhel:password:ansible123! \
  --run-command 'echo "rhel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel' \
  --run-command 'chmod 440 /etc/sudoers.d/rhel' \
  --run-command 'sed -i "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
  --run-command 'sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
  --run-command 'systemctl enable sshd' \
  --uninstall cloud-init

echo "Prepared image: ${PREPARED}"
