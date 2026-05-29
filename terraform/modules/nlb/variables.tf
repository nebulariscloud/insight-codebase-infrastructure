variable "name" {
  description = "NLB name. Must be <=32 chars, lowercase, hyphens."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase, start/end alphanumeric, max 32 chars."
  }
}

variable "vpc_id" {
  description = "VPC where the NLB lives. Read from /accelerator/network/vpc/<name>/id."
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Public subnets for the NLB - one per AZ. Each gets its own EIP, so the
    list length determines how many static IPs you publish to clients.
    Two subnets is the minimum for availability.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An NLB requires at least two subnets in different AZs."
  }
}

variable "scheme" {
  description = "internet-facing or internal."
  type        = string
  default     = "internet-facing"
  validation {
    condition     = contains(["internet-facing", "internal"], var.scheme)
    error_message = "scheme must be internet-facing or internal."
  }
}

variable "allocate_eips" {
  description = <<-EOT
    Allocate one EIP per subnet so the NLB has stable static IPs. Set false
    only if you don't care about IP stability (rare for an internet-facing NLB).
  EOT
  type        = bool
  default     = true
}

variable "cross_zone_load_balancing" {
  description = <<-EOT
    Cross-zone LB. NLB cross-zone is BILLED extra (data transfer per-GB)
    unlike ALB which is free. Default false to keep costs predictable.
    Flip true if a single-AZ outage of targets must keep traffic balanced.
  EOT
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Deletion protection on the NLB. Strongly recommended for prod."
  type        = bool
  default     = true
}

variable "security_group_ids" {
  description = <<-EOT
    Optional SGs to attach to the NLB. NLBs originally had no SG; newer NLBs
    support them. Use this if you want to scope inbound to specific source
    CIDRs (e.g. customer egress IPs) at the LB layer rather than per-target.
    Empty list = no SG attached.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags merged on top of provider default_tags."
  type        = map(string)
  default     = {}
}
