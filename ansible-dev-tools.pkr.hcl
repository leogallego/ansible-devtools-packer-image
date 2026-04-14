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
