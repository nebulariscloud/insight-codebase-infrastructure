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
  default     = "aheeva-cti-v86"
}

variable "instance_type" {
  description = "EC2 instance type. Source box is c5.2xlarge; kept the same."
  type        = string
  default     = "c5.2xlarge"
}

variable "ami_id" {
  description = <<-EOT
    AMI ID in us-east-2, registered from the block-level `dd` chain that severed
    the delisted CentOS 7 Marketplace product code `cvugziknvmxgqna9noibqnnsy`.
    Verified `ProductCodes: null`. Carries BOTH block device mappings
    (/dev/sda1 185 GiB, /dev/sdb 8 GiB).
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

variable "public_subnet_id" {
  description = <<-EOT
    shared-prod PUBLIC subnet ID — the IGW-routed /27 created by the guardrail
    exception. Not an app subnet: this box needs a directly-attached EIP.

    Currently `subnet-08ce7fb6c30eed107` (10.12.0.192/27, us-east-2a), recreated
    by the LZA pipeline on 2026-09-10 after the September config incident deleted
    the original. Two earlier IDs are traps and must not be used:
      subnet-0dc7b70d38275e775 — deleted by that incident
      subnet-0919739a39165a934 — undeletable orphan, retagged
                                 ORPHANED-do-not-use-was-shared-prod-public-a
  EOT
  type        = string
}

variable "private_ip" {
  description = <<-EOT
    Static private IP inside the public subnet. PINNED deliberately: the DB
    replica's `CHANGE MASTER TO MASTER_HOST=...` targets this address, so it must
    not move across instance replacements.

    Must be inside 10.12.0.192/27. AWS reserves .192-.195 and .223, so the usable
    range is 10.12.0.196 through 10.12.0.222 — 27 addresses, shared with the
    cti-v7 leaf which does NOT pin one.
  EOT
  type        = string
  default     = ""
}

variable "key_name" {
  description = <<-EOT
    EC2 key pair name. Left EMPTY: the migrated image already carries the
    `Aheeva` public key in authorized_keys and the team holds Aheeva.pem, so
    there is guaranteed SSH access without one. This differs from cti-v7, which
    needed its own `cti-v7-admin` key pair precisely because nobody held the
    source key.

    WARNING: setting this later FORCES INSTANCE REPLACEMENT.
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size_gib" {
  description = "Root volume size. Source is 185 GiB; match it or the AMI will not fit."
  type        = number
  default     = 185
}

variable "ebs_kms_key_arn" {
  description = "Optional override for the EBS encryption key ARN. Empty auto-resolves alias/accelerator/ebs/default-encryption/key."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# SIP / RTP
# ----------------------------------------------------------------------------

variable "sip_peer_cidrs" {
  description = <<-EOT
    CIDRs allowed inbound on UDP 5060, and included in the RTP media range.
    Each carrier or SIP peer that sends INVITEs to this box.

    ⚠️ EMPTY BY DEFAULT AND THAT IS DELIBERATE. The peer list is questionnaire
    Section 5 and is unanswered. Applying with an empty list gives a box with no
    SIP ingress — correct and safe for something not yet in service.

    ⚠️ NEVER set this to 0.0.0.0/0. UDP 5060 is the most scanned port profile on
    the internet and SIP brute-force into toll fraud is the standard outcome.

    Populating this list renumbers the rtp and db rules (the module keys rules by
    list index), so do it before the box carries traffic and expect to authorise
    it with an ALLOW-DESTROY line.
  EOT
  type        = list(string)
  default     = []
}

variable "rtp_extra_cidrs" {
  description = <<-EOT
    Additional RTP media sources beyond sip_peer_cidrs — media does not always
    originate from the signalling address.

    For reference, cti-v7 carries 64.89.2.105/32, 66.231.161.164/32 and
    1.1.1.1/32, the last being a vendor-confirmed intentional Aheeva special
    config. Do NOT copy those here without confirming they apply to v8.6.
  EOT
  type        = list(string)
  default     = []
}

variable "rtp_from_port" {
  description = <<-EOT
    RTP range start. The migrated box's /etc/asterisk/rtp.conf says
    rtpstart=10000, rtpend=20000, so the default matches what the box will
    actually negotiate.

    cti-v7 narrowed its equivalent to 10000-11000. Narrowing here requires
    editing rtp.conf IN-BOX as well — narrowing only the security group silently
    breaks media on calls that land on a higher port.
  EOT
  type        = number
  default     = 10000
}

variable "rtp_to_port" {
  description = "RTP range end. See rtp_from_port. Matches rtp.conf's rtpend=20000."
  type        = number
  default     = 20000
}

# ----------------------------------------------------------------------------
# Admin and database
# ----------------------------------------------------------------------------

variable "admin_ports" {
  description = <<-EOT
    Aheeva admin GUI ports, allowed only from the perimeter ingress VPC so TLS
    terminates at the ALB with an allowlisted listener. Never exposed directly.

    The source security group had 8443 and 9443 open (9443 described as "vicc8"
    plus AmEx HQ 139.71.144.9/32). Questionnaire Section 6 — which ports are
    actually in use — is unanswered; the default position is to drop anything
    unconfirmed.
  EOT
  type        = list(number)
  default     = [8443, 9443]
}

variable "admin_ingress_cidr" {
  description = "CIDR of the perimeter ingress VPC. Admin ports are reachable only from here."
  type        = string
  default     = "10.0.0.0/20"
}

variable "db_port" {
  description = "MariaDB port."
  type        = number
  default     = 3306
}

variable "db_client_cidrs" {
  description = <<-EOT
    CIDRs allowed inbound on db_port. This box is the MariaDB MASTER, so the
    replica's address must be here or replication cannot be established —
    replication is an inbound connection FROM the replica.

    Defaults to the replica only (10.12.1.54/32, instance i-034a56060c27f95fb).
    The source security group also shows Scriptcase 34.230.213.145,
    Webserver-Reportes 3.87.101.184 and 3.84.227.17, and webapps php7.3
    172.30.2.118 — several already migrated into Production and now egressing via
    the NAT EIPs. Questionnaire Section 4 settles who still needs access.

    APPEND ONLY. This list is last in the rule order specifically so that
    appending does not renumber anything.
  EOT
  type        = list(string)
  default     = ["10.12.1.54/32"]
}
