variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Production spoke."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "stack_name" {
  description = "Short stack name."
  type        = string
}

variable "region" {
  description = "AWS region the server lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Instance
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "aheeva-db-slave-v86"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is m5.2xlarge; kept the same."
  type        = string
  default     = "m5.2xlarge"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, registered from the block-level `dd` chain that severed
    the delisted CentOS 7 Marketplace product code `cvugziknvmxgqna9noibqnnsy`.
    Verified `ProductCodes: null`. Carries BOTH block device mappings
    (/dev/sda1 200 GiB, /dev/sdf 16 GiB) and `skip-slave-start` in /etc/my.cnf.
    Full provenance: docs/07-Operations/aheeva-v86-dd-migration-runbook.md
  EOT
  type        = string
  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "vpc_id" {
  description = "shared-prod VPC ID in us-east-2 (AWSAccelerator-us-east-2-shared-prod)."
  type        = string
}

variable "subnet_id" {
  description = "shared-prod app subnet ID (app-a or app-b). Private - this replica has no public exposure."
  type        = string
}

variable "private_ip" {
  description = "Static private IP inside the chosen app subnet. Pin it so MariaDB clients and the replication repoint stay stable across replacements. Empty = AWS picks."
  type        = string
  default     = ""
}

variable "key_name" {
  description = <<-EOT
    EC2 key pair name. Left EMPTY on purpose: the migrated image already carries
    the `Aheeva` public key in authorized_keys and the team holds Aheeva.pem, so
    there is guaranteed SSH access without one.

    WARNING: setting this later FORCES INSTANCE REPLACEMENT. If a
    Production-managed key pair is wanted, create it and set it before this box
    goes into service.
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 200 GiB; match it or the AMI will not fit."
  type        = number
  default     = 200
}

variable "ebs_kms_key_arn" {
  description = <<-EOT
    Optional override for the EBS encryption key ARN. Empty (default)
    auto-resolves the LZA-managed alias/accelerator/ebs/default-encryption/key,
    which is the key the AMI's snapshots are already encrypted with.
  EOT
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Access
# ----------------------------------------------------------------------------

variable "db_port" {
  description = "MariaDB port."
  type        = number
  default     = 3306
}

variable "db_client_cidrs" {
  description = <<-EOT
    CIDRs allowed inbound on db_port. Starts internal-only; widen once
    questionnaire item 3.1 (which systems actually query this replica) is
    answered, and again if the site VPN client CIDRs need direct access.

    APPEND ONLY - never insert. The module's security-group rules are keyed by
    list index, so inserting renumbers every later rule into a destroy+create,
    which the CI destroy guard blocks on merge.

    Note replication itself does NOT need a rule here: the replica connects
    OUTBOUND to the master. These rules are for read clients.
  EOT
  type        = list(string)
  default     = ["10.12.0.0/16"]
}

variable "admin_ssh_cidrs" {
  description = <<-EOT
    Optional CIDRs allowed inbound on 22/tcp for admin SSH. Empty by default.
    Deliberately ordered BEFORE db_client_cidrs in the rule list so that
    appending a DB client does not renumber these.

    There is no SSM agent and no EC2 Instance Connect on CentOS 7, so reaching
    this private box means either the site VPNs or an existing in-VPC jump host.
  EOT
  type        = list(string)
  default     = []
}
