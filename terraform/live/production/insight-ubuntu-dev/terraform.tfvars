###############################################################################
# insight-ubuntu-dev (Production / shared-prod, us-east-2).
#
# Dev-side sibling of insight-ubuntu-prod. Same shape, same access model,
# separate state and separate IP so changes on this box don't affect prod.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "insight-ubuntu-dev"
region       = "us-east-2"

name          = "insight-ubuntu-dev"
instance_type = "t3.medium"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# One address up from insight-ubuntu-prod (10.12.1.70).
private_ip = "10.12.1.71"

root_volume_size_gib = 30

eice_security_group_id = "sg-0a990a87e6abca926"

# The ICC CRM app runs on this box — grant it access to the data plane
# provisioned by the icc-crm-backend leaf (DynamoDB + S3 + Cognito).
enable_icc_data_access = true
