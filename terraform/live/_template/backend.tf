terraform {
  backend "s3" {
    # CHANGE: replace <sharedservices-account-id> after running _bootstrap
    bucket = "lza-terraform-state-<sharedservices-account-id>"

    # CHANGE: unique per leaf - "live/<account>/<stack-name>/terraform.tfstate"
    key = "live/__account__/__stack__/terraform.tfstate"

    region         = "us-east-2"
    dynamodb_table = "lza-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/lza-terraform-state"
  }
}
