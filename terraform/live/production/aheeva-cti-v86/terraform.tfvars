###############################################################################
# Aheeva CTI v8.6 (Production / shared-prod) — direct-EIP SIP endpoint
#
# Migrated from i-085b1b072af56e661 in the source tenant (254422596287,
# us-east-1, private 10.0.1.92, EIP 3.217.85.105, c5.2xlarge, CentOS 7.9).
# Application server AND MariaDB master for aheeva-db-slave-v86.
#
# ⚠️ NOT APPLYABLE YET. Requires, in order:
#     1. PR #93 merged (module hardcodes associate_public_ip_address = false;
#        allocate_eip = true without the fix is a permanent forced replacement)
#     2. SCP carve-out for Migrated = AheevaCTIV86
#     3. VPC Block Public Access exclusion for subnet-08ce7fb6c30eed107
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "aheeva-cti-v86"
region       = "us-east-2"

name = "aheeva-cti-v86"

# Match the source. This box runs Asterisk plus the Aheeva Java stack; the
# compute-optimised family is the vendor's shape, not ours to second-guess.
instance_type = "c5.2xlarge"

# Registered via the source-tenant block-level dd chain that severed the
# delisted CentOS 7 Marketplace product code:
#   i-085b1b072af56e661 --create-image--> ami-0b01474f719cfea3d (product-coded)
#   -> snap-0b6c6ccc2ca961e6f (185 GiB) + snap-01fb3e7724099667b (8 GiB)
#   -> FSR-hydrated volumes -> dd onto blank volumes in the source tenant
#   -> snapshot the blanks (clean, no lineage) -> shared to Production
#   -> copy-snapshot to us-east-2 on the LZA EBS key
#        -> snap-00f16909990ea560b (185) + snap-0f2b9893c7302a064 (8)
#   -> register-image --> this AMI.  ProductCodes: null (verified).
ami_id = "ami-006fd30030ba73053"

vpc_id = "vpc-04a8720d0ddb40713"

# shared-prod-public-a, 10.12.0.192/27, us-east-2a. Recreated by the LZA
# pipeline 2026-09-10 after the September incident deleted the original.
# Do not use subnet-0dc7b70d38275e775 (deleted) or subnet-0919739a39165a934
# (undeletable orphan, retagged ORPHANED-do-not-use-...).
public_subnet_id = "subnet-08ce7fb6c30eed107"

# First usable address in the /27 (AWS reserves .192-.195 and .223).
# PINNED because the DB replica's CHANGE MASTER TO targets it.
# RE-VERIFY free before apply - the cti-v7 leaf shares this subnet and does not
# pin an address, so it could take this one if it applies first.
private_ip = "10.12.0.196"

# Source root volume is 185 GiB.
root_volume_size_gib = 185

# ---------------------------------------------------------------------------
# SIP / RTP — deliberately closed until the client returns the peer list
# ---------------------------------------------------------------------------

# ⚠️ EMPTY ON PURPOSE. Questionnaire Section 5 (which carriers and partners
# connect inbound, and on which addresses) is unanswered. An empty list means no
# SIP ingress, which is correct for a box not yet in service.
#
# ⚠️ NEVER 0.0.0.0/0 here. UDP 5060 is the most scanned port on the internet and
# SIP brute-force into toll fraud is the standard outcome.
#
# For reference, cti-v7 uses 199.116.62.102/32 and 23.249.138.106/32 — the
# Liberty / WNet VoIP gateways. Whether v8.6 shares those peers is exactly what
# Section 5 needs to answer; do not assume.
sip_peer_cidrs  = []
rtp_extra_cidrs = []

# Matches the migrated box's /etc/asterisk/rtp.conf (rtpstart/rtpend).
# Narrowing this ALSO requires editing rtp.conf in-box, or media breaks on any
# call that lands above the narrowed ceiling.
rtp_from_port = 10000
rtp_to_port   = 20000

# ---------------------------------------------------------------------------
# Admin and database
# ---------------------------------------------------------------------------

# Source SG had 8443 and 9443 (9443 described as "vicc8" plus AmEx HQ).
# Reachable only from the perimeter ingress VPC, never the public internet.
admin_ports        = [8443, 9443]
admin_ingress_cidr = "10.0.0.0/20"

db_port = 3306

# This box is the MASTER. Replication is an INBOUND connection from the replica,
# so 10.12.1.54 (i-034a56060c27f95fb) must be allowed or replication cannot be
# established. Other 3306 clients pending questionnaire Section 4.
# APPEND ONLY - this list is last in the rule order so appending is free.
db_client_cidrs = ["10.12.1.54/32"]

# key_name intentionally empty - the image carries the Aheeva key, unlike
# cti-v7 where nobody held the source key. Setting it later forces replacement.
key_name = ""

# ebs_kms_key_arn left unset - auto-resolves the LZA EBS key, already the key
# both of the AMI's snapshots are encrypted with.
