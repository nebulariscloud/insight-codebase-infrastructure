###############################################################################
# Discovery commands are in example.tfvars. Same VPC / subnet as the existing
# sftp-server and sftp-server-claro leaves (also lift-and-shift, sitting on
# shared-prod-app-a).
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "sftp-server-f9"
region       = "us-east-2"

name          = "sftp-server-f9"
instance_type = "t3.medium"

# Migrated AMI (us-east-2):
#   Source: ami-0207938d1f8eedf49 / snap-0a9a4f2996e6cbd07 (us-east-1,
#           account 254422596287, name "f9-sftp-migration-image", taken from
#           instance i-018f8ea99b6beafab). Source snapshot was UNENCRYPTED
#           and carried no marketplace product code, so it was shared
#           directly - no transfer CMK step.
#   Target: ami-0545c53be16039a74 / snap-01b7371428ef4d68f
#           Re-encrypted with alias/accelerator/ebs/default-encryption/key
#           (arn:aws:kms:us-east-2:395516496764:key/97456cb7-a9ff-4278-a282-566c65984d53)
ami_id = "ami-0545c53be16039a74"

# vpc-04a8720d0ddb40713 = AWSAccelerator-us-east-2-shared-prod
# subnet-00d31cac6422417c4 = AWSAccelerator-us-east-2-shared-prod-app-a (10.12.1.0/24)
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned. Existing tenants in this subnet:
#   10.12.1.50  - sftp-server
#   10.12.1.51  - sftp-server-claro
#   10.12.1.61  - webapps-php73
#   10.12.1.65  - webapps
#   10.12.1.66  - ws-aheeva
#   10.12.1.67  - osticket
#   10.12.1.70  - insight-ubuntu-prod
#   10.12.1.71  - insight-ubuntu-dev
#   10.12.1.121 - wazuh
#   10.12.1.174 - scriptcase-php-73
# .52 continues the SFTP run (.50, .51) and is clear of everything else.
private_ip = "10.12.1.52"

# AMI is root-only (snap-01b7371428ef4d68f at /dev/xvda, 20 GiB, encrypted).
# Confirmed against the source instance i-018f8ea99b6beafab, which had exactly
# one attachment - vol-034113a44fc62ac97 at /dev/xvda. Nothing was excluded
# from the image, so no separate data volume.
data_volume_snapshot_id = ""

# Match the AMI's source root size (20 GiB). Bump higher only if you know
# the migrated server needs more headroom for SFTP files.
root_volume_size_gib = 20

sftp_port        = 22
ingress_vpc_cidr = "10.0.0.0/20"

# EC2 Instance Connect Endpoint SG in shared-prod, reused from the existing
# SFTP server stacks. Opens admin SSH from EICE only - no public exposure,
# no bastion.
eice_security_group_id = "sg-0a990a87e6abca926"

# KMS key that will encrypt f9-recordings-prod-395516496764. The bucket leaf
# creates it SSE-S3 (AES256), but the S3.17 Security Hub auto-remediation
# flips org buckets to SSE-KMS with this org-wide customer-managed key -
# same key already used by the amex-recordings and claro-recordings buckets.
# Granting it up front avoids a later EPERM-at-close surprise from s3fs.
# Confirm after the bucket exists with:
#   aws s3api get-bucket-encryption --bucket f9-recordings-prod-395516496764 --region us-east-2
f9_bucket_kms_key_arn = "arn:aws:kms:us-east-2:395516496764:key/adacb68f-a099-486c-bfce-56bb696ed126"
