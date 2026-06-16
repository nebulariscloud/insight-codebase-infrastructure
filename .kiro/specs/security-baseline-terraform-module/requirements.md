# Requirements Document

## Introduction

This feature delivers a reusable Terraform module, `terraform/modules/security-baseline/`, that applies a small set of account-level and region-level AWS security service settings that AWS Config does not model and that Landing Zone Accelerator (LZA) does not expose declaratively. The module is invoked once per spoke account from a per-account leaf at `terraform/live/<account>/security-baseline/`. Wave 1 of the rollout targets the PCI account (`PCI`) across the active regions; Wave 2 re-applies the same module to the other spoke accounts (`Production`, `Development`, `SharedServices`, `Network`, `Perimeter`) without changes to the module itself.

The feature implements the `Terraform` mechanism rows from the parent strategy spec `security-hub-findings-remediation-strategy` for the following Security Hub controls: `SSM.7` (Critical), `EC2.182` (High), `SSM.6` (Medium), and `Account.1` (Medium).

Two strategy rows that were originally classified `Terraform` in the parent design — `S3.22` and `S3.23` — are explicitly out of scope here because the target trail (`aws-controltower-BaselineCloudTrail`) lives in the Management account, and the existing Terraform credential model deliberately excludes the Management account from the `TerraformExecution` trust path (`terraform/README.md` and `terraform-execution-policy.json`). Those two findings are deferred to a new decision item D-9 in the parent strategy and will be addressed in a separate spec once a path is chosen.

This module is not a one-off PCI fix. It is the home for every future account/region service setting that AWS Config does not evaluate, including the deferred Inspector findings (`Inspector.1` through `Inspector.4`) once decision item D-1 is resolved. The module is designed so adding a new control means adding a new resource to the module and re-applying, never restructuring the module.

## Glossary

- **Security_Baseline_Module**: The Terraform module at `terraform/modules/security-baseline/` produced by this feature.
- **Security_Baseline_Leaf**: A per-account Terraform leaf at `terraform/live/<account>/security-baseline/` that invokes the Security_Baseline_Module for one spoke account.
- **In_Scope_Account**: A non-Management spoke account in the organization. Wave 1 contains `PCI`. Wave 2 contains `Production`, `Development`, `SharedServices`, `Network`, `Perimeter`. `LogArchive` and `Audit` are also In_Scope_Account values when the module is rolled out to security accounts. `Management` is explicitly excluded because the existing `TerraformExecution` trust path does not include it.
- **Active_Region**: One of `us-east-1`, `us-east-2`, `us-west-2`, matching the regions in the parent strategy.
- **Region_Set**: The set of Active_Region values for which a given service setting must be applied. For most Wave 1 controls this is all three regions.
- **Account_Setting**: A service setting that is set once per AWS account regardless of region (for example, the SECURITY alternate contact). Account_Settings are configured by the module exactly once per account.
- **Region_Setting**: A service setting that must be set once per region inside an account (for example, SSM document public-sharing block, EBS snapshot block public access, SSM Automation CloudWatch logging). Region_Settings are configured by the module once per Active_Region.
- **TerraformExecution_Role**: The IAM role named `TerraformExecution` that LZA provisions in every spoke account via `iam-config.yaml`. The Security_Baseline_Leaf assumes this role to apply changes in the target account.
- **SharedServices_Tooling_Profile**: The AWS profile that authenticates to the SharedServices account (via SSO locally or OIDC in CI) and is used by the leaf to read `/accelerator/organization/account-ids/<AccountName>` from SSM Parameter Store.
- **Provider_Alias**: A Terraform AWS provider alias scoped to a single Active_Region, used by the module to apply Region_Settings region by region.
- **Idempotent_Apply**: A subsequent `terraform plan` after a successful `terraform apply` reports no changes for the same input variables.
- **Account_Settings_Drift**: The state in which an Account_Setting or Region_Setting in AWS does not match the value declared by the module.
- **Deferred_Resource**: A Terraform resource that is conditionally enabled (via a feature flag variable) and is disabled by default until the corresponding decision item lands. Inspector resources are Deferred_Resources in this module pending decision D-1.
- **Compliance_Evidence**: A capture of post-apply state that proves the targeted Security Hub finding has moved to `PASSED` for the In_Scope_Account.

## Requirements

### Requirement 1: Module location, layout, and conventions

