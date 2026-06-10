# SFTP NLB (Perimeter)

Internet-facing Network Load Balancer in the perimeter ingress VPC that
fronts the SFTP server in
[`terraform/live/production/sftp-server/`](../../production/sftp-server/).
Same shape as the existing `wazuh-nlb` leaf, simplified to a single TCP
listener.

## Why an NLB and not the existing ALB

ALBs are HTTP/HTTPS only. SFTP is raw TCP on port 22 (or whatever
non-standard port you've configured), which terminates at L4. NLBs
forward L4 traffic transparently; ALBs cannot.

## Static IPs

The NLB does NOT allocate EIPs. The infrastructure-OU SCP
(`lza-infrastructure-guardrails-1`) denies `ec2:AllocateAddress` for
non-LZA principals, so Terraform can't attach EIPs to the NLB.

Instead the NLB gets the **AWS-managed public IP per AZ** that is
assigned automatically. These IPs are stable for the life of the NLB and
only change if the LB is destroyed and recreated. With
`deletion_protection = true` and the resources here treated as long-lived,
that's a non-event in normal operation.

If you ever need the IPs to outlast NLB recreation, put a Global
Accelerator in front (sibling stack like `wazuh-ga`). The two GA anycast
IPs are AWS-issued and never change for the life of the accelerator.

## Architecture

```
SFTP partner
  │  TCP/22
  ▼
[ NLB (Perimeter ingress) ]   ← AWS-managed public IPs (one per AZ)
  │  TCP/22 (SNAT, preserve_client_ip=false)
  ▼  via TGW
[ SFTP server (shared-prod, Production account) ]
```

## Apply order (one-time)

```bash
# 1. Apply the EC2 leaf first
cd terraform/live/production/sftp-server
aws sso login --profile lza-tooling
export AWS_PROFILE=lza-tooling
terraform init
terraform apply -var-file=terraform.tfvars

# 2. Capture the private IP
PRIVATE_IP=$(terraform output -raw private_ip)
echo "$PRIVATE_IP"

# 3. Edit ../../perimeter/sftp-nlb/terraform.tfvars
#    sftp_server_private_ip = "<paste $PRIVATE_IP>"

# 4. Apply the NLB leaf
cd ../../perimeter/sftp-nlb
terraform init
terraform plan -out tfplan -var-file=terraform.tfvars
terraform apply tfplan

# 5. Read the public IPs to send to the partner
terraform output -json nlb_public_ips
terraform output -raw nlb_dns_name
```

If you'd rather both stacks ride a single CI pipeline, just merge the
two PRs in order — the workflow runs `terraform plan/apply` on changed
leaves, so one PR per leaf keeps the diff readable.

## Verifying the NLB

```bash
NLB_DNS=$(terraform output -raw nlb_dns_name)

# TCP/22 reachable
nc -zv $NLB_DNS 22 -w 5
# expected: Connection to <NLB_DNS> 22 port [tcp/ssh] succeeded!

# Real handshake. Use the migrated server's host key to confirm; first
# connection will prompt to trust the fingerprint.
sftp -P 22 -i ~/.ssh/your_key user@$NLB_DNS
sftp> ls
sftp> bye
```

If `nc` succeeds but `sftp` fails:

- Most likely the SFTP daemon on the source-migrated server is bound to
  a specific IP that's no longer present (e.g. `ListenAddress` in
  `/etc/ssh/sshd_config` pinned to the old EIP). Set it back to `0.0.0.0`
  or remove the directive. Restart sshd.
- Or the server's host SG isn't allowing inbound from `10.0.0.0/20`.
  The Production sftp-server stack opens that automatically; check it
  hasn't been overridden.

## Allowlist hand-off

```bash
terraform output -json nlb_public_ips
# -> ["3.x.y.z", "18.a.b.c"]
```

Send the partner both IPs (and the `nlb_dns_name` if their tooling can
use a hostname). Both AZ IPs need to be allowlisted because the NLB
returns both via DNS round-robin and clients may resolve either.

## Tightening inbound

Once you have the partner's source CIDRs, set `allowed_source_cidrs` in
tfvars and re-apply. The NLB SG is rebuilt; the LB itself isn't replaced.

## Cost

- NLB: ~$16/month + ~$0.006 per LCU-hour
- No EIPs (SCP-blocked)
- No additional WAF / GA costs unless you add them
