###############################################################################
# RDS iccmaindb — Wave 2. Fill snapshot_identifier (the copied+re-encrypted
# destination snapshot) + db_subnet_ids before apply.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "iccmaindb"
region       = "us-east-2"

# The destination snapshot to restore from — set after the source snapshot is
# shared, copied cross-region, and re-encrypted with the destination CMK.
snapshot_identifier = "iccmaindb-REPLACE_WITH_DEST_SNAPSHOT"

identifier            = "iccmaindb"
instance_class        = "db.t3.small"
allocated_storage_gib = 50
storage_type          = "gp3"
multi_az              = true
engine_version        = "5.7.44"

vpc_id = "vpc-04a8720d0ddb40713"

# shared-prod data subnets (data-a + data-b). Confirm the IDs:
#   aws ec2 describe-subnets --region us-east-2 \
#     --filters "Name=vpc-id,Values=vpc-04a8720d0ddb40713" \
#     "Name=tag:Name,Values=*shared-prod-data*" \
#     --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table
db_subnet_ids = [
  "subnet-REPLACE_DATA_A",
  "subnet-REPLACE_DATA_B",
]

# App-tier clients that reach MySQL (WS Aheeva, the two webapps). Private only.
app_client_cidrs = ["10.12.0.0/16"]

backup_retention_days = 7
backup_window         = "07:00-09:00"
maintenance_window    = "wed:05:30-wed:06:30"
deletion_protection   = true
