# insight-ubuntu-dev (Production)

Dev-side sibling of `insight-ubuntu-prod`. Same shape: Ubuntu 22.04 LTS `t3.medium`, private-only, no ingress, SSM Session Manager for access. Separate leaf and separate state so changes on the dev box don't propagate to prod.

Why both live in the Production account: the LZA `shared-dev` VPC in this install has no app subnets shared into the Development account yet, and the client asked for two similar boxes today. When the shared-dev subnets get added, we can move this leaf under `terraform/live/development/` and re-apply against the Development account — the change is renaming the leaf and pointing the backend key at a new state file. The workload itself is portable.

See [`insight-ubuntu-prod/README.md`](../insight-ubuntu-prod/README.md) for the full rationale, access model, and outbound notes. This leaf differs only in name, IP, and state key.

## Values

- Instance name: `insight-ubuntu-dev`
- Private IP: `10.12.1.71`
- Subnet: `subnet-00d31cac6422417c4` (`shared-prod-app-a`)
- State key: `live/production/insight-ubuntu-dev/terraform.tfstate`
