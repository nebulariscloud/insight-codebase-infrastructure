# Copy to terraform.tfvars and edit before running.
# terraform.tfvars is gitignored by default; existing leaves in this repo
# commit theirs with `git add -f` so CI is deterministic. Same applies here.

# account_name = "PCI"
# account_id   = ""   # leave empty to read /accelerator/organization/account-ids/PCI from SSM

# security_contact_name  = "Alex Gonzalez"
# security_contact_email = "security@nebulariscloud.com"
# security_contact_title = "CEO"

# security_contact_phone is NOT set here. It comes from the SharedServices SSM
# SecureString /security-baseline/security-contact-phone, read in providers.tf.
