###############################################################################
# Aheeva DB Slave v8.6 (Production / shared-prod)
#
# Migrated from i-05b16ebe4f90c2c03 in the source tenant (254422596287,
# us-east-1, private 10.0.1.172, EIP 3.228.31.130, m5.2xlarge, CentOS 7.9,
# MariaDB replica of the Aheeva CTI v8.6 box).
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "aheeva-db-slave-v86"
region       = "us-east-2"

name = "aheeva-db-slave-v86"

# Match the source exactly. This is a database replica - undersizing it changes
# replication apply throughput, which is the one thing that must keep up.
instance_type = "m5.2xlarge"

# Registered via the source-tenant block-level dd chain that severed the
# delisted CentOS 7 Marketplace product code:
#   i-05b16ebe4f90c2c03 --create-image--> ami-0710301c8fde3db8a (product-coded)
#   -> snap-0dc9232b680733b3b (200 GiB) + snap-0d623a456d3b6b01b (16 GiB)
#   -> FSR-hydrated volumes -> dd onto blank volumes in the source tenant
#   -> snapshot the blanks (clean, no lineage) -> shared to Production
#   -> copy-snapshot to us-east-2 on the LZA EBS key
#        -> snap-0efe6b4cc20a89cb0 (200) + snap-00116924c493859fe (16)
#   -> register-image --> this AMI.  ProductCodes: null (verified).
# Also carries skip-slave-start in /etc/my.cnf, applied on the copy.
ami_id = "ami-07c696aab9f4b6c43"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4" # shared-prod-app-a (us-east-2a)

# Pinned so MariaDB clients and the replication repoint stay stable across
# replacements. Believed free in app-a: used at time of writing are .16 .50 .51
# .52 .60 .61 .65 .66 .67 .70 .71 .78 .121 .174 .192, and .53 is reserved for
# the Aheeva CTI v8.6 box in its own leaf. RE-VERIFY before apply - see README.
private_ip = "10.12.1.54"

# Source root volume is 200 GiB. Must not be smaller than the AMI's snapshot.
root_volume_size_gib = 200

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

db_port = 3306

# Internal-only to start. Questionnaire item 3.1 - which systems actually query
# this replica - is unanswered, and the source security group shows four
# distinct 3306 clients (Scriptcase, two Webserver-Reportes, webapps php7.3),
# several of which have already migrated into Production. Widen once that is
# settled.
#
# APPEND ONLY. Inserting renumbers the module's index-keyed SG rules into a
# destroy+create, which the CI destroy guard blocks on merge.
db_client_cidrs = ["10.12.0.0/16"]

# No admin SSH rule by default. There is no SSM agent and no EC2 Instance
# Connect on CentOS 7, so access is via the site VPNs or an in-VPC jump host.
admin_ssh_cidrs = []

# key_name intentionally empty - the image carries the Aheeva key. Setting it
# later forces instance replacement. See variables.tf.
key_name = ""

# ebs_kms_key_arn left unset - auto-resolves the LZA EBS key, which is already
# the key both of the AMI's snapshots are encrypted with.
