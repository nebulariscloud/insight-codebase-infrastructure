# Implementation Plan

## Overview

This is the execution plan for `security-baseline-terraform-module`. Tasks are sized so each can be completed and reviewed independently. Every task that produces code references the requirement(s) it satisfies and the design section it implements.

The plan delivers a fully working Wave 1 leaf for the PCI account. Wave 2 (other spokes) is a parent-strategy concern and is **not** part of this implementation plan; the module is built so Wave 2 needs only new leaves, not module changes.

## Tasks

### Pre-work (manual, one-time, before any code)

- [x] 1. Create the SSM SecureString parameter for the security contact phone in SharedServices
  - Run from a SharedServices SSO session with permission to write SSM parameters:
    ```
    aws ssm put-parameter \
      --name /security-baseline/security-contact-phone \
      --type SecureString \
      --value '+17875863211' \
      --description "Phone for aws_account_alternate_contact (SECURITY) across spokes" \
      --region us-east-2
    ```
  - Verify with `aws ssm get-parameter --name /security-baseline/security-contact-phone --with-decryption --region us-east-2 --query 'Parameter.Value'`.
  - This unblocks the Wave 1 leaf. Required before task 18.
  - _Requirements: 6.4, 6.5_

### Module scaffolding

- [x] 2. Create the module directory and base files
  - Create `terraform/modules/security-baseline/` with empty files: `versions.tf`, `variables.tf`, `outputs.tf`, `locals.tf`, `data.tf`, `README.md`.
  - Add a `.gitignore` entry under the module if needed (mirror existing modules).
  - _Requirements: 1.1, 1.2_

- [x] 3. Author `versions.tf` with `configuration_aliases`
  - Pin `required_version >= 1.6` and `aws ~> 5.60` (matching `terraform/modules/alb/versions.tf`).
  - Declare `configuration_aliases = [aws.use1, aws.use2, aws.usw2]` so consumers must pass three regional providers.
  - _Requirements: 1.3, 2.1, 2.2_
  - _Design: Components 1, file-layout section_

- [x] 4. Author `variables.tf` with all module inputs
  - Declare every variable from the design's Component 2 table: `account_name`, `regions` (object), `security_contact_*` (with `security_contact_phone` marked `sensitive = true`), `automation_log_retention_days` (default 365), `automation_log_kms_deletion_window` (default 30), `inspector_enabled` (default false), `inspector_resource_types` (default `[]`), `inspector_regions` (default `[]`), `tags` (default `{}`).
  - Add `validation` blocks for: `inspector_resource_types` only contains `EC2`/`ECR`/`LAMBDA`/`LAMBDA_CODE`; when `inspector_enabled` is true, both `inspector_resource_types` and `inspector_regions` must be non-empty.
  - _Requirements: 1.4, 5.6, 6.3, 6.6, 7.1, 7.2, 7.3, 7.6_
  - _Design: Component 2_

- [x] 5. Author `data.tf` and `locals.tf`
  - `data "aws_caller_identity" "current"` and `data "aws_partition" "current"` on the default provider.
  - `locals` block with `account_id`, `partition`, `default_tags` (merged with `var.tags`), `automation_log_group_name = "/aws/ssm/automation"`, `automation_role_name = "AcceleratorBaseline-SSMAutomationLogging"`.
  - _Requirements: 1.4_
  - _Design: Components 3, 4_

### Per-control resources

- [x] 6. Implement `ssm-document-public-sharing.tf` (SSM.7)
  - Three `aws_ssm_service_setting` resources, one per region alias (`aws.use1`, `aws.use2`, `aws.usw2`), with `setting_id = "arn:${local.partition}:ssm:${var.regions.<alias>}:${local.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"` and `setting_value = "Disable"`.
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_
  - _Design: Component 5_

- [x] 7. Implement `ebs-snapshot-public-access.tf` (EC2.182)
  - Three `aws_ebs_snapshot_block_public_access` resources, one per region alias, all with `state = "block-all-sharing"`.
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_
  - _Design: Component 6_

