###############################################################################
# Discovery commands are in example.tfvars. Same VPC / subnet as the existing
# sftp-server leaf (also lift-and-shift, sitting on shared-prod-app-a).
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "sftp-server-claro"
region       = "us-east-2"

name          = "sftp-server-claro"
instance_type = "t3.medium"

# Migrated AMI (us-east-2):
#   Source: ami-08a70ee672a3be576 / snap-0f0ec998581c40ad1 (us-east-1, account 254422596287)
#   Target: ami-02720404eb5b85c63 / snap-04370f749b46cef5c
#           Re-encrypted with alias/accelerator/ebs/default-encryption/key
ami_id = "ami-02720404eb5b85c63"

# vpc-04a8720d0ddb40713 = AWSAccelerator-us-east-2-shared-prod
# subnet-00d31cac6422417c4 = AWSAccelerator-us-east-2-shared-prod-app-a (10.12.1.0/24)
vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned. Existing tenants in this subnet:
#   10.12.1.50  - sftp-server (existing)
#   10.12.1.121 - wazuh
#   10.12.1.174 - scriptcase-php-73
# .51 is the next address after the existing SFTP server, easy to remember,
# clear of every other tenant.
private_ip = "10.12.1.51"

# AMI is root-only (snap-04370f749b46cef5c at /dev/sda1, 20 GiB, encrypted),
# no separate data volume.
data_volume_snapshot_id = ""

root_volume_size_gib = 20

sftp_port        = 22
ingress_vpc_cidr = "10.0.0.0/20"

# EC2 Instance Connect Endpoint SG in shared-prod, reused from the existing
# SFTP server stack. Opens admin SSH from EICE only - no public exposure,
# no bastion.
eice_security_group_id = "sg-0a990a87e6abca926"
