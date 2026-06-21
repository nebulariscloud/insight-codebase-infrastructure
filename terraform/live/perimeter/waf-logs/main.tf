###############################################################################
# WAF logs (Perimeter / us-east-2)
#
# Builds the WAF log destination bucket + KMS CMK and turns on logging for
# the two existing CFN-managed Web ACLs:
#   - ingress-alb-waf      (custom-stacks/ingress-alb.yaml)
#   - scriptcase-lb-waf    (custom-stacks/scriptcase-lb.yaml)
#
# Why this leaf can attach logging to LZA-owned Web ACLs without violating
# the LZA-vs-Terraform ownership boundary:
#
#   aws_wafv2_web_acl_logging_configuration is an independent AWS resource
#   from aws_wafv2_web_acl. Creating one does not modify the underlying
#   Web ACL or its CFN stack; CFN's drift detection won't notice. This is
#   the same shape we already use for aws_wafv2_web_acl_association in the
#   alb module - attach to a resource without owning it.
###############################################################################

# Look up the existing Web ACLs by name. ARNs are stable across regenerations
# of the LZA stack, but the lookup makes that automatic.
data "aws_wafv2_web_acl" "ingress" {
  name  = var.ingress_web_acl_name
  scope = "REGIONAL"
}

data "aws_wafv2_web_acl" "scriptcase" {
  name  = var.scriptcase_web_acl_name
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

  attach_to_web_acl_arns = [
    data.aws_wafv2_web_acl.ingress.arn,
    data.aws_wafv2_web_acl.scriptcase.arn,
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

output "ingress_web_acl_arn_logged" {
  description = "ARN of the IngressALB Web ACL that logging is now attached to."
  value       = data.aws_wafv2_web_acl.ingress.arn
}

output "scriptcase_web_acl_arn_logged" {
  description = "ARN of the Scriptcase Web ACL that logging is now attached to."
  value       = data.aws_wafv2_web_acl.scriptcase.arn
}