- [x] 8. Implement `ssm-automation-logging.tf` (SSM.6)
  - One `aws_iam_role` (default provider, IAM is global) named `AcceleratorBaseline-SSMAutomationLogging`, trust policy for `ssm.amazonaws.com`.
  - One `aws_iam_role_policy` granting only `logs:CreateLogStream` and `logs:PutLogEvents` on the three regional log group ARNs (no wildcards).
  - Per region (`use1`, `use2`, `usw2`): one `aws_kms_key` with rotation enabled, one `aws_kms_alias`, one `aws_cloudwatch_log_group` with `kms_key_id = aws_kms_key.<region>.arn` and retention from `var.automation_log_retention_days`, one `aws_ssm_service_setting` for the automation log group setting with `depends_on = [aws_cloudwatch_log_group.<region>]`.
  - Each KMS key policy grants: account root admin, `logs.<region>.amazonaws.com` encrypt/decrypt scoped via `kms:EncryptionContext:aws:logs:arn`, and the SSM Automation role decrypt + generate-data-key.
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 13.3_
  - _Design: Component 7_

- [x] 9. Implement `account-contacts.tf` (Account.1)
  - One `aws_account_alternate_contact` on the default provider with `alternate_contact_type = "SECURITY"` and the four `var.security_contact_*` values.
  - _Requirements: 6.1, 6.2, 6.7, 6.8, 6.9_
  - _Design: Component 8_

- [x] 10. Implement `inspector.tf` (feature flagged, off by default)
  - Compute `local.inspector_active = var.inspector_enabled && length(var.inspector_resource_types) > 0 && length(var.inspector_regions) > 0`.
  - Three `aws_inspector2_enabler` resources (one per region alias), each gated by `count = local.inspector_active && contains(var.inspector_regions, var.regions.<alias>) ? 1 : 0`, `account_ids = [local.account_id]`, `resource_types = var.inspector_resource_types`.
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6_
  - _Design: Component 9_

- [x] 11. Author `outputs.tf`
  - `automation_log_group_name`, `automation_role_arn`, `automation_kms_key_arns` (map keyed by region alias).
  - Do **not** output any contact field.
  - _Requirements: 1.5, 6.8, 13.1_
  - _Design: Component 10_

### Module documentation

- [x] 12. Write the module `README.md`
  - Sections required by Requirement 11.1: Purpose (linking the parent strategy), Inputs table, Outputs table, Usage example, Verification (the four AWS CLI commands plus Security Hub re-aggregation procedure), Rollback (per-control), Adding a new account (5-step), Adding a new region (2-step).
  - Document the SSM parameter prerequisite (`/security-baseline/security-contact-phone`) and the `put-parameter` setup command.
  - _Requirements: 1.2, 9.2, 11.1, 11.2, 11.3, 12.3_

### Wave 1 leaf for PCI

