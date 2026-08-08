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
  default     = "crm-alb"
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
  description = "Perimeter ingress VPC ID. Same VPC the shared ingress-alb / webapps-alb live in."
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
  description = "Source CIDRs allowed inbound to the ALB on 80/443. Default internet; tighten if the ICC API should be restricted."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------------------
# Backend target — the insight-ubuntu-dev box in shared-prod (over TGW)
#
# Both APIs run on the SAME box, different ports:
#   :80 -> production API   (crm.insightgrouppr.com)
#   :81 -> development API  (crm-dev.insightgrouppr.com)
# ----------------------------------------------------------------------------

variable "backend_private_ip" {
  description = <<-EOT
    Private IP of the box running the ICC APIs in shared-prod. Read from:
      cd ../../production/insight-ubuntu-dev && terraform output -raw private_ip
    (Currently 10.12.1.71.)
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.backend_private_ip))
    error_message = "must be a dotted-quad IPv4 address."
  }
}

variable "prod_api_port" {
  description = "Backend port for the production API."
  type        = number
  default     = 80
}

variable "dev_api_port" {
  description = "Backend port for the development API."
  type        = number
  default     = 81
}

# ----------------------------------------------------------------------------
# Host-header routing
# ----------------------------------------------------------------------------

variable "prod_api_host" {
  description = "Host header that routes to the production API (:80)."
  type        = string
  default     = "crm.insightgrouppr.com"
}

variable "dev_api_host" {
  description = "Host header that routes to the development API (:81)."
  type        = string
  default     = "crm-dev.insightgrouppr.com"
}

variable "health_check_path" {
  description = "HTTP health check path on the backends."
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy. Widen if the API root returns e.g. 404 when healthy."
  type        = string
  default     = "200,301,302"
}

# ----------------------------------------------------------------------------
# TLS / cert
#
# The ACM cert is created in this leaf (SAN covering both hostnames), DNS
# validation. Because insightgrouppr.com DNS is managed OUTSIDE Route53, the
# validation records are emitted as outputs for the DNS admin to add by hand.
#
# HTTPS is staged: an ELB HTTPS listener can only attach an ISSUED cert, so:
#   1) First apply with enable_https=false -> HTTP-only ALB + cert (PENDING).
#      Add the validation CNAME(s) from the `acm_validation_records` output to
#      the external DNS. Cert transitions to ISSUED.
#   2) Set enable_https=true and re-apply -> HTTPS listener attaches, HTTP
#      redirects to HTTPS. Then point both hostnames at `alb_dns_name`.
# ----------------------------------------------------------------------------

variable "enable_https" {
  description = <<-EOT
    Flip to true only AFTER the ACM cert is ISSUED (validation records added to
    external DNS). Attaches the HTTPS listener and redirects HTTP->HTTPS. Keep
    false on the first apply so the cert has time to validate.
  EOT
  type        = bool
  default     = false
}

variable "alb_egress_cidrs" {
  description = <<-EOT
    CIDRs the ALB may reach on the DEV API port (:81). The alb module already
    opens egress for the prod port; this covers the extra backend port this
    leaf adds. Must match the module's egress_cidrs (default 10.0.0.0/8).
  EOT
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

# ----------------------------------------------------------------------------
# WAF
#
# The Web ACL is built in this leaf by the waf-managed module and associated
# with the ALB, so there is no ARN to pass in. Tuning knobs live here.
# ----------------------------------------------------------------------------

variable "waf_rate_limit" {
  description = <<-EOT
    Requests per 5 minutes per source IP before the rate-based rule blocks.
    Matches the 2000 used on ingress-alb-waf / scriptcase-lb-waf.

    This ALB fronts APIs, and API clients burst harder than browsers. If a
    legitimate integration starts getting 403s, raise this (or add a scoped
    allow entry) rather than removing the rule.
  EOT
  type        = number
  default     = 2000
}
