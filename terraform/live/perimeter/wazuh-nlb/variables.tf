variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the spoke."
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
  description = "AWS region the NLB lives in."
  type        = string
  default     = "us-east-2"
}

# ------------------------------------------------------------------
# Inputs the leaf needs
# ------------------------------------------------------------------

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID. The NLB and existing ALB live here."
  type        = string
}

variable "public_subnet_ids" {
  description = <<-EOT
    Public subnets in the ingress VPC, one per AZ. The NLB attaches an EIP
    to each, so the count of subnets == count of static IPs you publish.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Provide at least two subnets in different AZs."
  }
}

variable "ingress_alb_name" {
  description = <<-EOT
    Name of the existing LZA-managed IngressALB (default 'ingress-alb').
    Looked up via data.aws_lb so we don't hardcode the ARN.
  EOT
  type        = string
  default     = "ingress-alb"
}

variable "wazuh_manager_ips" {
  description = <<-EOT
    Private IPs of the Wazuh manager(s) reachable from the ingress VPC via TGW.
    These get registered as raw IP targets for 1514/1515. Usually one IP; add
    more if you have a Wazuh cluster.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.wazuh_manager_ips) >= 1
    error_message = "At least one Wazuh manager IP is required."
  }
}

variable "agent_event_port" {
  description = "Wazuh agent events port (TCP). Default 1514."
  type        = number
  default     = 1514
}

variable "agent_enroll_port" {
  description = "Wazuh agent enrollment port (TCP). Default 1515."
  type        = number
  default     = 1515
}

variable "https_port" {
  description = "HTTPS port the NLB exposes for the dashboard/API. Forwards to the existing ALB."
  type        = number
  default     = 443
}

variable "ingress_cidrs" {
  description = <<-EOT
    Source CIDRs allowed inbound to the NLB on the agent ports (1514/1515).
    Default 0.0.0.0/0 because Wazuh agents come from anywhere; tighten to
    the customer's egress IPs once known. 443 stays open to the world.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
