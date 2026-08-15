###############################################################################
# Copy to terraform.tfvars and fill in.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "iccmaindb"
region       = "us-east-2"

snapshot_identifier = "iccmaindb-REPLACE_WITH_DEST_SNAPSHOT"

identifier            = "iccmaindb"
instance_class        = "db.t3.small"
allocated_storage_gib = 50
storage_type          = "gp3"
multi_az              = true
engine_version        = "5.7.44"

vpc_id = "vpc-04a8720d0ddb40713"
db_subnet_ids = [
  "subnet-REPLACE_A",
  "subnet-REPLACE_B",
]

# Bump this EVERY time db_subnet_ids changes, or the instance will not actually
# move — changing the IDs alone leaves db_subnet_group_name unchanged and RDS
# never re-places the network interfaces. Revision 1 = the original group name.
db_subnet_group_revision = 1

# Set true only while performing a subnet-group move, otherwise RDS defers it to
# the maintenance window and nothing relocates. Revert to false afterwards.
apply_immediately = false

app_client_cidrs = ["10.12.0.0/16"]

backup_retention_days = 7
backup_window         = "07:00-09:00"
maintenance_window    = "wed:05:30-wed:06:30"
deletion_protection   = true
