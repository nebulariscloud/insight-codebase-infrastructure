terraform {
  backend "s3" {
    bucket         = "lza-terraform-state-547368325532"
    key            = "live/production/icc-crm-backend/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "lza-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/lza-terraform-state"
  }
}
