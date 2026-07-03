###############################################################################
# insight-ubuntu-prod (Production / shared-prod, us-east-2).
#
# Private t3.medium on Ubuntu 22.04 LTS. No inbound from anywhere; admin
# access via SSM Session Manager only. Sibling: insight-ubuntu-dev.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "insight-ubuntu-prod"
region       = "us-east-2"

name          = "insight-ubuntu-prod"
instance_type = "t3.medium"

# vpc-04a8720d0ddb40713    = AWSAccelerator-us-east-2-shared-prod
# subnet-00d31cac6422417c4 = AWSAccelerator-us-east-2-shared-prod-app-a (10.12.1.0/24)
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Existing tenants in 10.12.1.0/24:
#   10.12.1.50  - sftp-server
#   10.12.1.51  - sftp-server-claro
#   10.12.1.60  - moodle
#   10.12.1.121 - wazuh
#   10.12.1.174 - scriptcase-php-73
# .70 keeps a clean gap above the existing migrated servers.
private_ip = "10.12.1.70"

root_volume_size_gib = 30

# EICE endpoint SG in shared-prod (reused from sftp-server / moodle).
# Fallback admin path if SSM Session Manager is ever unavailable.
eice_security_group_id = "sg-0a990a87e6abca926"
