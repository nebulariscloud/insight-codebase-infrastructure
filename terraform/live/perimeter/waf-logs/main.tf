###############################################################################
# WAF logs (Perimeter / us-east-2)
#
# Builds the WAF log destination bucket + KMS CMK and turns on logging for
# every Web ACL named in var.web_acl_names. As of 2026-08-10 that is all four
# perimeter Web ACLs:
#   - ingress-alb-waf      (custom-stacks/ingress-alb.yaml)      CFN-managed
#   - scriptcase-lb-waf    (custom-stacks/scriptcase-lb.yaml)    CFN-managed
#   - crm-alb-waf          (live/perimeter/crm-alb)              Terraform
#   - osticket-alb-waf     (live/perimeter/osticket-alb)         Terraform
#
# Why this leaf can attach logging to LZA-owned Web ACLs without violating
# the LZA-vs-Terraform ownership boundary:
#
#   aws_wafv2_web_acl_logging_configuration is an independent AWS resource
#   from aws_wafv2_web_acl. Creating one does not modify the underlying
#   Web ACL or its CFN stack; CFN's drift detection won't notice. This is
#   the same shape we already use for aws_wafv2_web_acl_association in the
#   alb module - attach to a resource without owning it.
#
# The list shape (rather than one variable per Web ACL, which is what this
# leaf had until 2026-08-10) exists so adding a Web ACL is a one-line tfvars
# edit. The old fixed-pair shape is why crm-alb-waf and osticket-alb-waf went
# unlogged from creation until 2026-08-10 - the leaf had no way to express a
# third or fourth ACL, so nothing failed and nobody noticed.
###############################################################################

# Look up each Web ACL by name. ARNs are stable across regenerations of the
# LZA stack, but the lookup makes that automatic.
data "aws_wafv2_web_acl" "this" {
  for_each = toset(var.web_acl_names)

  name  = each.value
  scope = "REGIONAL"
}

module "waf_logs" {
  source = "../../../modules/waf-logs"

  name = "perimeter-${var.region}"

  # WAF requires the bucket to start with 'aws-waf-logs-'. The full name
  # '<prefix>-<account>-<region>' mirrors the LZA elb-access-logs naming
  # so it slots into the same operational mental model.
  bucket_name = "aws-waf-logs-${var.account_id}-${var.region}"

  log_retention_days = var.log_retention_days

  # The module's for_each over this list is keyed by ARN, so the two Web ACLs
  # that were already logging keep their exact existing state addresses.
  # Adding names here is therefore a create-only plan - it never replaces or
  # destroys an existing logging configuration.
  attach_to_web_acl_arns = [
    for name in var.web_acl_names : data.aws_wafv2_web_acl.this[name].arn
  ]
}

###############################################################################
# Outputs - the monitoring leaf can read these via terraform_remote_state if
# we ever want to attach Athena / metric filters here. For now they're for
# verification.
###############################################################################

output "bucket_name" {
  description = "Name of the WAF logs bucket."
  value       = module.waf_logs.bucket_name
}

output "bucket_arn" {
  description = "ARN of the WAF logs bucket."
  value       = module.waf_logs.bucket_arn
}

output "kms_alias" {
  description = "KMS alias encrypting the WAF logs bucket."
  value       = module.waf_logs.kms_alias
}

output "web_acl_arns_logged" {
  description = "Map of Web ACL name => ARN that logging is attached to."
  value       = { for name, acl in data.aws_wafv2_web_acl.this : name => acl.arn }
}
