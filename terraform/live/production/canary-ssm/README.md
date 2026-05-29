# Canary leaf — Production / canary-ssm

Single SSM parameter in the Production spoke. Sole purpose: prove the
end-to-end Terraform pipeline reaches Production through OIDC →
GitHubActions-Terraform (SharedServices) → TerraformExecution (Production).

## What it creates

- `/canary/terraform-pipeline` (String, value `ok`) in account 395516496764.

## Why account ID is in tfvars instead of an SSM lookup

LZA in this install does not (yet) publish
`/accelerator/organization/account-ids/<Name>` in SharedServices. Until that's
enabled, leaves pass `account_id` directly. Once LZA publishes the parameters,
`providers.tf` in `terraform/live/_template/` already supports falling back to
SSM when `account_id` is empty.

## How to retire

After the pipeline run is verified green:

1. Delete this directory in a follow-up PR.
2. Merge — apply will destroy the parameter.
