###############################################################################
# Two providers needed:
#
#   1. Default provider runs in us-west-2 because Global Accelerator's control
#      plane only lives in us-west-2. The GA resource itself routes globally.
#
#   2. "alb_region" alias runs in us-east-2 so we can data-source the existing
#      LZA-managed IngressALB (which lives in us-east-2 in the Perimeter
#      account). GA references the ALB by ARN, but we let Terraform discover
#      it dynamically rather than hardcoding the ARN.
#
# Both providers assume the same Perimeter TerraformExecution role; only the
# region differs.
###############################################################################

provider "aws" {
  region = "us-west-2"

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

provider "aws" {
  alias  = "alb_region"
  region = var.alb_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/TerraformExecution"
    session_name = "tf-${var.account_name}-${var.stack_name}-lookup"
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
