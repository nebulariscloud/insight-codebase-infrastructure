###############################################################################
# Discovery commands are in example.tfvars. Fill in vpc_id and subnet_id
# from the Production account.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "sftp-server"
region       = "us-east-2"

name          = "sftp-server"
instance_type = "t3.medium"
ami_id        = "ami-0142292b2f75b5156"

# Same VPC and subnet Scriptcase used:
#   vpc-04a8720d0ddb40713 = AWSAccelerator-us-east-2-shared-prod
#   subnet-00d31cac6422417c4 = AWSAccelerator-us-east-2-shared-prod-app-a (10.12.1.0/24)
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned. Existing tenants in this subnet:
#   10.12.1.121 - wazuh
#   10.12.1.174 - scriptcase-php-73
# .50 is well clear of both, easy to remember, and keeps room above and
# below for future services.
private_ip = "10.12.1.50"

# Confirmed via `aws ec2 describe-images` that snap-0226e25f48a663eed is
# the AMI's root volume snapshot at /dev/sda1 (20 GiB gp3, encrypted),
# already baked into ami-0142292b2f75b5156. So no separate data volume.
data_volume_snapshot_id = ""

# Match the AMI's source root size (20 GiB). Bump higher only if you know
# the migrated server needs more headroom for SFTP files.
root_volume_size_gib = 20

sftp_port        = 22
ingress_vpc_cidr = "10.0.0.0/20"

# EC2 Instance Connect Endpoint SG in shared-prod. Opens admin SSH from
# EICE only - no public exposure, no bastion. Get this from:
#   aws ec2 describe-instance-connect-endpoints --region us-east-2 \
#     --filters Name=vpc-id,Values=vpc-04a8720d0ddb40713 \
#     --query 'InstanceConnectEndpoints[].SecurityGroupIds'
eice_security_group_id = "sg-0a990a87e6abca926"

# KMS key encrypting amex-recordings-prod-395516496764. The bucket uses
# SSE-KMS, so the SFTP instance role needs kms:GenerateDataKey/Decrypt on
# this key or every PutObject server-side gets denied and s3fs returns
# EPERM. Confirm with:
#   aws s3api get-bucket-encryption --bucket amex-recordings-prod-395516496764 --region us-east-2
#
# Was adacb68f-a099-486c-bfce-56bb696ed126, which is not the key this bucket
# uses. A PutObject from the instance was denied on
# key/d6fdb2e8-3be3-4e00-8c6d-96abe2b8aa8a, so the grant sat on a key S3
# never calls here. Same defect as the claro leaf (PR #98) - the ARN was
# copied between leaves on the belief that adacb68f was the org-wide S3
# default CMK. Both buckets in fact resolve to d6fdb2e8, which is consistent
# with the S3.17 remediation document reading one key per region from SSM.
#
# Read the authoritative value rather than copying it from a sibling leaf
# (see aws-accelerator-config/ssm-documents/enable-s3-bucket-kms-encryption.yaml):
#   aws ssm get-parameter --name /accelerator/kms/AcceleratorS3DefaultKey/key-arn \
#     --region us-east-2 --query Parameter.Value --output text
amex_bucket_kms_key_arn = "arn:aws:kms:us-east-2:395516496764:key/d6fdb2e8-3be3-4e00-8c6d-96abe2b8aa8a"
