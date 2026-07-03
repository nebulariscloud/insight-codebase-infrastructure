# insight-ubuntu-prod (Production)

Private Ubuntu 22.04 LTS `t3.medium` in `shared-prod`, `us-east-2`. Provisioned for Insight's client (Julian) alongside a matching dev-side sibling (`insight-ubuntu-dev`) so they can iterate on dev without touching prod.

## Design constraints (from the request)

- OS: Ubuntu Server 22.04 LTS, 64-bit.
- Type: `t3.medium`.
- No public visibility.
- No other servers call it (no ingress from anywhere in the SG).

## What this leaf creates

- One EC2 instance, private-only, in `shared-prod-app-a` (`10.12.1.0/24`).
- Dedicated instance security group with **no ingress rules** (except optional TCP/22 from the EICE endpoint SG when `eice_security_group_id` is set).
- Dedicated IAM role + instance profile with `AmazonSSMManagedInstanceCore`, `CloudWatchAgentServerPolicy`, and the KMS grant Session Manager needs against LZA's `accelerator/sessionmanager-logs/session` CMK.
- First-boot user data that ensures `snap.amazon-ssm-agent` is enabled and running (Ubuntu 22.04 ships the agent via snap; this belt-and-suspenders makes sure it's active).

## AMI selection

`data "aws_ssm_parameter"` reads `/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id` — Canonical's public parameter that always points at the current Ubuntu 22.04 LTS AMD64 AMI in the region. The `ec2-migrated` module's `lifecycle.ignore_changes = [ami]` means new SSM values don't trigger silent replacements. When you want to roll a fresh image, bump it deliberately (taint the instance, or migrate the workload to a new leaf).

## Access

Primary: SSM Session Manager.

```bash
aws ssm start-session --region us-east-2 --target <instance-id-from-outputs>
```

Fallback (only if the SSM agent doesn't register): EICE endpoint. Wired in via `eice_security_group_id` in `terraform.tfvars`.

```bash
aws ec2-instance-connect ssh \
  --region us-east-2 \
  --instance-id <instance-id> \
  --connection-type eice \
  --os-user ubuntu
```

## Outbound

The shared-prod VPC has `internetGateway: false`. Outbound egress goes TGW → egress VPC → NAT GW. That's enough for `apt update`, package installs, and general workload traffic. If the workload needs specific endpoints allowlisted (on-prem DB, license server, etc.), tell us and we'll add them to the SG's egress rules or coordinate the perimeter side.

## What this does NOT create

- ALB / NLB / EIP — no public exposure was requested.
- Route53 records — no DNS was requested.
- Any S3 bucket grants — the role is minimal.
