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
  default     = "limesurvey-alb"
}

variable "region" {
  description = "AWS region the ALB lives in."
  type        = string
  default     = "us-east-2"
}

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID. Same VPC crm-alb / osticket-alb / the shared ingress-alb live in."
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

variable "allowed_source_cidrs" {
  description = <<-EOT
    Source CIDRs allowed inbound to the ALB on 80/443. Locked to the partner
    allowlist carried over from the source webserver SG's :443 rule (LimeSurvey
    is not a public portal — it's used by known partners). The bogus
    0.0.0.0/32 entries in the source SG were dropped. Tighten/extend as needed.
  EOT
  type        = list(string)
  default = [
    "64.89.2.21/32",
    "179.51.68.42/32",
    "200.88.114.16/29",
    "179.51.75.18/32",
    "179.51.75.22/32",
    "64.89.2.20/32",
    "207.204.158.60/30",
    "181.36.228.170/32",
    "186.150.204.2/32",
    "54.152.253.96/32",
    "179.51.78.170/32",
    "190.167.33.43/32",
    "190.166.239.186/32",
    "24.139.143.242/32",
    "190.26.16.123/32",
    "190.71.134.67/32",
    "200.116.242.124/32",
    "190.131.229.34/32",
    "190.70.103.98/32",
    "190.14.235.50/32",
    "200.116.198.67/32",
    "154.64.223.34/32",
    "186.30.29.28/32",
    "190.71.135.203/32",
    "190.14.235.66/32",
    "65.23.211.232/29",
    "66.50.181.184/29",
    "64.89.2.105/32",
    "181.204.67.42/32",
    "190.14.226.41/32",
    "190.60.92.152/29",
    "152.200.208.174/32",
    "181.207.82.178/32",
  ]
}

variable "backend_private_ip" {
  description = <<-EOT
    Private IP of the icc-limesurvey box in shared-prod, pinned by the
    terraform/live/production/icc-limesurvey leaf (10.12.1.83). Reached
    cross-VPC over the TGW, which is why the target attachment uses
    availability_zone = "all".
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.backend_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

variable "backend_port" {
  description = "Backend port LimeSurvey's Apache listens on."
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "HTTP health check path. LimeSurvey's / typically 200s or 302s to /index.php/admin."
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy. Includes redirects since LimeSurvey's root often 302s."
  type        = string
  default     = "200,301,302"
}

variable "enable_https" {
  description = <<-EOT
    INTERIM: false. There is no domain/cert yet, so the ALB serves LimeSurvey
    over HTTP on its own AWS DNS name (alb_dns_name output) — usable today with
    no external DNS.

    When the domain is ready: create an ACM cert for the hostname, set
    certificate_arn + enable_https = true, re-apply. HTTP then 301-redirects to
    HTTPS. (Add the cert resource + host var at that point, mirroring
    osticket-alb.)
  EOT
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes per source IP before the rate-based rule blocks. Matches the other public ALBs."
  type        = number
  default     = 2000
}