- [x] 13. Create `terraform/live/pci/security-baseline/` directory
  - Files: `backend.tf`, `versions.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `README.md`.
  - _Requirements: 8.1, 8.2_

- [x] 14. Author the leaf's `backend.tf`
  - S3 backend, `bucket = "lza-terraform-state-547368325532"`, `key = "live/pci/security-baseline/terraform.tfstate"`, `region = "us-east-2"`, `dynamodb_table = "lza-terraform-locks"`, `encrypt = true`, `kms_key_id = "alias/lza-terraform-state"`.
  - _Requirements: 8.3_
  - _Design: Component 11_

- [x] 15. Author the leaf's `versions.tf`
  - Identical pinning to module versions: `required_version >= 1.6`, `aws ~> 5.60`. No `configuration_aliases` (only modules need that).
  - _Requirements: 1.3_

- [x] 16. Author the leaf's `providers.tf`
  - `aws.tooling` provider in SharedServices for SSM reads (no assume role).
  - `data "aws_ssm_parameter" "spoke_account_id"` reading `/accelerator/organization/account-ids/PCI` via `aws.tooling`.
  - `data "aws_ssm_parameter" "security_contact_phone"` reading `/security-baseline/security-contact-phone` via `aws.tooling` with `with_decryption = true`.
  - Local `spoke_account_id` derived from the parameter value, with fallback support for `var.account_id` if explicitly provided (mirror the template).
  - Three regional providers `aws.use1` / `aws.use2` / `aws.usw2`, each assuming `arn:aws:iam::${local.spoke_account_id}:role/TerraformExecution`, with the same `default_tags` shape.
  - One unaliased default provider for account-level resources, also assuming TerraformExecution, region `us-east-2`.
  - _Requirements: 8.4, 13.4_
  - _Design: Component 11_

- [x] 17. Author the leaf's `variables.tf`
  - `account_name` (default `"PCI"`), `account_id` (default `""`, validation for 12-digit numeric or empty), `account_id_ssm_path` (default `/accelerator/organization/account-ids/PCI`), `security_contact_name` (default `"Alex Gonzalez"`), `security_contact_email` (default `"security@nebulariscloud.com"`), `security_contact_title` (default `"CEO"`).
  - **Do not** declare `security_contact_phone` as a variable. It comes from SSM in `providers.tf`.
  - _Requirements: 6.4, 6.6, 8.6, 13.2_

- [x] 18. Author the leaf's `main.tf`
  - Single `module "security_baseline"` block, `source = "../../../modules/security-baseline"`.
  - `providers = { aws = aws, aws.use1 = aws.use1, aws.use2 = aws.use2, aws.usw2 = aws.usw2 }`.
  - Pass `account_name`, `security_contact_name`, `security_contact_email`, `security_contact_title` from variables.
  - Pass `security_contact_phone = data.aws_ssm_parameter.security_contact_phone.value`.
  - Set `inspector_enabled = false` explicitly (deferred to D-1).
  - _Requirements: 8.5, 8.6, 8.7_
  - _Design: Component 11_

- [x] 19. Author the leaf's `outputs.tf`
  - Re-export `automation_log_group_name`, `automation_role_arn`, `automation_kms_key_arns` from the module.
  - No contact fields.
  - _Requirements: 6.8, 13.1_

- [x] 20. Write the leaf's `README.md`
  - Document: prerequisite SSM parameter (link to task 1), expected plan diff, apply procedure, post-apply verification, rollback, evidence-capture pointer.
  - _Requirements: 11.1, 12.1, 12.3_

### Validation and verification

- [x] 21. Run `terraform fmt -check -recursive` against module and leaf
  - Fix any formatting drift before commit.
  - _Requirements: 1.9_

- [x] 22. Run `terraform init -backend=false && terraform validate` from the leaf
  - Catches missing variables, type mismatches, validation rule errors before AWS calls.
  - _Requirements: 1.10_

- [ ] 23. Run `terraform init && terraform plan` from the leaf in a SharedServices SSO session
  - Inspect the plan diff; expect:
    - 3× `aws_ssm_service_setting` (SSM.7)
    - 3× `aws_ebs_snapshot_block_public_access`
    - 1× `aws_iam_role`, 1× `aws_iam_role_policy`
    - 3× `aws_kms_key`, 3× `aws_kms_alias`, 3× `aws_cloudwatch_log_group`, 3× `aws_ssm_service_setting` (SSM.6)
    - 1× `aws_account_alternate_contact`
    - 0× `aws_inspector2_enabler` (Inspector still disabled)
  - Save plan to `tfplan` for apply.
  - _Requirements: 11.1, 11.2_
  - _Design: Testing Strategy — Plan dry-run_

- [ ] 24. Apply the plan and run post-apply verification
  - `terraform apply tfplan`.
  - Run all four AWS CLI verification commands across the three regions:
    - `ssm get-service-setting` for `documents/console/public-sharing-permission` → `Disable`
    - `ec2 get-snapshot-block-public-access-state` → `block-all-sharing`
    - `ssm get-service-setting` for `automation/cloudwatch-log-group` → `/aws/ssm/automation`
    - `account get-alternate-contact --alternate-contact-type SECURITY` → expected name/email/title
  - _Requirements: 11.1_
  - _Design: Testing Strategy — Post-apply verification_

- [ ] 25. Confirm idempotency
  - Re-run `terraform plan`. Expected: `No changes.` (One-shot drift on `aws_ssm_service_setting` is acceptable on the first re-read; if it persists past two runs, file as a bug.)
  - _Requirements: 3.4, 4.5, 5.5, 6.9_
  - _Design: Testing Strategy — Idempotency check_

- [ ] 26. Capture compliance evidence
  - `terraform plan` and `terraform apply` outputs.
  - Stdout from the AWS CLI verification commands in task 24.
  - Security Hub finding export (after one aggregation cycle, ~1–2 hours): filter by control IDs `SSM.7`, `EC2.182`, `SSM.6`, `Account.1` and AwsAccountId = PCI; expect all `PASSED`.
  - Store in the evidence location agreed with security; reference the path in the parent strategy spec.
  - _Requirements: 11.2, 12.1, 12.2_
  - _Design: Testing Strategy — Security Hub re-aggregation_

### Strategy bookkeeping

- [x] 27. Update the parent strategy disposition table
  - In `.kiro/specs/security-hub-findings-remediation-strategy/design.md`, mark rows for `SSM.7`, `EC2.182`, `SSM.6`, `Account.1` as **Wave 1 complete** with the date and the evidence path.
  - _Requirements: 12.2_

- [x] 28. Spawn follow-up specs called out in Requirement 10
  - Create empty spec scaffolds (or just titles in the parent strategy's "Implementation specs to spawn" section) for the next pieces — `lza-config-rules-and-ssm-remediations`, `lza-vpc-endpoints-pci-coverage`, `lza-iam-and-account-baseline` — so the queue is visible.
  - This task does not block Wave 1 completion; it sets up the next iteration.
  - _Requirements: 10.2_

## Task Dependency Graph

```json
{
  "waves": [
    {
      "wave": 1,
      "name": "Manual prerequisite",
      "tasks": [1],
      "depends_on": [],
      "parallel": false
    },
    {
      "wave": 2,
      "name": "Module scaffolding",
      "tasks": [2],
      "depends_on": [],
      "parallel": false
    },
    {
      "wave": 3,
      "name": "Module foundation files",
      "tasks": [3, 4, 5],
      "depends_on": [2],
      "parallel": true
    },
    {
      "wave": 4,
      "name": "Per-control resources and module outputs",
      "tasks": [6, 7, 8, 9, 10, 11],
      "depends_on": [3, 4, 5],
      "parallel": true
    },
    {
      "wave": 5,
      "name": "Module documentation",
      "tasks": [12],
      "depends_on": [6, 7, 8, 9, 10, 11],
      "parallel": false
    },
    {
      "wave": 6,
      "name": "Wave 1 leaf scaffolding",
      "tasks": [13],
      "depends_on": [12],
      "parallel": false
    },
    {
      "wave": 7,
      "name": "Wave 1 leaf foundation files",
      "tasks": [14, 15, 17],
      "depends_on": [13],
      "parallel": true
    },
    {
      "wave": 8,
      "name": "Wave 1 leaf providers (needs SSM parameter)",
      "tasks": [16],
      "depends_on": [1, 13],
      "parallel": false
    },
    {
      "wave": 9,
      "name": "Wave 1 leaf composition",
      "tasks": [18, 19, 20],
      "depends_on": [11, 14, 15, 16, 17],
      "parallel": false
    },
    {
      "wave": 10,
      "name": "Static validation",
      "tasks": [21, 22],
      "depends_on": [18, 19, 20],
      "parallel": false
    },
    {
      "wave": 11,
      "name": "Plan, apply, verify",
      "tasks": [23, 24, 25, 26],
      "depends_on": [21, 22],
      "parallel": false
    },
    {
      "wave": 12,
      "name": "Strategy bookkeeping and follow-on specs",
      "tasks": [27, 28],
      "depends_on": [26],
      "parallel": true
    }
  ]
}
```

Visual reference (for humans):

```
1 (SSM phone parameter)
        │
        └─────────────────────────────────┐
                                          │
