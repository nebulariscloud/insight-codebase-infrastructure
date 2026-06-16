###############################################################################
# Security Hub control SSM.7
# - SSM documents should have the block public sharing setting enabled.
#
# Why one resource per region instead of for_each over toset(regions):
#   Provider aliases cannot be selected dynamically by for_each / count.
#   The resources must reference their providers statically, so we write three
#   explicit blocks. Adding a region later means adding a fourth block plus a
#   matching configuration_alias in versions.tf. That's the standard Terraform
#   multi-region pattern and it produces the clearest plan output.
###############################################################################

resource "aws_ssm_service_setting" "doc_public_sharing_use1" {
  provider = aws.use1

  setting_id    = "arn:${local.partition}:ssm:${var.regions.use1}:${local.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}

resource "aws_ssm_service_setting" "doc_public_sharing_use2" {
  provider = aws.use2

  setting_id    = "arn:${local.partition}:ssm:${var.regions.use2}:${local.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}

resource "aws_ssm_service_setting" "doc_public_sharing_usw2" {
  provider = aws.usw2

  setting_id    = "arn:${local.partition}:ssm:${var.regions.usw2}:${local.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}
