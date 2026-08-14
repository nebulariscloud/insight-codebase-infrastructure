variable "account_name" {
  description = "Spoke account label used in tags and session names."
  type        = string
}

variable "account_id" {
  description = "12-digit AWS account ID for the Perimeter spoke."
  type        = string
}

variable "stack_name" {
  description = "Short stack name."
  type        = string
  default     = "osticket-alb"
}

variable "region" {
  description = "AWS region the ALB lives in."
  type        = string
  default     = "us-east-2"
}

variable "ingress_vpc_id" {
  description = "Perimeter ingress VPC ID. Same VPC crm-alb and the shared ingress-alb live in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets in the perimeter ingress VPC, one per AZ (>= 2)."
  type        = list(string)
}

variable "allowed_source_cidrs" {
  description = <<-EOT
    Source CIDRs allowed inbound to the ALB on 80/443.

    Defaults to the internet because osTicket is a public-facing ticket portal.
    If it is only used by staff and known partners, tighten this — a ticketing
    system is a common target and the source Lightsail box was reachable from
    anywhere.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "backend_private_ip" {
  description = <<-EOT
    Private IP of the osTicket instance in shared-prod, pinned by the
    terraform/live/production/osticket leaf. Reached cross-VPC over the TGW,
    which is why the target attachment uses availability_zone = "all".
  EOT
  type        = string
}

variable "osticket_port" {
  description = "Backend port osTicket's Apache listens on."
  type        = number
  default     = 80
}

variable "osticket_host" {
  description = "Public hostname for osTicket. Also the ACM cert's domain name."
  type        = string
}

variable "cert_request_serial" {
  description = <<-EOT
    Bump this by one to throw away the current ACM certificate request and
    issue a brand new one.

    WHEN YOU NEED IT: an ACM request that is not validated within 72 hours goes
    to VALIDATION_TIMED_OUT and can never be validated afterwards. AWS's
    remedy is to delete it and request a new certificate. Because `status` is a
    computed attribute, a timed-out certificate shows NO plan diff — re-running
    the apply will not fix it. Bumping this serial is what forces the new
    request.

    HOW IT WORKS: the certificate is declared with
    `for_each = toset([tostring(var.cert_request_serial)])`, so the serial is
    part of the resource address. Changing it is a create-then-destroy rather
    than a no-op. See the long comment above the resource in main.tf.

    AFTER BUMPING: the new certificate has a DIFFERENT validation CNAME. Read
    `terraform output acm_validation_records` from the apply log and publish
    that one — any previously published record is dead.

    Expect to need this again: the validation record is added by hand at
    Network Solutions, so a 72-hour timeout is a foreseeable repeat.

    History:
      1 -> initial request (hostname tickets.*, then osticket.* after PR #57).
           The osticket.* request timed out unvalidated on 2026-08-13.
      2 -> re-request after that timeout.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.cert_request_serial >= 1 && floor(var.cert_request_serial) == var.cert_request_serial
    error_message = "cert_request_serial must be a whole number >= 1."
  }
}

variable "health_check_path" {
  description = <<-EOT
    HTTP health check path on the backend.

    osTicket's "/" typically 302-redirects (to /scp or the kb index), which is
    why health_check_matcher allows redirects by default. If a cleaner endpoint
    exists, point at that instead.
  EOT
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "HTTP codes considered healthy. Includes redirects because osTicket's root usually 302s."
  type        = string
  default     = "200,301,302"
}

variable "enable_https" {
  description = <<-EOT
    Two-stage TLS, because the DNS zone may be external and the cert has to
    validate before an HTTPS listener can reference it.

      false -> HTTP-only ALB. The ACM cert is still created (PENDING); add the
               validation CNAME from the acm_validation_records output.
      true  -> HTTPS listener attaches with the cert and HTTP 301-redirects
               to it. Only set this once the cert is ISSUED.
  EOT
  type        = bool
  default     = false
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
    Matches the 2000 used on the other public ALBs.

    A ticket portal sees far lower legitimate request rates than an API, so
    there is room to tighten this once the traffic baseline is captured. Do
    that rather than loosening it.
  EOT
  type        = number
  default     = 2000
}
