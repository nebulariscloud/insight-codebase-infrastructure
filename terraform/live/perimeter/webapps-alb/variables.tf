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
  description = "AWS region the ALB lives in."
  type        = string
  default     = "us-east-2"
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID. Same VPC the shared ingress-alb / sftp-nlb live in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in the perimeter ingress VPC, one per AZ (>= 2)."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires at least two subnets in different AZs."
  }
}

variable "certificate_arn" {
  description = <<-EOT
    ACM cert ARN for the HTTPS listener (us-east-2, Perimeter account). Should
    cover both app hostnames (SAN or wildcard). Empty = HTTP-only listener
    (not recommended for production web apps).
  EOT
  type        = string
  default     = ""
}

# ----------------------------------------------------------------------------
# Backend targets (private IPs of the two webapps in shared-prod, over TGW)
# ----------------------------------------------------------------------------

variable "webapps_server_private_ip" {
  description = <<-EOT
    Private IP of the webapps server in shared-prod. Read from the sibling leaf:
      cd ../../production/webapps && terraform output -raw private_ip
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.webapps_server_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

variable "webapps_php73_private_ip" {
  description = <<-EOT
    Private IP of the webapps php7.3 server in shared-prod. Read from:
      cd ../../production/webapps-php73 && terraform output -raw private_ip
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.webapps_php73_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

# ----------------------------------------------------------------------------
# Host-header routing
# ----------------------------------------------------------------------------

variable "webapps_server_host" {
  description = "Host header that routes to the webapps server (e.g. webapps.<corp>.com)."
  type        = string
}

variable "webapps_php73_host" {
  description = "Host header that routes to the webapps php7.3 server (e.g. php73.<corp>.com)."
  type        = string
}

variable "target_port" {
  description = "Backend port the webapps listen on. Both serve HTTP on 80 behind TLS-terminating ALB."
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "HTTP health check path on the backends."
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy."
  type        = string
  default     = "200,301,302"
}

variable "allowed_source_cidrs" {
  description = "Source CIDRs allowed inbound to the ALB on 80/443. Default internet; tighten if these apps are meant to be restricted."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "waf_web_acl_arn" {
  description = "Optional WAF Web ACL ARN to attach to the ALB. Empty to skip."
  type        = string
  default     = ""
}
