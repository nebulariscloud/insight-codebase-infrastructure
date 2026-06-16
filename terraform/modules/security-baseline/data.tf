###############################################################################
# Data sources used module-wide.
# Both run on the default provider (which the leaf points at the home region).
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
