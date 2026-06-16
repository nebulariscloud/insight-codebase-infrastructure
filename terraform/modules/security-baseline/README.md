# `security-baseline` module

Per-account Terraform module that applies AWS security service settings AWS Config does not model and Landing Zone Accelerator does not expose declaratively. Built to be reusable across every non-Management spoke account in the org.

Implementation of the `Terraform` mechanism rows in [`security-hub-findings-remediation-strategy`](../../../.kiro/specs/security-hub-findings-remediation-strategy/design.md). Closes the following Security Hub controls:

| Control | Title | Severity |
|---|---|---|
| `SSM.7` | SSM documents should have block public sharing enabled | Critical |
| `EC2.182` | Block public access settings should be enabled for EBS snapshots | High |
| `SSM.6` | SSM Automation should have CloudWatch logging enabled | Medium |
| `Account.1` | Security contact information should be provided | Medium |
| `Inspector.1/2/3/4` | Inspector v2 EC2 / ECR / Lambda code / Lambda standard | High (deferred via feature flag, off by default) |

Findings explicitly **not** addressed here:

- `S3.22` and `S3.23` (CloudTrail S3 data events). The trail lives in the Management account, which Terraform's credential model excludes. Resolved via [`cloudtrail-data-events-runbook.md`](../../../cloudtrail-data-events-runbook.md) (manual procedure).

## Prerequisites

The `security_contact_phone` value comes from an SSM SecureString in **SharedServices**, not from variables or `tfvars`. Create it once before the first apply:

```bash
aws ssm put-parameter \
  --name /security-baseline/security-contact-phone \
  --type SecureString \
  --value '+1xxxxxxxxxx' \
  --description "Phone for aws_account_alternate_contact (SECURITY) across spokes" \
  --region us-east-2
```

The same parameter is reused by every leaf that consumes this module — single source of truth across the org. To rotate, `--overwrite` and re-`apply` each leaf.

## Usage

This is a multi-region module: it requires three regional provider aliases (`aws.use1`, `aws.use2`, `aws.usw2`) plus a default provider for account-level resources.

```hcl
module "security_baseline" {
  source = "../../../modules/security-baseline"

  providers = {
    aws      = aws        # default — home region (us-east-2)
    aws.use1 = aws.use1
    aws.use2 = aws.use2
    aws.usw2 = aws.usw2
  }

  account_name           = "PCI"
  security_contact_name  = "Alex Gonzalez"
  security_contact_email = "security@nebulariscloud.com"
  security_contact_phone = data.aws_ssm_parameter.security_contact_phone.value
  security_contact_title = "CEO"

  # Inspector deferred until decision item D-1 lands.
  inspector_enabled = false
}
```

See [`terraform/live/pci/security-baseline/`](../../live/pci/security-baseline) for the canonical leaf wiring.

## Inputs

| Variable | Type | Default | Notes |
|---|---|---|---|
| `account_name` | string | (required) | Free-form account label, used in tags. |
| `regions` | object | `{use1="us-east-1", use2="us-east-2", usw2="us-west-2"}` | Map of provider alias to region name. Keys must match `configuration_aliases` in `versions.tf`. |
| `security_contact_name` | string | (required) | SECURITY alternate contact name. |
| `security_contact_email` | string | (required) | SECURITY alternate contact email. |
| `security_contact_phone` | string (sensitive) | (required) | SECURITY alternate contact phone. Sourced from SSM in the leaf, never literal. |
| `security_contact_title` | string | (required) | SECURITY alternate contact title. |
| `automation_log_retention_days` | number | `365` | Retention for `/aws/ssm/automation` log groups. |
| `automation_log_kms_deletion_window` | number | `30` | Pending-deletion window for the SSM Automation CMKs. |
| `inspector_enabled` | bool | `false` | Master toggle for Inspector v2. |
| `inspector_resource_types` | list(string) | `[]` | Subset of `EC2`, `ECR`, `LAMBDA`, `LAMBDA_CODE`. Required when `inspector_enabled = true`. |
| `inspector_regions` | list(string) | `[]` | Region names where Inspector v2 should be enabled. Required when `inspector_enabled = true`. |
| `tags` | map(string) | `{}` | Extra tags merged with module defaults. |

## Outputs

| Output | Type | Notes |
|---|---|---|
| `automation_log_group_name` | string | `/aws/ssm/automation` |
| `automation_role_arn` | string | IAM role assumed by SSM Automation to write logs. |
| `automation_kms_key_arns` | map(string) | Region alias → CMK ARN for the log group encryption. |

No contact fields are exposed as outputs; they are PII and stay in state only.

## Verification

After `terraform apply`, confirm each control:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# SSM.7 — public sharing disabled, all 3 regions
for r in us-east-1 us-east-2 us-west-2; do
  aws ssm get-service-setting \
    --setting-id "arn:aws:ssm:$r:$ACCOUNT:servicesetting/ssm/documents/console/public-sharing-permission" \
    --region "$r" --query 'ServiceSetting.SettingValue' --output text
