packer {
  required_plugins {
    ansible = {
      version = ">= v1.1.4"
      source  = "github.com/hashicorp/ansible"
    }
    googlecompute = {
      version = ">= v1.2.5"
      source  = "github.com/hashicorp/googlecompute"
    }
    amazon = {
      version = ">= v1.8.0"
      source  = "github.com/hashicorp/amazon"
    }
    qemu = {
      version = ">= v1.1.1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "variant" {
  type    = string
  default = "pip"

  validation {
    condition     = contains(["pip", "pip-pinned", "rpm"], var.variant)
    error_message = "Variant must be one of: pip, pip-pinned, rpm."
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

# --- QEMU variables ---

variable "qemu_iso_url" {
  type        = string
  default     = "rhel-9-x86_64-kvm.qcow2"
  description = "Path to RHEL 9 KVM guest image (qcow2)."
}

variable "qemu_iso_checksum" {
  type    = string
  default = "none"
}

variable "qemu_output_directory" {
  type    = string
  default = "output"
}

# --- Locals ---

locals {
  playbooks = {
    pip        = "dev-tools-pip.yml"
    pip-pinned = "dev-tools-pip-pinned.yml"
    rpm        = "dev-tools-rpm.yml"
  }
  timestamp           = formatdate("YYYYMMDD-hhmm", timestamp())
  resolved_image_name = coalesce(var.image_name, "ansible-devtools-image-${var.variant}-${local.timestamp}")
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

source "qemu" "ansible-dev-tools" {
  iso_url                = var.qemu_iso_url
  iso_checksum           = var.qemu_iso_checksum
  disk_image             = true
  output_directory       = var.qemu_output_directory
  vm_name                = "${local.resolved_image_name}.qcow2"
  format                 = "qcow2"
  accelerator            = "kvm"
  cpus                   = 2
  memory                 = 4096
  skip_resize_disk       = true
  ssh_username           = var.ssh_username
  ssh_password           = "ansible123!"
  ssh_timeout            = "5m"
  ssh_handshake_attempts = 50
  boot_wait              = "15s"
  shutdown_command       = "sudo shutdown -P now"
  headless               = true
  qemuargs = [
    ["-cpu", "host"]
  ]
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
    "sources.amazon-ebs.ansible-dev-tools",
    "sources.qemu.ansible-dev-tools"
  ]

  provisioner "shell" {
    inline = [
      "sudo dnf install -y openssh-server",
      "sudo systemctl restart sshd"
    ]
    only = ["googlecompute.ansible-dev-tools", "amazon-ebs.ansible-dev-tools"]
  }

  provisioner "ansible" {
    playbook_file   = "${path.root}/ansible/qemu-prepare.yml"
    extra_arguments = local.extra_args
    only            = ["qemu.ansible-dev-tools"]
  }

  provisioner "ansible" {
    playbook_file   = "${path.root}/ansible/${local.resolved_playbook}"
    extra_arguments = local.extra_args
  }
}
