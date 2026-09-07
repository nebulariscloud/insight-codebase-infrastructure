# audit / security-hub-suppressions

Manages Security Hub automation rules in the **Audit account**, which is the
Security Hub delegated administrator for the organization. Rules defined here
apply organization-wide.

## Why this leaf exists

Security Hub generates `FAILED` findings for controls that have known,
intentional exceptions (e.g. AWS-managed infrastructure that cannot be
remediated without breaking the service). This leaf creates automation rules
to suppress those findings permanently, replacing ad-hoc manual suppression
with auditable, version-controlled Infrastructure as Code.

## Controls suppressed

| Control | Resource scope | Reason |
|---|---|---|
| `CloudFormation.4` | `AWSAccelerator-*` stacks | LZA service-managed StackSets cannot populate `roleARN` by design. See [AWS documentation](https://docs.aws.amazon.com/securityhub/latest/userguide/cloudformation-controls.html). |
| `CloudFormation.4` | `StackSet-AWSControlTowerBP-*` stacks | Control Tower baseline StackSets cannot populate `roleARN` by design. Modifying these stacks breaks Control Tower governance. |

## How to add new suppressions

1. Add a new `aws_securityhub_automation_rule` resource in `main.tf`.
2. Follow the existing pattern: one rule per `WorkflowStatus` value (`NEW` and
   `NOTIFIED`) so both current and pre-existing findings are covered.
3. Add a row to the table above.
4. Open a PR — the standard GitHub Actions Terraform workflow will plan and
   apply on merge.

## Prerequisites

- The Audit account must have `TerraformExecution` IAM role (deployed by LZA
  bootstrap).
- Security Hub must be enabled and this account must be the delegated admin
  (both configured in `aws-accelerator-config/security-config.yaml`).

## Running locally

```bash
cd terraform/live/audit/security-hub-suppressions

# Copy and edit tfvars
cp example.tfvars terraform.tfvars
# edit terraform.tfvars: set account_id to the Audit account number

terraform init
terraform plan
terraform apply
```
