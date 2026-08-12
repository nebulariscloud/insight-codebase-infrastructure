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
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Instance
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "ws-aheeva"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is t3a.medium; kept the same."
  type        = string
  default     = "t3a.medium"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2. Source root volume is 80 GiB, encrypted with the
    aws/ebs AWS-managed key (unshareable) — so the AMI is produced via the
    transfer-CMK re-encrypt dance (create CMK in source, copy-snapshot
    re-encrypted, share, copy cross-region + re-encrypt with LZA key,
    register-image). See README. Placeholder until that's done.
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
  description = "shared-prod app subnet ID (app-a or app-b). Private; the FTPS NLB targets the private IP over TGW."
  type        = string
}

variable "private_ip" {
  description = "Optional static private IP inside the app subnet. Pin it so the NLB target stays stable across replacements."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name for SSH admin access. Empty = SSM-only (but the migrated CentOS-family AMI may lack the SSM agent — provide a key or plan to add the agent)."
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 80 GiB; match it."
  type        = number
  default     = 80
}

variable "ebs_kms_key_arn" {
  description = "Optional override for the EBS encryption key ARN. Empty auto-resolves the LZA EBS key."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Ingress: FTPS (file drop from clients) + Aheeva app/admin ports
# ----------------------------------------------------------------------------

variable "ftps_control_port" {
  description = "FTPS implicit-TLS control port. Source uses 990."
  type        = number
  default     = 990
}

variable "ftps_passive_from" {
  description = "FTPS passive data range start. Source uses 40000."
  type        = number
  default     = 40000
}

variable "ftps_passive_to" {
  description = "FTPS passive data range end. Source uses 40500."
  type        = number
  default     = 40500
}

variable "imdsv2_required" {
  description = <<-EOT
    Require IMDSv2 (sets http_tokens = "required").

    Should be true. It is exposed as a variable only because SSM agent versions
    older than roughly 2.3.68 cannot fetch an IMDSv2 token, so they never read
    instance identity and never register — which presents as an instance that is
    running and perfectly healthy but simply absent from Systems Manager. On a
    lift-and-shift of an old Windows box that is a real possibility, and setting
    this false is the cheapest way to confirm or eliminate it.

    Leaving it false is a genuine security regression: IMDSv1 is reachable without
    a token, which is what makes SSRF-to-credential-theft possible. Mitigated only
    by this box being private with no public IP. Revert to true as soon as the
    in-box agent is confirmed working and upgraded.
  EOT
  type        = bool
  default     = true
}

# NOTE: there is deliberately no `ftps_client_cidrs` variable here.
#
# It used to exist, was never referenced by main.tf, and was actively misleading:
# the README told you to put the FTPS client IPs in it, so someone could set it,
# believe access was restricted, and have changed nothing. Client IPs are enforced
# on the NLB's security group in terraform/live/perimeter/ws-aheeva-ftps-nlb, which
# is the only place they can be enforced — the NLB SNATs, so this instance never
# sees a client address, only NLB private IPs from ingress_vpc_cidr below.

variable "ingress_vpc_cidr" {
  description = "Perimeter ingress VPC CIDR. The FTPS NLB fronts the box; the instance SG allows the FTPS ports from this range (NLB SNATs)."
  type        = string
  default     = "10.0.0.0/20"
}

variable "extra_app_ports" {
  description = <<-EOT
    Additional Aheeva app/admin TCP ports observed on the source SG
    (WebServerAWS): 8025, 8078, 8081, 3389 (RDP), etc. Add only the ones
    confirmed still in use, scoped to admin CIDRs via extra_app_cidrs.
  EOT
  type        = list(number)
  default     = []
}

variable "extra_app_cidrs" {
  description = "CIDRs allowed on extra_app_ports (admin/monitoring sources)."
  type        = list(string)
  default     = []
}

variable "eice_security_group_id" {
  description = "Optional EC2 Instance Connect Endpoint SG ID for admin SSH. Empty to skip."
  type        = string
  default     = ""
}
