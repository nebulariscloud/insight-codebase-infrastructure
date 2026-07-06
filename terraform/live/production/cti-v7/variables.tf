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
  description = "AWS region CTI v7 lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Instance
# ----------------------------------------------------------------------------

variable "name" {
  description = "Server name. Used for the Name tag and resource names."
  type        = string
  default     = "cti-v7"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type. Source box is m5.2xlarge (8 vCPU / 32 GiB). Kept the
    same to avoid changing Aheeva's licensed capacity or SIP/RTP performance
    characteristics at cutover. Right-size later once stable.
  EOT
  type        = string
  default     = "m5.2xlarge"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, copied+re-encrypted from the source-tenant CTI v7
    AMI. The source root volume is UNENCRYPTED gp2; the copy step re-encrypts
    with the LZA EBS key (see README, step "copy the AMI"). Placeholder until
    that copy is done.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxx."
  }
}

variable "vpc_id" {
  description = <<-EOT
    Shared-prod VPC ID in us-east-2 (AWSAccelerator-us-east-2-shared-prod).
  EOT
  type        = string
}

variable "public_subnet_id" {
  description = <<-EOT
    PUBLIC subnet ID in shared-prod for the direct-EIP CTI v7 instance. This is
    the AWSAccelerator-us-east-2-shared-prod-public-a subnet added as part of
    the Option B guardrail exception (see docs/07-Operations/cti-v7-lza-
    exception.md). It does NOT exist in the default LZA layout. Do not apply
    this leaf until the exception (IGW + public subnet + BPA exclusion + SCP
    carve-out) is live. Resolve with:

      aws ec2 describe-subnets --region us-east-2 \
        --filters "Name=tag:Name,Values=*shared-prod-public-a" \
        --query 'Subnets[0].SubnetId' --output text
  EOT
  type        = string
}

variable "private_ip" {
  description = <<-EOT
    Optional static private IP inside the public subnet. Pin it so the
    Aheeva SIP config (externip is the EIP, but the private IP is referenced
    by localnet) and any downstream references stay stable across instance
    replacements. Leave empty to let AWS pick.
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 200 GiB; match it."
  type        = number
  default     = 200
}

variable "ebs_kms_key_arn" {
  description = <<-EOT
    Optional override for the EBS encryption key ARN. Leave empty (default) to
    auto-resolve the LZA-managed key alias/accelerator/ebs/default-encryption/key
    via a data source. Only set this if you need a different key.
  EOT
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# SIP / RTP peers
# ----------------------------------------------------------------------------

variable "sip_peer_cidrs" {
  description = <<-EOT
    CIDRs of the SIP/RTP peers (the VoIP gateway path). Confirmed as the
    Liberty data-center IPs. SIP 5060 (UDP) and RTP 10000-11000 (UDP) are
    opened from these sources only.
  EOT
  type        = list(string)
  default = [
    "199.116.62.102/32",
    "23.249.138.106/32",
  ]
}

variable "rtp_extra_cidrs" {
  description = <<-EOT
    Additional CIDRs allowed on the RTP range beyond the SIP peers. Includes
    the entries confirmed still-needed from the source SG. NOTE: 1.1.1.1/32 is
    an INTENTIONAL Aheeva special config (confirmed by the vendor) — it is not
    a mistake, keep it. 196.12.161.225 was dropped (no longer needed for v7).
  EOT
  type        = list(string)
  default = [
    "64.89.2.105/32",
    "66.231.161.164/32",
    "1.1.1.1/32",
  ]
}

variable "rtp_from_port" {
  description = "RTP range start. Matches Asterisk rtpstart on the source."
  type        = number
  default     = 10000
}

variable "rtp_to_port" {
  description = <<-EOT
    RTP range end. Source Asterisk uses rtpend=11000 (NOT the 20000 the old
    SG allowed). Scoped tight to match reality; widen only if Aheeva's
    rtp.conf changes.
  EOT
  type        = number
  default     = 11000
}

# ----------------------------------------------------------------------------
# Admin access (8443 web GUI)
# ----------------------------------------------------------------------------

variable "admin_ingress_cidr" {
  description = <<-EOT
    CIDR the admin 8443 web GUI is reachable from. In the chosen design the
    8443 UI sits behind the perimeter ingress ALB (TLS-terminating, IP
    allowlist at the ALB), so this is the perimeter ingress VPC CIDR — the
    instance only accepts 8443 from the ALB, not from the public internet.
    The public admin allowlist lives on the ALB listener rule, not here.
  EOT
  type        = string
  default     = "10.0.0.0/20"
}

# ----------------------------------------------------------------------------
# License server egress note
# ----------------------------------------------------------------------------
# CTI v7 phones home to the Aheeva License Server on TCP 5053 + 50555. Egress
# is all-allow by default (matches the source SG), so no explicit egress rule
# is needed. The Aheeva-side allowlist is keyed to CTI v7's EIP — coordinate
# the new EIP with the vendor before cutover.
