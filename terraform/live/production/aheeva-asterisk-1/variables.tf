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
  default     = "aheeva-asterisk-1"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is m5.2xlarge; kept the same."
  type        = string
  default     = "m5.2xlarge"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, copied + re-encrypted from the source-tenant
    "Aheeva Asterisk 1" AMI. Source root volume is UNENCRYPTED, so the copy
    just re-encrypts with the LZA EBS key (no CMK share needed). See README.
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
  description = "shared-prod app subnet ID (private). The box is reached over the Site-to-Site VPNs via TGW; no public IP."
  type        = string
}

variable "private_ip" {
  description = "Static private IP inside the chosen app subnet. Pinned so cluster peers and VPN routing stay stable."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name for SSH admin access. Empty = SSM-only."
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 100 GiB; match it."
  type        = number
  default     = 100
}

variable "ebs_kms_key_arn" {
  description = "Optional override for the EBS encryption key ARN. Empty auto-resolves the LZA EBS key."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Security-group source scopes
#
# The source box was public and its SG referenced the carriers' PUBLIC IPs.
# In the destination every source arrives PRIVATELY:
#   - cluster peers (the other Aheeva boxes + CTI v7) over shared-prod / TGW
#   - the voice carriers over the Site-to-Site VPNs, sourced from the on-prem
#     ranges routed in network-config.yaml (tgw-rt-spoke), NOT their public IPs
#   - admins via the shared-prod bastion / EICE
#
# Each scope is a tunable list so the exact ranges can be pruned at the voice
# cutover without a code change. Nothing is open to the internet.
# ----------------------------------------------------------------------------

variable "intra_cluster_cidrs" {
  description = <<-EOT
    CIDRs of the Aheeva cluster peers + CTI v7 inside shared-prod. Covers the
    box-to-box traffic that was self-SG-referenced in the source (SIP 5080 and
    the all-traffic intra-cluster rule). Default = the shared-prod app subnet
    CIDR, which holds all these boxes.
  EOT
  type        = list(string)
  default     = ["10.12.1.0/24"]
}

variable "voice_source_cidrs" {
  description = <<-EOT
    On-prem VPN source ranges the voice carriers reach this box from over the
    Site-to-Site VPNs (SIP + RTP). Defaulted to the ranges routed in
    network-config.yaml's tgw-rt-spoke (Liberty / Kennedy / RD / Zima),
    including the CGNAT (100.64.x) source-NAT ranges. Prune to the carriers
    actually in use at the voice cutover.
  EOT
  type        = list(string)
  # SUMMARIZED to supernets, not the 19 individual VPN routes. The voice ports
  # multiply CIDRs x ports, and 19 CIDRs blew past the 60-rules-per-SG limit
  # (RulesPerSecurityGroupLimitExceeded, 2026-09-23). These 5 supernets cover
  # every on-prem range routed in network-config.yaml's tgw-rt-spoke:
  #   172.16.10.0/24   Liberty
  #   172.26.0.0/15    Kennedy 172.26.4/22 + all 172.27.x
  #   172.20.0.0/21    RD 172.20.0-4/24
  #   192.168.0.0/16   Kennedy 192.168.x
  #   100.64.0.0/20    all three CGNAT source-NAT ranges (RD/Kennedy/Zima)
  # Tighten to exact ranges at the voice cutover if a narrower scope is wanted.
  default = [
    "172.16.10.0/24",
    "172.26.0.0/15",
    "172.20.0.0/21",
    "192.168.0.0/16",
    "100.64.0.0/20",
  ]
}

variable "db_client_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach MySQL 3306 on this box. In the destination this is
    the app tier + reporting consumers + VPN on-prem sites. Default = the
    shared-prod app subnet; add VPN ranges or specific consumers as needed.
  EOT
  type        = list(string)
  default     = ["10.12.1.0/24"]
}

variable "admin_cidrs" {
  description = "CIDRs allowed SSH (22) and the Aheeva admin GUI (8443). Default = shared-prod app subnet (bastion/EICE path)."
  type        = list(string)
  default     = ["10.12.1.0/24"]
}

# ----------------------------------------------------------------------------
# Ports (from the source AheevaV7 SG). Grouped so they can be toggled.
# ----------------------------------------------------------------------------

variable "sip_port" {
  description = "Inter-cluster SIP port (source SG: 5080 TCP+UDP, self-referenced)."
  type        = number
  default     = 5080
}

variable "rtp_from_port" {
  description = "RTP media range start (source SG: 10000-20000/udp)."
  type        = number
  default     = 10000
}

variable "rtp_to_port" {
  description = "RTP media range end."
  type        = number
  default     = 20000
}

variable "voice_tcp_ports" {
  description = "Extra Aheeva voice/app TCP ports the carriers use (source SG: 5901, 4331, 4343, and 5002-5004 handled separately)."
  type        = list(number)
  default     = [5901, 4331, 4343]
}

variable "db_port" {
  description = "MySQL port."
  type        = number
  default     = 3306
}

variable "eice_security_group_id" {
  description = "Optional EC2 Instance Connect Endpoint SG ID in shared-prod, to allow admin SSH via EICE. Empty to skip."
  type        = string
  default     = ""
}
