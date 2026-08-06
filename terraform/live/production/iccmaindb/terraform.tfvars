###############################################################################
# RDS iccmaindb — Wave 2. Fill snapshot_identifier (the copied+re-encrypted
# destination snapshot) + db_subnet_ids before apply.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "iccmaindb"
region       = "us-east-2"

# The destination snapshot to restore from — created in Part 1 (source snapshot ->
# transfer CMK -> shared to Production -> cross-region copy + re-encrypt).
snapshot_identifier = "iccmaindb-dest"

identifier            = "iccmaindb"
instance_class        = "db.t3.small"
allocated_storage_gib = 50
storage_type          = "gp3"
multi_az              = true
engine_version        = "5.7.44"

vpc_id = "vpc-04a8720d0ddb40713"

# shared-prod data subnets (data-a us-east-2a + data-b us-east-2b).
#   data-a subnet-092d9baf6d34778e2 = 10.12.0.64/26
#   data-b subnet-0e802f8a78c72c225 = 10.12.0.128/26
#
# !! DECISION PENDING — Kennedy IP conflict — CONFIRM BEFORE MERGE !!
# Both data subnets sit inside 10.12.0.0/24, which the client reported as the
# Kennedy site's camera network. If that camera net is a /24 (or anything less
# specific), the Kennedy FortiGate holds a more-specific local route for this
# space and will never send DB traffic over the VPN — Kennedy's reporting clients
# would not reach this database.
#
# If Kennedy's camera network IS 10.12.0.0/24, swap these for the APP subnets,
# which sit OUTSIDE the conflict and are still in two AZs (satisfying the RDS
# multi-AZ subnet-group requirement):
#   app-a  subnet-00d31cac6422417c4 = 10.12.1.0/24  (us-east-2a)
#   app-b  <look up>                = 10.12.2.0/24  (us-east-2b)
# Changing this now is one line; moving a live RDS instance between subnets later
# is disruptive.
db_subnet_ids = [
  "subnet-092d9baf6d34778e2",
  "subnet-0e802f8a78c72c225",
]

# App-tier clients that reach MySQL (WS Aheeva, the two webapps). Private only.
app_client_cidrs = ["10.12.0.0/16"]

backup_retention_days = 7
backup_window         = "07:00-09:00"
maintenance_window    = "wed:05:30-wed:06:30"
deletion_protection   = true
