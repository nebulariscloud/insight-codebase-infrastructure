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
# TEMPORARILY false to permit the subnet-group move. RDS refuses to change a DB
# instance's subnet group while Multi-AZ is enabled, and it treats ANY subnet
# group change as a "VPC move" even when the target subnets are in the same VPC:
#
#   InvalidParameterCombination: You cannot move a DB instance with Multi-Az
#   enabled to a VPC
#
# (PR #81 apply, 2026-08-14, RequestID d3b6dcc3-959b-4568-b63e-3113f62218f1.)
#
# AWS's documented remedy is exactly this: convert to single-AZ, move, convert
# back. See "Updating the VPC for a DB instance":
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_VPC.VPC2VPC.html
#
# Acceptable here because this instance is a pre-cutover replica serving no
# traffic — the standby protects nothing yet, and running single-AZ also halves
# its cost in the meantime.
#
# !! RESTORE TO true BEFORE CUTOVER !! Tracked in
# docs/07-Operations/cti-v7-open-items.md section B.
multi_az       = false
engine_version = "5.7.44"

vpc_id = "vpc-04a8720d0ddb40713"

# shared-prod APP subnets (app-a us-east-2a + app-b us-east-2b).
#   app-a subnet-00d31cac6422417c4 = 10.12.1.0/24  (236 free)
#   app-b subnet-093296184eb7e6e64 = 10.12.2.0/24  (250 free)
#
# MOVED here 2026-08-14 from the data subnets. Superseded values, for reference:
#   data-a subnet-092d9baf6d34778e2 = 10.12.0.64/26
#   data-b subnet-0e802f8a78c72c225 = 10.12.0.128/26
#
# WHY THE MOVE (resolves the former "KNOWN ISSUE" block here).
# The data subnets sit inside 10.12.0.0/24. The client confirmed on 2026-08-14
# that this is the Kennedy site's AZURE range — earlier notes called it a camera
# network, which was wrong and came from an unrelated conversation. Because
# Kennedy holds a more-specific local route for that space, its FortiGate would
# never send DB traffic over the VPN, so Kennedy's reporting clients could not
# reach this database. Verified concretely: the instance's ENIs were at
# 10.12.0.110 (data-a) and 10.12.0.148 / 10.12.0.165 (data-b).
#
# Three options existed: (a) Kennedy adds static routes for our two /26s,
# (b) DNAT on their FortiGate, (c) we move. Chose (c) — it needs nothing from the
# client, requires no knowledge of which Azure addresses are actually in use,
# clears the whole /24 rather than two /26s, and is nearly free while this
# instance still serves no traffic. Details: docs/07-Operations/cti-v7-open-items.md
# sections A2 and B1.
#
# WHY THE APP SUBNETS ARE SAFE TARGETS, verified 2026-08-14:
#   * Same AZs as the current placement (2a + 2b), so no AZ change. The instance
#     is Multi-AZ, primary us-east-2a / secondary us-east-2b.
#   * Capacity: 236 and 250 free addresses. RDS needs spare addresses per subnet
#     for failover and maintenance.
#   * Both are RAM-shared to Production, so this account can reference them. Not
#     a given — the orphaned public subnet 10.12.0.32/27 is NOT shared here, which
#     is what actually killed cti-v7 on 2026-08-08.
#   * Egress is unchanged: rt-data-a/b and rt-app-a/b all carry 0.0.0.0/0 -> TGW,
#     so the replication path (TGW -> egress VPC -> NAT -> source RDS) is
#     identical. The app tables merely add S3/DynamoDB gateway endpoints.
#
# RESIDUAL RISK: no site DECLARES 10.12.1.x or 10.12.2.x, but the full four-site
# IP inventory is still outstanding (open item A1) and Kennedy's Azure range was
# itself learned incidentally. If another site turns out to use these ranges, the
# same move applies in reverse — bump db_subnet_group_revision again.
db_subnet_ids = [
  "subnet-00d31cac6422417c4", # app-a, 10.12.1.0/24, us-east-2a
  "subnet-093296184eb7e6e64", # app-b, 10.12.2.0/24, us-east-2b
]

# Bumped 1 -> 2 together with db_subnet_ids above. REQUIRED: changing the subnet
# IDs alone only rewrites the group's membership and leaves db_subnet_group_name
# on the instance untouched, so RDS never re-places the network interfaces and the
# database keeps answering on 10.12.0.x while the apply reports success. The
# revision changes the group NAME, which is what triggers the move. See
# variables.tf.
db_subnet_group_revision = 2

# TEMPORARY for the move — revert to false once the new addresses are confirmed.
# With the default false, RDS records the subnet-group change as a PENDING
# modification and relocates nothing until the maintenance window
# (wed:05:30-wed:06:30) — the second way this change can look applied and not be.
# Safe to force here: this instance serves no traffic pre-cutover, so the
# interruption costs nothing. Re-run mysql.rds_start_replication afterwards.
apply_immediately = true

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
