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
  description = "AWS region the NLB lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Inputs the leaf needs
# ----------------------------------------------------------------------------

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID. Same VPC the IngressALB / wazuh-nlb / sftp-nlb live in."
  type        = string
}

variable "public_subnet_ids" {
  description = <<-EOT
    Public subnets in the perimeter ingress VPC, one per AZ. Same subnets
    used by the existing IngressALB / wazuh-nlb / sftp-nlb leaves.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An NLB requires at least two subnets in different AZs."
  }
}

variable "sftp_server_private_ip" {
  description = <<-EOT
    Private IP of the SFTP server in shared-prod. Read it from the
    sibling production/sftp-server-claro leaf:

      cd ../../production/sftp-server-claro
      terraform output -raw private_ip
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", var.sftp_server_private_ip))
    error_message = "sftp_server_private_ip must be a dotted-quad IPv4 address."
  }
}

variable "sftp_port" {
  description = "SFTP listener port. Must match what the SFTP daemon listens on inside the instance."
  type        = number
  default     = 22
}

variable "allowed_source_cidrs" {
  description = <<-EOT
    Source CIDRs allowed inbound to the NLB on the SFTP port. Default
    open until you have the partner's egress IPs; tighten as soon as
    they are known. The NLB SG is the IP allowlist enforcement point
    (preserve_client_ip is off, so the SFTP server itself only sees
    NLB private IPs).
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