done
# Expected: Disable, Disable, Disable

# EC2.182 — EBS snapshot block public access
for r in us-east-1 us-east-2 us-west-2; do
  aws ec2 get-snapshot-block-public-access-state --region "$r" --query State --output text
done
# Expected: block-all-sharing, block-all-sharing, block-all-sharing

# SSM.6 — automation log group setting
for r in us-east-1 us-east-2 us-west-2; do
  aws ssm get-service-setting \
    --setting-id "arn:aws:ssm:$r:$ACCOUNT:servicesetting/ssm/automation/cloudwatch-log-group" \
    --region "$r" --query 'ServiceSetting.SettingValue' --output text
done
# Expected: /aws/ssm/automation, /aws/ssm/automation, /aws/ssm/automation

# Account.1 — security contact set
aws account get-alternate-contact --alternate-contact-type SECURITY \
  --query '{Name:Name, Email:EmailAddress, Title:Title}'
# Expected: configured name, email, and title (phone redacted on purpose)
```

### Security Hub re-aggregation

After ~1–2 hours (one Security Hub aggregation cycle), confirm in the delegated admin (Audit) account:

1. Open **Security Hub** in `us-east-2` (the aggregator region).
2. Filter **Findings** by `AwsAccountId` = the spoke account.
3. Filter by Control IDs `SSM.7`, `EC2.182`, `SSM.6`, `Account.1`.
4. Each should be in `PASSED` state.

Export the filtered findings as CSV and store alongside the Terraform plan/apply outputs as compliance evidence.

## Rollback

The four controls have different reversion semantics. Removing the module via `terraform destroy` does **not** automatically revert all of them — by design.

| Control | Reverted by `terraform destroy`? | Notes |
|---|---|---|
| `SSM.7` | No (`aws_ssm_service_setting` keeps the last-set value) | The setting stays at `Disable` after destroy. This is the safer state. To re-enable manually: `aws ssm reset-service-setting --setting-id <arn>`. |
| `EC2.182` | No | Same shape as `SSM.7`. State stays at `block-all-sharing`. To revert: `aws ec2 disable-snapshot-block-public-access --region <r>`. |
| `SSM.6` | Partially | The service setting persists; the log group, CMK, and IAM role are removed. Automation runs after destroy will fail to write logs until the log group is recreated or the service setting is reset. |
| `Account.1` | No | The alternate contact persists. Remove via `aws account delete-alternate-contact --alternate-contact-type SECURITY`. |

To do a clean rollback, run `terraform destroy`, then explicitly reset the service settings and the alternate contact with the AWS CLI commands above.

## Adding a new account

1. Copy `terraform/live/pci/security-baseline/` to `terraform/live/<new-account>/security-baseline/`.
2. In `backend.tf`, change `key = "live/<new-account>/security-baseline/terraform.tfstate"`.
3. In `variables.tf`, change `account_name` default to the new account's name.
4. In `providers.tf`, change the SSM lookup path to `/accelerator/organization/account-ids/<new-account>`.
5. `git add -f terraform/live/<new-account>/security-baseline/terraform.tfvars` (the project's `.gitignore` excludes `*.tfvars`; existing leaves are committed with `git add -f` to make CI deterministic).
6. Open a PR. CI runs `terraform plan` automatically. Review the diff, merge, and CI applies.

The same SSM SecureString from SharedServices is reused — no per-account setup beyond the steps above.

## Adding a new region

1. In this module's `versions.tf`, add the new alias to `configuration_aliases`, e.g. `aws.euw1`.
2. Replicate the regional resources in:
   - `ssm-document-public-sharing.tf`
   - `ebs-snapshot-public-access.tf`
   - `ssm-automation-logging.tf` (KMS key + alias + log group + service setting + KMS policy data source)
   - `inspector.tf`
   - `outputs.tf` (extend the `automation_kms_key_arns` map)
   - `locals.tf` (extend the `automation_log_group_arns` map and the IAM permissions policy data source uses these)
3. Extend `var.regions` to include the new alias.
4. Each consuming leaf adds the new provider in its `providers.tf` and passes it into the module call.

The shape is verbose by design. Each region resource is statically wired to its provider alias, which keeps `terraform plan` output unambiguous.

## Cross-references

- Parent strategy: [`.kiro/specs/security-hub-findings-remediation-strategy/`](../../../.kiro/specs/security-hub-findings-remediation-strategy/)
- This module's spec: [`.kiro/specs/security-baseline-terraform-module/`](../../../.kiro/specs/security-baseline-terraform-module/)
- D-9 manual runbook (out of scope here): [`cloudtrail-data-events-runbook.md`](../../../cloudtrail-data-events-runbook.md)
- Wave 1 leaf: [`terraform/live/pci/security-baseline/`](../../live/pci/security-baseline)
