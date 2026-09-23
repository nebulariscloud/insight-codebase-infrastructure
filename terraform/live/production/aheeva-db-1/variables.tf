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
  default     = "aheeva-db-1"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is m5.2xlarge; kept the same."
  type        = string
  default     = "m5.2xlarge"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, copied + re-encrypted from the source-tenant
    "Aheeva DB 1" AMI. Source root volume is UNENCRYPTED, so the copy just
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
  description = "shared-prod app subnet ID (private). Reached over the Site-to-Site VPNs via TGW; no public IP."
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
  description = "Root volume size. Source is 200 GiB; match it."
  type        = number
  default     = 200
}

variable "ebs_kms_key_arn" {
  description = "Optional override for the EBS encryption key ARN. Empty auto-resolves the LZA EBS key."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Security-group source scopes (see the aheeva-asterisk-1 leaf for the full
# rationale). The three Aheeva boxes shared one SG in the source, so the same
# scoped shape is reproduced here. On a DB-only box the voice rules are inert
# but kept behind the variable in case this box also runs Aheeva voice roles.
# Nothing is open to the internet.
# ----------------------------------------------------------------------------

variable "intra_cluster_cidrs" {
  description = "CIDRs of the Aheeva cluster peers + CTI v7 inside shared-prod. Default = the app subnet."
  type        = list(string)
  default     = ["10.12.1.0/24"]
}

variable "voice_source_cidrs" {
  description = <<-EOT
    On-prem VPN source ranges for any voice ports (SIP/RTP) this box serves.
    Defaulted to the ranges routed in network-config.yaml's tgw-rt-spoke
    (Liberty / Kennedy / RD / Zima) incl. the CGNAT source-NAT ranges. Prune
    at the voice cutover; set to [] if this DB box serves no voice.
  EOT
  type        = list(string)
  default = [
    "172.16.10.0/24",
    "172.27.150.0/27",
    "172.27.100.0/24",
    "172.27.50.0/25",
    "172.27.75.0/24",
    "172.27.200.0/24",
    "172.27.220.0/24",
    "172.26.4.0/22",
    "192.168.100.0/24",
    "192.168.20.128/29",
    "192.168.70.0/26",
    "100.64.4.0/22",
    "172.20.0.0/24",
    "172.20.1.0/24",
    "172.20.2.0/24",
    "172.20.3.0/24",
    "172.20.4.0/24",
    "100.64.0.0/22",
    "100.64.8.0/22",
  ]
}

variable "db_client_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach MySQL 3306 on this box — the app tier + reporting
    consumers + VPN on-prem sites. Default = the shared-prod app subnet; add
    VPN ranges or specific consumers as needed.
  EOT
  type        = list(string)
  default     = ["10.12.1.0/24"]
}

variable "admin_cidrs" {
  description = "CIDRs allowed SSH (22) and the Aheeva admin GUI (8443). Default = shared-prod app subnet (bastion/EICE path)."
  type        = list(string)
  default     = ["10.12.1.0/24"]
}

variable "sip_port" {
  description = "Inter-cluster SIP port (source SG: 5080 TCP+UDP, self-referenced)."
  type        = number
  default     = 5080
}

variable "rtp_from_port" {
  description = "RTP media range start."
  type        = number
  default     = 10000
}

variable "rtp_to_port" {
  description = "RTP media range end."
  type        = number
  default     = 20000
}

variable "voice_tcp_ports" {
  description = "Extra Aheeva voice/app TCP ports (source SG: 5901, 4331, 4343)."
  type        = list(number)
  default     = [5901, 4331, 4343]
}

variable "db_port" {
  description = "MySQL port."
  type        = number
  default     = 3306
}

variable "eice_security_group_id" {
  description = "Optional EC2 Instance Connect Endpoint SG ID in shared-prod. Empty to skip."
  type        = string
  default     = ""
}