2 (module dirs) ───► 3 (versions.tf)      │
                ───► 4 (variables.tf)     │
                ───► 5 (data + locals)    │
                          │               │
                          ├──► 6 (SSM.7)  │
                          ├──► 7 (EC2.182)│
                          ├──► 8 (SSM.6)  │
                          ├──► 9 (Account.1)
                          ├──►10 (Inspector flag, off)
                          └──►11 (outputs)
                                  │
                                 12 (module README)
                                  │
                                 13 (leaf dir) ───►14 (backend)
                                                ───►15 (versions)
                                                ───►16 (providers)  ◄──── needs 1
                                                ───►17 (variables)
                                                          │
                                                         18 (main.tf)  ◄──── needs 11, 16
                                                          │
                                                         19 (outputs)
                                                          │
                                                         20 (leaf README)
                                                          │
                                                         21 (fmt) ──► 22 (validate) ──► 23 (plan)
                                                                                             │
                                                                                            24 (apply + verify)
                                                                                             │
                                                                                            25 (idempotency)
                                                                                             │
                                                                                            26 (evidence)
                                                                                             │
                                                                                            27 (strategy update)
                                                                                             │
                                                                                            28 (spawn next specs)
```

Critical path: 1 → 2 → 3,4,5 (parallel) → 6,7,8,9,10,11 (parallel) → 12 → 13–20 (mostly sequential within the leaf) → 21 → 22 → 23 → 24 → 25 → 26 → 27 → 28.

Tasks 6, 7, 8, 9, 10, 11 are independent of each other and can be done in parallel by different contributors.

Task 1 is the only manual prerequisite. All other tasks are code or terminal commands.

## Notes

### How this maps to your existing CI

- PRs touching `terraform/modules/security-baseline/` or `terraform/live/pci/security-baseline/` automatically trigger your existing `.github/workflows/terraform.yml`. The pipeline assumes `GitHubActions-Terraform` in SharedServices, which is the same chain used for `aws.tooling`.
- Task 23 (`terraform plan`) is what CI runs on PR. The diff posted to the PR is your reviewer signal.
- Task 24 (`terraform apply`) is what CI runs on merge to `main`, gated by your GitHub environment approval.
- Task 1 (the SSM SecureString) is the only step that **must** happen outside of code and CI. Run it once manually before opening the PR. Without it, task 23 will fail at plan time with a "parameter not found" error.

### What "Wave 2" means in practice (out of scope for this spec)

When the parent strategy moves to Wave 2, a new spec spawns one or more leaves at:

```
terraform/live/production/security-baseline/
terraform/live/development/security-baseline/
terraform/live/sharedservices/security-baseline/
terraform/live/network/security-baseline/
terraform/live/perimeter/security-baseline/
```

Each leaf is a copy of the PCI leaf with `account_name`, the SSM path for the spoke ID, and the `backend.tf` `key` updated. The same SSM SecureString parameter from task 1 is reused — it's a single source of truth across the org.

### What happens if `/accelerator/organization/account-ids/PCI` does not exist yet

Task 16 documents the fallback. If LZA hasn't published the SSM parameter for the PCI account ID, set `var.account_id` explicitly in the leaf and remove the SSM lookup. The module behavior is unchanged.

This is mostly a defensive note — the LZA accounts-config has the PCI account, and LZA typically publishes account-id parameters. If it doesn't on first plan, raise it as a separate item under the parent strategy.

### What happens after task 28

The next two highest-leverage specs to start are:

1. `lza-config-rules-and-ssm-remediations` — the Config Rule + SSM remediation work for `S3.5`, `S3.9`, `S3.13`, `S3.17`, `SNS.1`, `CloudWatch.16`. Biggest finding-count knockdown. Lives entirely in `aws-accelerator-config/security-config.yaml`, no Terraform.
2. `lza-vpc-endpoints-pci-coverage` — investigation into why the EC2.10/55/56/57/58/60 controls are failing on `vpc-0766c6bceb81ea3fa` despite the central endpoints already being defined.

Either can run in parallel with task 24 (apply for this spec).
