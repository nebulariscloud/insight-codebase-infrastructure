###############################################################################
# All resources land in the Perimeter account / us-east-2.
# We assume TerraformExecution from the active SharedServices session.
###############################################################################

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/TerraformExecution"
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
