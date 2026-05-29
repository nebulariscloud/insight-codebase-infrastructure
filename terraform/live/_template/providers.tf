###############################################################################
# Provider chain:
#   1. The "tooling" provider runs in SharedServices (where you logged in or
#      where GitHub Actions assumed the GitHubActions-Terraform role).
#   2. We resolve the spoke's account ID. Two ways:
#        - Set var.account_id explicitly (most reliable, works regardless of
#          what LZA has published).
#        - Or leave var.account_id empty and var.account_id_ssm_path set, and
#          we read it from SSM in SharedServices.
#   3. The default provider re-assumes TerraformExecution into the spoke.
###############################################################################

provider "aws" {
  alias  = "tooling"
  region = var.region
}

# Optional SSM lookup: only runs when var.account_id is empty.
data "aws_ssm_parameter" "spoke_account_id" {
  count    = var.account_id == "" ? 1 : 0
  provider = aws.tooling
  name     = var.account_id_ssm_path
}

locals {
  spoke_account_id = var.account_id != "" ? var.account_id : data.aws_ssm_parameter.spoke_account_id[0].value
}

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-${var.stack_name}"
  }

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Account   = var.account_name
      Stack     = var.stack_name
      Repo      = "insight-codebase-infrastructure"
    }
  }
}
