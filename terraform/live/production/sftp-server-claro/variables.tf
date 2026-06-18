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
  description = "AWS region the SFTP server lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Inputs the leaf needs
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "sftp-server-claro"
}

variable "instance_type" {
  description = "EC2 instance type. SFTP is rarely CPU-bound; t3.medium covers most loads."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID in us-east-2. Migrated AMI from the source account."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "vpc_id" {
  description = <<-EOT
    Shared-prod VPC ID in us-east-2. Get it from the Production account
    console (VPC -> Your VPCs, look for AWSAccelerator-us-east-2-shared-prod)
    or:

      aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*shared-prod*" \
        --query 'Vpcs[].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
  EOT
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    Shared-prod app subnet ID. Pick AZ a or b - the NLB targets the
    instance's private IP regardless of AZ.

      aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc>" \
        "Name=tag:Name,Values=*shared-prod-app*" \
        --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
        --output table
  EOT
  type        = string
}

variable "private_ip" {
  description = <<-EOT
    Optional static private IP inside the chosen subnet. Pinning it keeps
    the NLB target group stable across instance replacements (no need to
    update the NLB stack's tfvars). Leave empty to let AWS pick.
  EOT
  type        = string
  default     = ""
}

variable "ingress_vpc_cidr" {
  description = <<-EOT
    CIDR of the perimeter ingress VPC. The SFTP server SG only allows
    inbound from this range, since the NLB SNATs and connections arrive
    from NLB private IPs in the perimeter ingress VPC.
  EOT
  type        = string
  default     = "10.0.0.0/20"
}

variable "sftp_port" {
  description = "Port the SFTP daemon listens on inside the instance."
  type        = number
  default     = 22
}

variable "eice_security_group_id" {
  description = <<-EOT
    Optional. Security group ID of the EC2 Instance Connect Endpoint in
    shared-prod (e.g. sg-0a990a87e6abca926). When set, the SFTP server
    SG is opened on TCP/22 from that SG so admins can SSH via EICE for
    troubleshooting. Leave empty to skip.
  EOT
  type        = string
  default     = ""
}

variable "data_volume_snapshot_id" {
  description = <<-EOT
    Snapshot ID for an extra data volume to attach at /dev/sdb. Use this
    when the SFTP user files live on a separate volume that's not part of
    the AMI. Leave empty if the AMI already contains everything (root-only
    snapshot baked into the AMI).
  EOT
  type        = string
  default     = ""
}

variable "data_volume_size_gib" {
  description = "Size of the data volume. Must be >= the snapshot size. Ignored when data_volume_snapshot_id is empty."
  type        = number
  default     = 100
}

variable "data_volume_device_name" {
  description = "Linux device name for the extra data volume."
  type        = string
  default     = "/dev/sdb"
}

variable "root_volume_size_gib" {
  description = "Root volume size. Most migrated AMIs ship the original size; bump only if you've added software."
  type        = number
  default     = 30
}

variable "claro_bucket_name" {
  description = <<-EOT
    Name of the claro-recordings S3 bucket the instance needs access to.
    Defaults to "claro-recordings-prod-<account_id>", matching the default
    in terraform/live/production/claro-recordings/. Override only if the
    bucket leaf was applied with a custom bucket_name.
  EOT
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name. Empty = SSM-only access (recommended for SFTP servers in shared-prod)."
  type        = string
  default     = ""
}
