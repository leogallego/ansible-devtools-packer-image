# ansible-devtools-image

Parameterized Packer + Ansible image builder for ansible-dev-tools lab environments. Produces a RHEL 9 image with [code-server](https://github.com/coder/code-server) (VS Code in browser) and [ansible-dev-tools](https://github.com/ansible/ansible-dev-tools) pre-installed. Targets GCP and AWS, with qcow2 export for RHDP.

## Image variants

| Variant | Description | ansible-dev-tools version |
|---------|-------------|--------------------------|
| `pip` | Installed via pip, unpinned (latest) | latest |
| `pip-pinned` | Installed via pip, pinned version | 26.4.1 |
| `rpm` | Installed via RPM from offline AAP bundle | 26.1.0 |

All variants include:
- RHEL 9 base
- Python 3.11 and 3.12 with pip
- code-server 4.115.0 with nginx reverse proxy (accessible at `/editor/`)
- Ansible and Markdown VS Code extensions
- Lab user (`rhel`) with sudo access and test playbook scaffold

## Prerequisites

- [Packer](https://www.packer.io/downloads) (>= 1.9)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) (on the machine running Packer)
- GCP or AWS credentials (see [CI/CD Setup](#cicd-setup) for GitHub Actions)

For the `rpm` variant, you must place an AAP bundle tarball at `ansible/aap.tar.gz` before building.

## Quick start

### Initialize Packer plugins

```bash
packer init .
```

### Build for GCP

```bash
# pip variant (default)
packer build -only='googlecompute.*' .

# pip-pinned variant
packer build -only='googlecompute.*' -var="variant=pip-pinned" .

# rpm variant (requires ansible/aap.tar.gz)
packer build -only='googlecompute.*' -var="variant=rpm" .
```

### Build for AWS

```bash
packer build -only='amazon-ebs.*' -var="variant=pip" .
```

### Custom image name

```bash
packer build -only='googlecompute.*' -var="image_name=my-custom-name" .
```

### Override variables with a file

```bash
packer build -only='googlecompute.*' -var="ansible_vars_file=my-vars.yml" .
```

## Packer variables

| Variable | Default | Description |
|----------|---------|-------------|
| `variant` | `pip` | Build variant: `pip`, `pip-pinned`, or `rpm` |
| `image_name` | auto-generated | Override the output image name (default: `ansible-dev-tools-{variant}-{YYYYMMDD}`) |
| `ssh_username` | `rhel` | SSH user for Packer to connect as |
| `ansible_vars_file` | none | Path to an Ansible vars file to pass as extra vars |
| `project_id` | `red-hat-mbu` | GCP project ID |
| `zone` | `us-east1-d` | GCP zone |
| `gcp_machine_type` | `n1-standard-2` | GCP machine type for the build instance |
| `aws_region` | `us-east-1` | AWS region |
| `aws_instance_type` | `t3.medium` | AWS instance type for the build instance |

## Repository structure

```
packer-ansible-devtools-image/
  ansible-dev-tools.pkr.hcl              # parameterized Packer file (GCP + AWS)

  ansible/
    dev-tools-pip.yml                     # playbook: pip unpinned variant
    dev-tools-pip-pinned.yml              # playbook: pip pinned variant
    dev-tools-rpm.yml                     # playbook: rpm variant (requires aap.tar.gz)
    tasks/
      base_setup.yml                      # shared: user, sshd, test environment, code-server
      python_setup.yml                    # shared: Python 3.11/3.12 install
      image_cleanup.yml                   # shared: end-of-build image hygiene
    roles/
      code_server/                        # browser-based VS Code (code-server + nginx)
    templates/
      rh-cloud.repo.j2                   # GCP RHUI repo configuration

  .github/
    workflows/
      build-gcp.yml                      # GCP image build (workflow_dispatch)
      build-aws.yml                      # AWS image build + qcow2 export (workflow_dispatch)
```

## CI/CD setup

Both workflows are triggered via `workflow_dispatch` with a variant selector in the GitHub UI.

### GitHub secrets (required)

| Secret | Workflow | Description |
|--------|----------|-------------|
| `GCLOUD_SA_KEY` | GCP | Service account key JSON with `compute.images.create`, `compute.instances.create`, and related Compute Engine permissions |
| `AWS_ACCESS_KEY_ID` | AWS | IAM access key with EC2, S3, and VM Import/Export permissions |
| `AWS_SECRET_ACCESS_KEY` | AWS | Corresponding IAM secret key |

### GitHub variables (optional)

Configure these as repository-level variables (Settings > Secrets and variables > Actions > Variables):

| Variable | Default if unset | Description |
|----------|-----------------|-------------|
| `AWS_REGION` | `us-east-1` | AWS region for builds and image export |
| `S3_BUCKET_NAME` | `ansible-dev-tools-images` | S3 bucket for qcow2 output |
| `CONVERTER_INSTANCE_PROFILE` | `qcow2-converter` | IAM instance profile for the temporary converter EC2 instance |

### AWS prerequisites

The AWS workflow builds an AMI, exports it to S3 as raw, converts it to qcow2 on a temporary EC2 instance, and uploads the qcow2 back to S3. This requires several AWS resources to be set up beforehand:

1. **S3 bucket** — Create a bucket matching `S3_BUCKET_NAME` (default: `ansible-dev-tools-images`) in the target region.

2. **IAM instance profile** — Create an IAM role and instance profile named `qcow2-converter` (or whatever you set in `CONVERTER_INSTANCE_PROFILE`) with a policy granting S3 access to the bucket:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
         "Resource": "arn:aws:s3:::ansible-dev-tools-images/*"
       }
     ]
   }
   ```

3. **VM Import/Export service role** — `aws ec2 export-image` requires a service role named `vmimport` with permissions to write to the S3 bucket. Follow the [AWS VM Import/Export documentation](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html) to create it:

   ```bash
   # Create the trust policy
   cat > trust-policy.json << 'EOF'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": { "Service": "vmie.amazonaws.com" },
         "Action": "sts:AssumeRole"
       }
     ]
   }
   EOF

   # Create the role
   aws iam create-role --role-name vmimport --assume-role-policy-document file://trust-policy.json

   # Attach the S3 policy
   cat > vmimport-policy.json << 'EOF'
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"],
         "Resource": [
           "arn:aws:s3:::ansible-dev-tools-images",
           "arn:aws:s3:::ansible-dev-tools-images/*"
         ]
       },
       {
         "Effect": "Allow",
         "Action": ["ec2:ModifySnapshotAttribute", "ec2:CopySnapshot", "ec2:RegisterImage", "ec2:Describe*"],
         "Resource": "*"
       }
     ]
   }
   EOF

   aws iam put-role-policy --role-name vmimport --policy-name vmimport-policy --policy-document file://vmimport-policy.json
   ```

4. **IAM user permissions** — The IAM user whose credentials are stored in `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` needs permissions for:
   - EC2: create/terminate instances, create/delete security groups and key pairs, describe/deregister/copy images, export images, describe snapshots
   - S3: read/write/delete objects in the target bucket
   - IAM: pass the `qcow2-converter` instance profile role to EC2

### GCP prerequisites

The GCP service account whose key is stored in `GCLOUD_SA_KEY` needs the following roles (or equivalent permissions):

- `roles/compute.instanceAdmin.v1` — create build instances
- `roles/compute.imageUser` — use source images
- `roles/compute.storageAdmin` — create output images
- `roles/iam.serviceAccountUser` — use the service account on instances

## License

GPL-3.0-or-later
