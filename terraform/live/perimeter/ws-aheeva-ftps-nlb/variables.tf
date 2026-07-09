variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Perimeter spoke."
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

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID (same as sftp-nlb / ingress-alb)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in the perimeter ingress VPC, one per AZ (>= 2)."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An NLB requires at least two subnets in different AZs."
  }
}

variable "ws_aheeva_private_ip" {
  description = <<-EOT
    Private IP of WS Aheeva in shared-prod. Read from the sibling leaf:
      cd ../../production/ws-aheeva && terraform output -raw private_ip
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.ws_aheeva_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

variable "ftps_control_port" {
  description = "FTPS implicit-TLS control port. 990."
  type        = number
  default     = 990
}

variable "ftps_passive_from" {
  description = <<-EOT
    FTPS passive data range start. Source uses 40000-40500 (501 ports).
    NLB has ONE listener per port, so a wide range = many listeners (AWS
    default quota is 50 listeners/NLB). STRONGLY prefer narrowing the passive
    range in the Aheeva FTPS config (e.g. 40000-40019 = 20 ports) and matching
    it here. See README.
  EOT
  type        = number
  default     = 40000
}

variable "ftps_passive_to" {
  description = "FTPS passive data range end. Narrow this (with the Aheeva config) to stay within the NLB listener quota."
  type        = number
  default     = 40019
}

variable "allowed_source_cidrs" {
  description = <<-EOT
    Source CIDRs allowed inbound to the NLB on the FTPS ports. These are the
    FTPS file-drop clients. Default open until the real client list is
    confirmed — tighten ASAP (enforced at the NLB SG).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
