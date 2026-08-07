###############################################################################
# RDS iccmaindb — Wave 2. Fill snapshot_identifier (the copied+re-encrypted
# destination snapshot) + db_subnet_ids before apply.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "iccmaindb"
region       = "us-east-2"

# The destination snapshot to restore from.
#
# NOTE: this is the SECOND destination copy, re-encrypted onto this leaf's own CMK
# (alias/iccmaindb-rds). The first copy (`iccmaindb-dest`) was encrypted with
# alias/accelerator/ebs/default-encryption/key, whose key policy is scoped to
# EC2 (`kms:ViaService = ec2.<region>.amazonaws.com`) and grants RDS nothing — so
# RestoreDBInstanceFromDBSnapshot failed with KMSKeyNotAccessibleFault. Restoring
# needs the snapshot's key to be usable by RDS, so we re-copied onto our own CMK:
#
#   aws rds copy-db-snapshot --region us-east-2 \
#     --source-db-snapshot-identifier iccmaindb-dest \
#     --target-db-snapshot-identifier iccmaindb-dest-cmk \
#     --kms-key-id alias/iccmaindb-rds
snapshot_identifier = "iccmaindb-dest-cmk"

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
# KNOWN ISSUE — revisit BEFORE CUTOVER, not before merge.
# Both data subnets sit inside 10.12.0.0/24, which the client reported as the
# Kennedy site's camera network. If that camera net is a /24 (or less specific),
# the Kennedy FortiGate holds a more-specific local route for this space and will
# never send DB traffic over the VPN — Kennedy's reporting clients would not reach
# this database.
#
# Why this does NOT block the apply: until cutover this instance serves no traffic
# (it only consumes binlogs), so changing its subnet group in that window costs a
# brief interruption to a database nobody queries — just re-run
# mysql.rds_start_replication afterwards. The expensive-to-reverse window opens at
# cutover, not now.
#
# Pre-cutover action: get the COMPLETE IP inventory for all four sites (Liberty,
# Kennedy, RD, Zima) — we only learned about the Kennedy cameras incidentally and
# have no verified map. Then place the DB once, correctly. If a move is needed, the
# app subnets are the fallback (outside 10.12.0.0/24, two AZs, so the RDS multi-AZ
# subnet-group requirement is still satisfied):
#   app-a  subnet-00d31cac6422417c4 = 10.12.1.0/24  (us-east-2a)
#   app-b  <look up>                = 10.12.2.0/24  (us-east-2b)
# Note: app subnets are NOT automatically safe either — if any site uses 10.12.1.x
# or 10.12.2.x they break instead. Hence needing the full map.
db_subnet_ids = [
  "subnet-092d9baf6d34778e2",
  "subnet-0e802f8a78c72c225",
]

# App-tier clients that reach MySQL (WS Aheeva, the two webapps, osTicket, n8n —
# anything inside shared-prod). Private only.
app_client_cidrs = ["10.12.0.0/16"]

# On-prem reporting clients arriving over the four Site-to-Site VPNs.
# Native ranges arrive untranslated; 100.64.x are the sites' 10.234.x LANs
# source-NATted (10.234.x collides with GlobalCidr 10.0.0.0/8 and is unroutable).
# Never list raw 10.234.x here. Per-site map: docs/07-Operations/cti-v7-open-items.md §D
vpn_client_cidrs = [
  # --- Liberty (peer 23.249.138.106) ---
  "172.16.10.0/24",

  # --- Insight Kennedy / Puerto Rico HQ (peer 64.89.2.105) ---
  "172.27.150.0/27",
  "172.27.100.0/24",
  "172.27.50.0/25",
  "172.27.75.0/24",
  "172.27.200.0/24",
  "172.27.220.0/24",
  "172.26.4.0/22",
  "192.168.100.0/24",
  "192.168.20.128/29",
  "192.168.70.0/26",
  "100.64.4.0/22", # NAT for 10.234.5.0/26

  # --- Insight RD / Republica Dominicana (peer 190.166.239.186) ---
  "172.20.0.0/24",
  "172.20.1.0/24",
  "172.20.2.0/24",
  "172.20.3.0/24",
  "172.20.4.0/24",
  "100.64.0.0/22", # NAT for 10.234.3.0/24 + 10.234.4.0/24

  # --- Insight Zima / Colombia (peer 181.207.82.178) ---
  "100.64.8.0/22", # NAT for all 11 of Zima's 10.234.x subnets
]

# Replica guard — rejects accidental writes while replicating from the source.
# !! SET TO "0" AT CUTOVER or the applications cannot write. !!
read_only = "1"

backup_retention_days = 7
backup_window         = "07:00-09:00"
maintenance_window    = "wed:05:30-wed:06:30"
deletion_protection   = true
