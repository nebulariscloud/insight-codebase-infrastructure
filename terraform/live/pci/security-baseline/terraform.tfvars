###############################################################################
# All values use the defaults from variables.tf. This file exists so the CI's
# -var-file=terraform.tfvars flag finds something to read.
#
# To override any default, uncomment the matching line and set a value.
# Anything sensitive (e.g. the security contact phone) is read from SSM
# SecureString in providers.tf, not from this file.
###############################################################################

# account_name = "PCI"

# Set explicitly only if /accelerator/organization/account-ids/PCI is not yet
# published in SharedServices SSM. Default behavior is to read it from SSM.
# account_id = "123456789012"

# security_contact_name  = "Alex Gonzalez"
# security_contact_email = "security@nebulariscloud.com"
# security_contact_title = "CEO"
