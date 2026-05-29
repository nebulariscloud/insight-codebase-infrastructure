###############################################################################
# Provider chain:
#   1. The "tooling" provider runs in SharedServices (where you logged in).
#   2. We read the spoke's account ID from /accelerator/organization/account-ids.
#   3. The default provider re-assumes TerraformExecution into the spoke.
#
# That keeps account IDs out of code and makes the leaf identical regardless
# of which account it targets - only var.account_name changes.
###############################################################################

provider "aws" {
  alias  = "tooling"
  region = var.region
}

data "aws_ssm_parameter" "spoke_account_id" {
  provider = aws.tooling
  name     = "/accelerator/organization/account-ids/${var.account_name}"
}

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${data.aws_ssm_parameter.spoke_account_id.value}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-${var.stack_name}"
  }

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Account   = var.account_name
      Stack     = var.stack_name
      Repo      = "lza-universal-config-hub-and-spoke"
    }
  }
}
