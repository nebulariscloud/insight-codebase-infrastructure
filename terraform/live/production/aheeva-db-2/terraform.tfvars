###############################################################################
# Aheeva DB 2 — private lift-and-shift from source tenant 254422596287 /
# us-east-1 (i-097ec187250e48e21). Source root 200 GiB gp2, unencrypted.
# Private in shared-prod-app-a.
###############################################################################

account_name = "Production"
account_id   = "395516496764"
stack_name   = "aheeva-db-2"
region       = "us-east-2"

name          = "aheeva-db-2"
instance_type = "m5.2xlarge"

# Clean AMI built via the source-tenant dd-sever (source carried marketplace
# product code cvugziknvmxgqna9noibqnnsy -> OptInRequired on copy-image).
# Registered 2026-09-23 from clean snapshot snap-0952cf2a1636073a8;
# ProductCodes null, verified. See aheeva-cluster-dd-migration-runbook.md.
ami_id = "ami-01378200f8672c0a4"

vpc_id    = "vpc-04a8720d0ddb40713"
subnet_id = "subnet-00d31cac6422417c4"

# Pinned. .80 asterisk-1, .81 db-1, .82 db-2 (contiguous Aheeva cluster block).
private_ip = "10.12.1.82"

root_volume_size_gib = 200

# SG scopes take their variables.tf defaults (voice = VPN ranges, db/admin =
# app subnet). If this box serves no voice, set voice_source_cidrs = [].

# ebs_kms_key_arn left unset — auto-resolves the LZA EBS key.
