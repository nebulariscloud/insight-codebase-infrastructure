# Terraform vs LZA — quick reference

This repo manages AWS in two layers:

| Layer | Tool | Lives in | Cycle time |
|---|---|---|---|
| Platform: accounts, OUs, VPCs, TGW, IPAM, Identity Center, central security & logging, SCPs | LZA | `aws-accelerator-config/` and `thenew-aws-accelerator-config/` | ~30 min pipeline |
| Apps: ALBs, WAFs, EC2, ECS, RDS, Lambda, app DNS, app certs, Global Accelerator | Terraform | `terraform/` | seconds |

Existing CloudFormation stacks defined in `customizations-config.yaml` (`IngressALB`, `ScriptcaseLB`, `ScriptcaseGA`) **stay where they are**. Only new app-layer infrastructure goes to Terraform. We don't migrate stable resources just for tidiness.

## Where to start

- Read `terraform/README.md` for the full operating contract.
- New stack? Copy `terraform/live/_template/` to `terraform/live/<account>/<stack-name>/` and edit.
- Need credentials? See the "Credential model" section in `terraform/README.md`.
- First time setup? Run `terraform/_bootstrap/` once with admin SSO into SharedServices.

## The boundary, in one sentence

> LZA owns the platform. Terraform owns the apps. Terraform reads LZA outputs from SSM (`/accelerator/*`) but never writes there.