**User Story:** As a platform engineer, I want the Security_Baseline_Module to live in a predictable location and follow the existing Terraform conventions in this repository, so that other contributors can find, review, and extend it without learning a new pattern.

#### Acceptance Criteria

1. THE Security_Baseline_Module SHALL be created at `terraform/modules/security-baseline/`.
2. THE Security_Baseline_Module SHALL be a self-contained Terraform module composed of one or more `*.tf` files, with a top-level `README.md` that documents inputs, outputs, and usage.
3. THE Security_Baseline_Module SHALL declare its provider requirements in a `versions.tf` file using `required_providers` and `required_version`, matching the version pins used in `terraform/live/_template/versions.tf`.
4. THE Security_Baseline_Module SHALL declare every input as a `variable` block in `variables.tf` with `type`, `description`, and a default value where applicable.
5. THE Security_Baseline_Module SHALL declare every output as an `output` block in `outputs.tf` with `description`.
6. THE Security_Baseline_Module SHALL NOT declare any `provider` blocks. Providers are passed in by the consuming Security_Baseline_Leaf.
7. THE Security_Baseline_Module SHALL NOT declare a `backend`. State backends are configured by the consuming Security_Baseline_Leaf.
8. THE Security_Baseline_Module SHALL NOT contain any `*.tfvars` files or hard-coded account IDs.
9. THE Security_Baseline_Module SHALL pass `terraform fmt -check -recursive`.
10. THE Security_Baseline_Module SHALL pass `terraform validate` when invoked from a representative leaf.

### Requirement 2: Multi-region application via provider aliases

**User Story:** As a platform engineer, I want the module to apply Region_Settings consistently across all Active_Regions without duplicating Terraform code per region, so that adding a new region is a single configuration change rather than a code rewrite.

#### Acceptance Criteria

1. THE Security_Baseline_Module SHALL accept a Provider_Alias mapping from each Active_Region to an AWS provider through Terraform's `providers` argument at the module call site, using `configuration_aliases` in the module's `versions.tf` `required_providers.aws.configuration_aliases`.
2. THE Security_Baseline_Module SHALL declare exactly one Provider_Alias per Active_Region in scope. The initial set SHALL be `aws.use1` for `us-east-1`, `aws.use2` for `us-east-2`, and `aws.usw2` for `us-west-2`.
3. THE Security_Baseline_Module SHALL apply every Region_Setting once per Provider_Alias.
4. WHEN a new Active_Region is added in the future, THE Security_Baseline_Module SHALL require only the addition of a new Provider_Alias to `configuration_aliases` and the corresponding resource references, with no changes to existing Region_Setting code paths.
5. THE Security_Baseline_Module SHALL NOT use `for_each` over a `toset` of region strings to drive per-region resources, because Terraform AWS provider aliases cannot be selected dynamically. Per-region resources are expressed explicitly with provider aliases.

### Requirement 3: SSM document public sharing block per region (`SSM.7`)

**User Story:** As the security owner, I want SSM documents to be blocked from public sharing in every Active_Region of every In_Scope_Account, so that custom runbooks cannot be unintentionally exposed to other AWS accounts.

#### Acceptance Criteria

