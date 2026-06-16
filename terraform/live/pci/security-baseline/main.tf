###############################################################################
# Wave 1 leaf for the PCI account.
#
# Closes Security Hub findings:
#   - SSM.7      (Critical) — block public sharing of SSM documents
#   - EC2.182    (High)     — block public access for EBS snapshots
#   - SSM.6      (Medium)   — SSM Automation CloudWatch logging
#   - Account.1  (Medium)   — SECURITY alternate contact
#
# Inspector findings (Inspector.1/2/3/4) are wired but disabled until decision
# item D-1 is resolved (see parent strategy spec).
###############################################################################

module "security_baseline" {
  source = "../../../modules/security-baseline"

  providers = {
    aws      = aws # default — home region (us-east-2), account-level resources
    aws.use1 = aws.use1
    aws.use2 = aws.use2
    aws.usw2 = aws.usw2
  }

  account_name = var.account_name

  security_contact_name  = var.security_contact_name
  security_contact_email = var.security_contact_email
  security_contact_phone = data.aws_ssm_parameter.security_contact_phone.value
  security_contact_title = var.security_contact_title

  # Inspector deferred to decision item D-1.
  inspector_enabled = false
}
