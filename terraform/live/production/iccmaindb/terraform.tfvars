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
# Restored to true 2026-08-16. It was set false only to permit a subnet-group
# move that turned out to be impossible — see the block above db_subnet_ids.
# The instance was left single-AZ in AWS by an out-of-band
# `modify-db-instance --no-multi-az`, so this change is what brings it back.
multi_az       = true
engine_version = "5.7.44"

vpc_id = "vpc-04a8720d0ddb40713"

# shared-prod DATA subnets (data-a us-east-2a + data-b us-east-2b).
#   data-a subnet-092d9baf6d34778e2 = 10.12.0.64/26
#   data-b subnet-0e802f8a78c72c225 = 10.12.0.128/26
#
###############################################################################
# 🛑 DO NOT TRY TO MOVE THIS INSTANCE BETWEEN SUBNETS OF THIS VPC. IT CANNOT BE
#    DONE. Two applies were spent proving it on 2026-08-14.
#
# `ModifyDBInstance --db-subnet-group-name` exists ONLY to move an instance
# between VPCs. Within one VPC, RDS refuses outright:
#
#   InvalidVPCNetworkStateFault: You cannot move DB instance iccmaindb to subnet
#   group iccmaindb-subnet-group-2. The specified DB subnet group and DB instance
#   are in the same VPC. Choose a DB subnet group in different VPC than the
#   specified DB instance and try again.
#   (RequestID bad53fa3-6039-4c65-a9c9-1f9909288aa5)
#
# A Multi-AZ rejection is hit FIRST and is a red herring — clearing it only gets
# you to the real wall above:
#
#   InvalidParameterCombination: You cannot move a DB instance with Multi-Az
#   enabled to a VPC
#   (RequestID d3b6dcc3-959b-4568-b63e-3113f62218f1)
#
# Adding NEW LZA subnets outside 10.12.0.0/24 does not help either: still the
# same VPC. And note the plan CANNOT catch any of this — plan-time validation
# never calls ModifyDBInstance, so the plan looks perfect and the apply fails.
###############################################################################
#
# THE PROBLEM THAT PROMPTED THE ATTEMPT, still open.
# These data subnets sit inside 10.12.0.0/24, which the client confirmed on
# 2026-08-14 is the Kennedy site's AZURE range. (Earlier notes called it a camera
# network; that was wrong and came from an unrelated conversation.) Kennedy holds
# a more-specific local route for that space, so its FortiGate would never send
# DB traffic over the VPN and Kennedy's reporting clients cannot reach this
# database. Verified concretely: the ENIs are at 10.12.0.110 (data-a) and
# 10.12.0.148 / 10.12.0.165 (data-b).
#
# THE TWO PATHS THAT REMAIN — tracked as open item B9:
#   (a) Kennedy adds static routes for 10.12.0.64/26 and 10.12.0.128/26 pointing
#       at the VPN tunnel. More specific than their local /24, so they win, and
#       no NAT anywhere. Minutes of work, nothing needed from us. Requires
#       confirming Azure does not occupy 10.12.0.64-10.12.0.191.
#   (b) Rebuild: snapshot this instance and RestoreDBInstanceFromDBSnapshot into
#       a subnet group on the app subnets. Restore DOES accept a subnet group,
#       unlike modify. Then re-establish replication from the captured
#       coordinate. Fully in our control and permanent, but it is a rebuild.
#
# If (b) is chosen, the app subnets are the target and were verified suitable on
# 2026-08-14: app-a subnet-00d31cac6422417c4 = 10.12.1.0/24 us-east-2a (236 free),
# app-b subnet-093296184eb7e6e64 = 10.12.2.0/24 us-east-2b (250 free); same AZs as
# now; both RAM-shared to Production; and rt-app-a/b carry the same
# 0.0.0.0/0 -> TGW egress as rt-data-a/b, so the replication path is unchanged.
db_subnet_ids = [
  "subnet-092d9baf6d34778e2", # data-a, 10.12.0.64/26,  us-east-2a
  "subnet-0e802f8a78c72c225", # data-b, 10.12.0.128/26, us-east-2b
]

# Back to 1 (the original group name, iccmaindb-subnet-group) after the failed
# move. The mechanism itself is sound and worth keeping for a genuine cross-VPC
# move or a rebuild — see variables.tf — it just cannot relocate an existing
# instance inside one VPC.
db_subnet_group_revision = 1

# false is the correct steady state: modifications wait for the maintenance
# window (wed:05:30-wed:06:30) instead of interrupting the database the moment a
# PR merges. Restored 2026-08-16 once Multi-AZ was confirmed back on.
#
# It was true only briefly, to force two changes to execute on apply rather than
# be deferred: the (failed) subnet-group move, and the multi_az restoration.
#
# ⚠️ If you ever need a change to take effect immediately, set this true IN THE
# SAME PR and revert it afterwards. Leaving it false and expecting an instant
# change is a silent no-op — RDS accepts the modification, reports success, and
# applies nothing until Wednesday morning. That trap cost real time on
# 2026-08-14; see the block above db_subnet_ids.
apply_immediately = false

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
