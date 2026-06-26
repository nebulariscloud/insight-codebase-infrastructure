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
  description = "AWS region the Moodle server lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Inputs the leaf needs
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "moodle"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type. The source Lightsail was 2 GB / 2 vCPU; t3a.small is
    the equivalent. Bump to t3a.medium if Moodle's PHP-FPM workers start
    queueing under real user load.
  EOT
  type        = string
  default     = "t3a.small"
}

variable "ami_id" {
  description = "AMI ID in us-east-2. Built locally via register-image from the cross-account-copied Lightsail snapshot."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "vpc_id" {
  description = <<-EOT
    Shared-prod VPC ID in us-east-2. Same VPC used by scriptcase, wazuh, and
    sftp-server: vpc-04a8720d0ddb40713 (AWSAccelerator-us-east-2-shared-prod).
  EOT
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    Shared-prod app subnet ID. Use app-a (us-east-2a, 10.12.1.0/24) so this
    server sits alongside the other migrated workloads. The perimeter ALB
    targets the private IP cross-VPC over TGW regardless of AZ.
  EOT
  type        = string
}

variable "private_ip" {
  description = <<-EOT
    Optional static private IP inside the chosen subnet. Pinning keeps the
    ALB target group stable across instance replacements (no need to update
    the ALB stack). Existing tenants in 10.12.1.0/24:
      10.12.1.50  - sftp-server
      10.12.1.121 - wazuh
      10.12.1.174 - scriptcase-php-73
    .60 is suggested below as the default for Moodle.
  EOT
  type        = string
  default     = ""
}

variable "ingress_vpc_cidr" {
  description = <<-EOT
    CIDR of the perimeter ingress VPC. The Moodle server SG only allows
    inbound HTTP from this range, since the ingress ALB lives in the
    perimeter ingress VPC and connections arrive from its private IPs.
  EOT
  type        = string
  default     = "10.0.0.0/20"
}

variable "moodle_http_port" {
  description = "Port Apache listens on inside the Bitnami Moodle stack."
  type        = number
  default     = 80
}

variable "eice_security_group_id" {
  description = <<-EOT
    Optional. Security group ID of the EC2 Instance Connect Endpoint in
    shared-prod. When set, the Moodle server SG is opened on TCP/22 from
    that SG so admins can SSH via EICE for troubleshooting if SSM Session
    Manager is ever unavailable.

    Get this with:
      aws ec2 describe-instance-connect-endpoints --region us-east-2 \
        --filters Name=vpc-id,Values=vpc-04a8720d0ddb40713 \
        --query 'InstanceConnectEndpoints[].SecurityGroupIds'

    Leave empty to skip (SSM Session Manager is the primary access path).
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = <<-EOT
    Root volume size. The source Lightsail bundle was 60 GiB; the migrated
    AMI's backing snapshot is 60 GiB. Bump higher only if Moodle's
    /var/moodledata starts approaching the disk's capacity.
  EOT
  type        = number
  default     = 60
}

variable "key_name" {
  description = "EC2 key pair name. Empty = SSM-only access (recommended)."
  type        = string
  default     = ""
}

variable "extra_ingress_rules" {
  description = <<-EOT
    Extra security group ingress rules beyond the defaults (HTTP from
    ingress VPC, optional SSH from EICE). Use this only if Moodle needs an
    additional listener (e.g., a Moodle plugin that exposes a webhook on a
    non-standard port). Each rule sources from exactly one CIDR; the
    underlying module flattens lists of CIDRs internally.
  EOT
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default = []
}
