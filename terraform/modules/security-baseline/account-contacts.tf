###############################################################################
# Security Hub control Account.1
# - Security contact information should be provided for an AWS account.
#
# Account-level resource. No region alias needed; uses the default provider
# supplied by the consuming leaf (which points at the home region).
#
# Phone is sensitive at the variable level so Terraform redacts it from plan
# output. The leaf reads its value from SSM SecureString in SharedServices.
###############################################################################

resource "aws_account_alternate_contact" "security" {
  alternate_contact_type = "SECURITY"
  name                   = var.security_contact_name
  email_address          = var.security_contact_email
  phone_number           = var.security_contact_phone
  title                  = var.security_contact_title
}
