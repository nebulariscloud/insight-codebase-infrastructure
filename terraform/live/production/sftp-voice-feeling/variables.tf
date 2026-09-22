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
# Instance
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "sftp-voice-feeling"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is t3.micro; kept the same."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, copied + re-encrypted from the source-tenant
    "SFTP VOFeeling" AMI. Source root volume is UNENCRYPTED, so the copy just
    re-encrypts with the LZA EBS key (no CMK share needed). See README.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "vpc_id" {
  description = "shared-prod VPC ID in us-east-2."
  type        = string
}

variable "subnet_id" {
  description = "shared-prod app subnet ID (app-a or app-b). Private; the NLB targets the private IP over TGW."
  type        = string
}

variable "private_ip" {
  description = "Optional static private IP inside the chosen app subnet. Pinning keeps the NLB target stable across replacements. Empty = AWS picks."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name. Empty = SSM-only access (recommended for SFTP servers in shared-prod)."
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 80 GiB gp3; match it."
  type        = number
  default     = 80
}

variable "ebs_kms_key_arn" {
  description = "Optional override for the EBS encryption key ARN. Empty auto-resolves the LZA EBS key."
  type        = string
  default     = ""
}

variable "sftp_port" {
  description = "Port the SFTP daemon listens on inside the instance."
  type        = number
  default     = 22
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

variable "eice_security_group_id" {
  description = <<-EOT
    Optional. Security group ID of the EC2 Instance Connect Endpoint in
    shared-prod. When set, the SFTP server SG is opened on the SFTP port
    from that SG so admins can SSH via EICE for troubleshooting. Leave
    empty to skip.
  EOT
  type        = string
  default     = ""
}
