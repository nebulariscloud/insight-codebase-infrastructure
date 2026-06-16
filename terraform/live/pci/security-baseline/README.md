# `live/pci/security-baseline` — Wave 1 leaf

Applies the [`security-baseline`](../../../modules/security-baseline) module to the PCI account, closing the following Security Hub findings:

| Control | Severity |
|---|---|
| `SSM.7` | Critical |
| `EC2.182` | High |
| `SSM.6` | Medium |
| `Account.1` | Medium |

Inspector findings (`Inspector.1/2/3/4`) are wired in the module but disabled until decision item **D-1** is resolved.

## One-time prerequisites

Before the first `terraform plan` for this leaf, the SSM SecureString holding the security contact phone must exist in SharedServices:

```bash
aws ssm put-parameter \
  --name /security-baseline/security-contact-phone \
  --type SecureString \
  --value '+1xxxxxxxxxx' \
  --description "Phone for aws_account_alternate_contact (SECURITY) across spokes" \
  --region us-east-2
```

This parameter is shared across every leaf that consumes the module — set it once.

The leaf also reads `/accelerator/organization/account-ids/PCI` from SharedServices SSM. If LZA has not yet published this parameter when you run the first `plan`, set `var.account_id` explicitly in `terraform.tfvars` as a fallback (see the commented line in `example.tfvars`).

## Plan diff (expected)

A clean first `terraform plan` should show approximately:

- 3× `aws_ssm_service_setting` (SSM.7 — public sharing block, one per region)
- 3× `aws_ebs_snapshot_block_public_access` (EC2.182, one per region)
- 3× `aws_kms_key` + 3× `aws_kms_alias` (CMKs for SSM Automation log groups)
- 3× `aws_cloudwatch_log_group` (`/aws/ssm/automation`, one per region)
- 3× `aws_ssm_service_setting` (SSM.6 — automation log group setting, one per region)
- 1× `aws_iam_role` + 1× `aws_iam_role_policy` (SSM Automation logging role, account-wide)
- 1× `aws_account_alternate_contact` (Account.1)
- 0× `aws_inspector2_enabler` (deferred)

Total: ~17 resources to add, 0 to change, 0 to destroy.

## Day-to-day commands

The CI handles the standard cycle. Local commands are only useful for first-time bootstrapping or debugging.

```bash
# From a SharedServices SSO session
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling

cd terraform/live/pci/security-baseline
terraform init
terraform plan -var-file=terraform.tfvars -out tfplan
terraform apply tfplan
```

Idempotency check after apply:

```bash
terraform plan -var-file=terraform.tfvars
# Expected: "No changes."
# (One-shot drift on aws_ssm_service_setting on the very first re-read is acceptable.)
```

## Post-apply verification

See the [module README's Verification section](../../../modules/security-baseline/README.md#verification) for the four AWS CLI commands and the Security Hub re-aggregation procedure.

## Rollback

See the [module README's Rollback section](../../../modules/security-baseline/README.md#rollback). Note that `terraform destroy` does not revert all of the controls automatically — that is intentional, the safer state is to leave the security settings on after the module is removed.

## Wave 2

When the parent strategy moves to Wave 2, copy this directory to `terraform/live/<account>/security-baseline/`, change `account_name`, `account_id_ssm_path`, and the `backend.tf` `key`. The module itself is unchanged.

## Cross-references

- Module: [`terraform/modules/security-baseline/README.md`](../../../modules/security-baseline/README.md)
- Spec: [`.kiro/specs/security-baseline-terraform-module/`](../../../../.kiro/specs/security-baseline-terraform-module/)
- Parent strategy: [`.kiro/specs/security-hub-findings-remediation-strategy/`](../../../../.kiro/specs/security-hub-findings-remediation-strategy/)