1. WHEN the Security_Baseline_Module is applied to an In_Scope_Account, THE Security_Baseline_Module SHALL set the SSM service setting `arn:aws:ssm:<region>:<account>:servicesetting/ssm/documents/console/public-sharing-permission` to `Disable` in every Active_Region.
2. THE Security_Baseline_Module SHALL implement the SSM.7 fix using the `aws_ssm_service_setting` Terraform resource.
3. THE Security_Baseline_Module SHALL produce one `aws_ssm_service_setting` resource per Active_Region for the public-sharing-permission setting.
4. THE Security_Baseline_Module SHALL satisfy Idempotent_Apply for the SSM.7 resources after a successful apply.
5. WHEN the Security_Baseline_Module is removed via `terraform destroy`, THE Security_Baseline_Module SHALL leave the public-sharing-permission setting at its safe value `Disable`. (Note: `aws_ssm_service_setting` does not delete the setting; this requirement is met by the resource's natural behavior.)

### Requirement 4: EBS snapshot public access block per region (`EC2.182`)

**User Story:** As the security owner, I want EBS snapshot public sharing to be blocked at the account-region level for every Active_Region, so that snapshots cannot be unintentionally shared publicly and expose data.

#### Acceptance Criteria

1. WHEN the Security_Baseline_Module is applied to an In_Scope_Account, THE Security_Baseline_Module SHALL enable EBS snapshot block-public-access at the `block-all-sharing` level in every Active_Region.
2. THE Security_Baseline_Module SHALL implement the EC2.182 fix using the `aws_ebs_snapshot_block_public_access` Terraform resource.
3. THE Security_Baseline_Module SHALL produce one `aws_ebs_snapshot_block_public_access` resource per Active_Region.
4. THE Security_Baseline_Module SHALL set `state = "block-all-sharing"` for every `aws_ebs_snapshot_block_public_access` resource.
5. THE Security_Baseline_Module SHALL satisfy Idempotent_Apply for the EC2.182 resources after a successful apply.

### Requirement 5: SSM Automation CloudWatch logging per region (`SSM.6`)

**User Story:** As the security owner, I want SSM Automation executions to write logs to CloudWatch Logs in every Active_Region, so that runbook executions are auditable and persistent.

#### Acceptance Criteria

1. WHEN the Security_Baseline_Module is applied to an In_Scope_Account, THE Security_Baseline_Module SHALL set the SSM service setting `arn:aws:ssm:<region>:<account>:servicesetting/ssm/automation/cloudwatch-log-group` to a CloudWatch Logs group name `/aws/ssm/automation` in every Active_Region.
2. THE Security_Baseline_Module SHALL create the destination CloudWatch Logs group named `/aws/ssm/automation` in every Active_Region using `aws_cloudwatch_log_group` if the group does not already exist, with a configurable retention period defaulting to 365 days.
3. THE Security_Baseline_Module SHALL create or reference an IAM role that SSM Automation assumes to write to the destination log group, with a trust policy for `ssm.amazonaws.com` and a permissions policy granting `logs:CreateLogStream` and `logs:PutLogEvents` scoped to the log group ARN in each Active_Region.
4. THE Security_Baseline_Module SHALL implement the service-setting fix using the `aws_ssm_service_setting` Terraform resource, one per Active_Region.
5. THE Security_Baseline_Module SHALL satisfy Idempotent_Apply for the SSM.6 resources after a successful apply.
6. THE Security_Baseline_Module SHALL accept an input variable `automation_log_retention_days` of type `number` with a default value of `365`, applied to every Active_Region's destination log group.

### Requirement 6: Account-level alternate security contact (`Account.1`)

**User Story:** As the security owner, I want every In_Scope_Account to have a SECURITY alternate contact set, so that AWS can reach the security team for incidents and abuse notifications.

#### Acceptance Criteria

1. WHEN the Security_Baseline_Module is applied to an In_Scope_Account, THE Security_Baseline_Module SHALL set a SECURITY alternate contact on the target AWS account.
2. THE Security_Baseline_Module SHALL implement the Account.1 fix using the `aws_account_alternate_contact` Terraform resource with `alternate_contact_type = "SECURITY"`.
3. THE Security_Baseline_Module SHALL accept the contact fields as input variables: `security_contact_name` (string), `security_contact_email` (string), `security_contact_phone` (string, marked `sensitive = true`), `security_contact_title` (string).
4. THE Security_Baseline_Leaf SHALL source `security_contact_phone` from an SSM SecureString parameter stored in SharedServices at the path `/security-baseline/security-contact-phone`, read via the `aws.tooling` provider data source.
5. THE feature SHALL document the one-time creation of the SSM SecureString parameter in the leaf README and in `tasks.md`, including the AWS CLI command (`aws ssm put-parameter --type SecureString --name /security-baseline/security-contact-phone --value <value>`).
6. THE Security_Baseline_Leaf SHALL NOT read `security_contact_phone` from a `*.tfvars` file, an environment variable, or a hard-coded literal in `*.tf` source.
7. THE Security_Baseline_Module SHALL apply the SECURITY alternate contact exactly once per In_Scope_Account regardless of the number of Active_Regions.
8. THE Security_Baseline_Module SHALL NOT emit phone or email values to Terraform output, console logs, or `terraform plan` summaries beyond what the AWS provider already prints in resource diffs (which are redacted because the variable is marked sensitive).
9. THE Security_Baseline_Module SHALL satisfy Idempotent_Apply for the Account.1 resource after a successful apply.

### Requirement 7: Inspector enablement as a deferred capability

**User Story:** As the platform owner, I want the module to be ready to enable Amazon Inspector v2 once decision item D-1 is resolved, so that adding Inspector enablement is a configuration toggle rather than a new module.

#### Acceptance Criteria

1. THE Security_Baseline_Module SHALL accept an input variable `inspector_enabled` of type `bool` with a default value of `false`.
2. THE Security_Baseline_Module SHALL accept an input variable `inspector_resource_types` of type `list(string)` with a default value of `[]`. Valid values include `EC2`, `ECR`, `LAMBDA`, and `LAMBDA_CODE`.
3. THE Security_Baseline_Module SHALL accept an input variable `inspector_regions` of type `list(string)` with a default value of `[]`. Each value SHALL be one of the Active_Regions for which the consuming Security_Baseline_Leaf provides a Provider_Alias.
4. WHEN `inspector_enabled` is `true` and `inspector_resource_types` is non-empty and `inspector_regions` is non-empty, THE Security_Baseline_Module SHALL create one `aws_inspector2_enabler` resource per region in `inspector_regions`, with `account_ids` set to the current account ID and `resource_types` set to `inspector_resource_types`.
5. WHEN `inspector_enabled` is `false`, THE Security_Baseline_Module SHALL NOT create any `aws_inspector2_enabler` resources.
6. THE Security_Baseline_Module SHALL fail `terraform plan` with a clear validation error if `inspector_enabled` is `true` and either `inspector_resource_types` or `inspector_regions` is empty.

### Requirement 8: Per-account leaf invocation contract

**User Story:** As a platform engineer onboarding a new In_Scope_Account, I want a documented, copy-pasteable leaf layout that consumes the Security_Baseline_Module, so that adding the baseline to a new account is a five-minute task.

#### Acceptance Criteria

1. THE feature SHALL produce a Wave 1 Security_Baseline_Leaf at `terraform/live/pci/security-baseline/` that invokes the Security_Baseline_Module for the PCI account.
2. THE Wave 1 Security_Baseline_Leaf SHALL include `backend.tf`, `providers.tf`, `variables.tf`, `versions.tf`, `main.tf`, and a `README.md` matching the structure used by existing leaves under `terraform/live/`.
3. THE Wave 1 Security_Baseline_Leaf `backend.tf` SHALL use the S3 backend convention from `terraform/README.md` with `key = "live/pci/security-baseline/terraform.tfstate"`.
4. THE Wave 1 Security_Baseline_Leaf `providers.tf` SHALL declare three regional AWS providers (one per Active_Region) and a tooling provider scoped to SharedServices for reading `/accelerator/organization/account-ids/PCI` from SSM Parameter Store, mirroring the existing leaf provider pattern.
5. THE Wave 1 Security_Baseline_Leaf SHALL pass exactly the providers `aws.use1`, `aws.use2`, `aws.usw2` to the Security_Baseline_Module via the `providers` argument.
6. THE Wave 1 Security_Baseline_Leaf SHALL set `var.security_contact_name = "Alex Gonzalez"`, `var.security_contact_email = "security@nebulariscloud.com"`, `var.security_contact_title = "CEO"`. THE leaf SHALL source `var.security_contact_phone` from the SSM SecureString parameter `/security-baseline/security-contact-phone` in SharedServices via a `data "aws_ssm_parameter"` block on the `aws.tooling` provider with `with_decryption = true`.
7. THE Wave 1 Security_Baseline_Leaf SHALL set `var.inspector_enabled = false` (deferred to D-1).
8. THE feature SHALL NOT modify any existing leaves under `terraform/live/`.

### Requirement 9: Wave 2 readiness without module changes

**User Story:** As a platform engineer planning the org-wide rollout, I want to extend the baseline to other spoke accounts by copying the leaf and changing variables, so that Wave 2 does not require revisiting the module.

#### Acceptance Criteria

1. THE Security_Baseline_Module SHALL be implemented such that any non-Management spoke account can be added by creating a new leaf at `terraform/live/<account>/security-baseline/` that calls the same module with different `var.account_name` and `var.security_contact_*` values, with no edits to the module's `*.tf` files.
2. THE feature SHALL document, in `terraform/modules/security-baseline/README.md`, the procedure to add a new In_Scope_Account, including the leaf scaffolding step and the SSM Parameter Store path for resolving the spoke account ID.
3. THE feature SHALL NOT introduce any account-specific conditionals or `count` expressions inside the Security_Baseline_Module that depend on a hard-coded account name.

### Requirement 10: Out-of-scope items and explicit deferrals

**User Story:** As a reviewer, I want the spec to explicitly call out which strategy rows are not covered by this spec and why, so that future contributors do not assume gaps are bugs.

#### Acceptance Criteria

1. THE feature SHALL explicitly document that `S3.22` and `S3.23` from the parent strategy are out of scope for this spec, with the reason that the target trail (`aws-controltower-BaselineCloudTrail`) lives in the Management account and the existing `TerraformExecution` trust path excludes Management.
2. THE feature SHALL explicitly document that the Wave 2 application of the module to non-PCI accounts is part of the parent strategy's Wave 2 work and is not part of this spec's deliverable scope; only the Wave 1 leaf is delivered here.
3. THE feature SHALL explicitly document that Inspector enablement is deferred to D-1 and is implemented as a feature flag in this spec but not enabled in any leaf.
4. THE feature SHALL register a new decision item D-9 in the parent strategy spec to capture the path for `S3.22` and `S3.23` (Management-account trail event selectors). The decision item SHALL list the three options identified during scoping (narrow IAM grant + dedicated leaf; LZA customizations stack; one-time manual change with runbook).

### Requirement 11: Validation and verification

**User Story:** As the security owner, I want a documented verification procedure so that anyone can confirm the targeted Security Hub findings have moved to `PASSED` after the module is applied.

#### Acceptance Criteria

1. THE feature SHALL include in `terraform/modules/security-baseline/README.md` a verification section documenting how to confirm each control:
   - `SSM.7`: `aws ssm get-service-setting --setting-id arn:aws:ssm:<region>:<account>:servicesetting/ssm/documents/console/public-sharing-permission --region <region>` returns `SettingValue` of `Disable`.
   - `EC2.182`: `aws ec2 get-snapshot-block-public-access-state --region <region>` returns `State` of `block-all-sharing`.
   - `SSM.6`: `aws ssm get-service-setting --setting-id arn:aws:ssm:<region>:<account>:servicesetting/ssm/automation/cloudwatch-log-group --region <region>` returns `SettingValue` of `/aws/ssm/automation`.
   - `Account.1`: `aws account get-alternate-contact --alternate-contact-type SECURITY` returns the configured contact.
2. THE feature SHALL include in the same README a Security Hub re-aggregation procedure: open the Security Hub console in the delegated admin (Audit) account, filter findings by control ID for the In_Scope_Account, and confirm the targeted findings are in `PASSED` state within one aggregation cycle after `terraform apply`.
3. THE feature SHALL include a rollback procedure in the same README that restores the prior state for each control in the event of a regression.

### Requirement 12: Compliance evidence capture

**User Story:** As the security owner, I want Compliance_Evidence captured for each apply so that audits can reference the post-apply state.

#### Acceptance Criteria

1. WHEN the Wave 1 Security_Baseline_Leaf is applied successfully, THE feature SHALL produce a captured artifact set containing: the `terraform plan` and `terraform apply` outputs; the AWS CLI verification command outputs from Requirement 11.1; and a Security Hub finding export filtered by the four control IDs and the PCI account.
2. THE captured artifact set SHALL be stored in a location agreed with the security owner, referenced by file path or storage URI in the parent strategy spec's evidence appendix.
3. THE feature SHALL document the artifact-capture procedure in the same README so it can be reproduced for Wave 2 applications.

### Requirement 13: Safety, secrets, and least privilege

**User Story:** As the security owner, I want the module and its leaves to follow the repository's existing security defaults so that nothing in this work erodes the baseline.

#### Acceptance Criteria

1. THE Security_Baseline_Module SHALL NOT log secret values, contact phone numbers, or email addresses outside of normal Terraform resource diffs.
2. THE Security_Baseline_Leaf SHALL NOT commit any `*.tfvars` file containing the security contact values to source control. Email, name, and title SHALL be supplied as variable defaults in `variables.tf`. Phone SHALL be sourced from an SSM SecureString parameter (Requirement 6.4) and SHALL NOT appear as a variable default or `*.tfvars` value.
3. THE Security_Baseline_Module SHALL NOT request any IAM permission beyond what is necessary to manage the resources it declares.
4. THE Security_Baseline_Leaf SHALL assume into the target account using the existing `TerraformExecution_Role` and SHALL NOT introduce a new cross-account role.
5. THE feature SHALL NOT modify the existing `terraform-execution-policy.json` deny boundaries.
