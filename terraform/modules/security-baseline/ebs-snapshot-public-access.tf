###############################################################################
# Security Hub control EC2.182
# - Block public access settings should be enabled for Amazon EBS snapshots.
#
# Setting state = "block-all-sharing" rejects any new sharing of EBS snapshots
# (public or with specific accounts) at the account-region level. This is the
# strongest of the three options and matches the expected PCI baseline.
###############################################################################

resource "aws_ebs_snapshot_block_public_access" "use1" {
  provider = aws.use1
  state    = "block-all-sharing"
}

resource "aws_ebs_snapshot_block_public_access" "use2" {
  provider = aws.use2
  state    = "block-all-sharing"
}

resource "aws_ebs_snapshot_block_public_access" "usw2" {
  provider = aws.usw2
  state    = "block-all-sharing"
}
