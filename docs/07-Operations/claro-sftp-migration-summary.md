# Claro SFTP migration — summary

What got built, what changed, and what's still pending. This is the
companion doc to the existing `sftp-server` (amex) leaves; the goal was
to bring Claro to functional parity.

## Goal

Stand up a second SFTP server (Claro) with the same shape as the
existing one: private EC2 in shared-prod, internet-facing NLB in the
Perimeter ingress VPC, dedicated S3 bucket for recording storage, and a
scoped instance role tying the two together. No deviations from the
existing pattern unless forced by IAM policy.

## What was added

### `terraform/live/production/claro-recordings/` (new leaf)

Mirror of `amex-recordings`. S3 bucket for Claro recording storage with:

- Object Lock enabled at create time (cannot be turned on later)
- Versioning enabled (required for Object Lock)
- SSE-S3 encryption by default
- Public access fully blocked
- Bucket-owner-enforced ACLs
- TLS-only bucket policy
- Lifecycle rule expiring non-current versions after 365 days
- Lifecycle rule aborting incomplete multipart uploads after 7 days

Default bucket name: `claro-recordings-prod-<account_id>`.

### `terraform/live/production/sftp-server-claro/iam.tf` (new file)

Dedicated instance role + instance profile, mirroring the existing
`sftp-server` leaf's `iam.tf`. Carries:

- `AmazonSSMManagedInstanceCore` (managed)
- `CloudWatchAgentServerPolicy` (managed)
- Inline `claro-recordings-access` policy granting `ListBucket`,
  `GetBucketLocation` on the bucket and `GetObject`, `GetObjectVersion`,
  `PutObject`, `PutObjectAcl`, `PutObjectRetention`, `PutObjectLegalHold`,
  `AbortMultipartUpload`, `ListMultipartUploadParts` on the objects.

The role is named `sftp-server-claro-instance-role` and explicitly does
**not** carry the `Accelerator=AWSAccelerator` tag, which keeps it
inside the `TerraformExecution` allow-list (the `IamForAppRoles`
statement uses `NotResource: AWSAccelerator-*`).

### `terraform/live/production/sftp-server-claro/main.tf` (modified)

Switched `iam_instance_profile` from a variable referencing
`EC2-Default-SSM-Role` to `aws_iam_instance_profile.sftp.name` from the
new `iam.tf`. Same wiring as the existing `sftp-server` leaf.

Set `monitoring = false`. See "Why monitoring is off" below.

### `terraform/live/production/sftp-server-claro/variables.tf` (modified)

- Removed unused `iam_instance_profile` variable
- Added `claro_bucket_name` (matches the existing `amex_bucket_name` on
  the sibling leaf)

### `terraform/live/production/sftp-server-claro/README.md` (modified)

Added pointers to the new bucket leaf, documented apply order, and
clarified what this stack owns vs what the bucket leaf owns.

## What stayed the same as the existing `sftp-server`

To keep the diff narrow:

- VPC and subnet (`vpc-04a8720d0ddb40713`, shared-prod-app-a)
- Instance type (`t3.medium`), root volume (20 GiB gp3), IMDSv2,
  EBS-optimized, deletion-protected
- First-boot user_data (fail2ban whitelist for `10.0.0.0/20`, EIC agent
  install, sshd safety reload)
- Inbound SG: TCP/22 from `10.0.0.0/20` (perimeter ingress CIDR)
- EICE SG wired in for admin SSH (`sg-0a990a87e6abca926`)
- NLB shape: `target_type=ip`, `availability_zone=all` (cross-VPC via
  TGW), `preserve_client_ip=false`, TCP/22 listener and TCP/22 health
  check, `allocate_eips=false`, `cross_zone_load_balancing=false`,
  `deletion_protection=true`

Pinned IPs: existing server `10.12.1.50`, Claro `10.12.1.51`. AMIs:
existing `ami-0142292b2f75b5156`, Claro `ami-02720404eb5b85c63`
(re-encrypted with `alias/accelerator/ebs/default-encryption/key` during
copy).

## PRs and CI runs

| PR | Title | Outcome |
|---|---|---|
| #22 | feat(sftp-claro): claro-recordings bucket and dedicated instance role | Merged. Apply on main: `claro-recordings` succeeded, `sftp-server-claro` failed at the post-create monitoring update. |
| #23 | fix(sftp-claro): disable detailed monitoring to match TerraformExecution policy | Sets `monitoring = false`, aligns Terraform desired state with what AWS already has. |

## Why monitoring is off

The `TerraformExecution` allow policy in
`aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json`
enumerates EC2 actions explicitly under the `Ec2AppLayer` statement and
does not grant `ec2:MonitorInstances` or `ec2:UnmonitorInstances`.

When `monitoring = true` is set on `aws_instance`, the AWS provider
calls `RunInstances` first, then issues a separate `MonitorInstances`
call after the instance is up. The `MonitorInstances` call 403'd in PR
#22's apply on main, leaving the leaf half-applied (instance up, IAM
created, monitoring update failed).

The instance in AWS already has monitoring disabled (the create call
succeeded with the default), so flipping the Terraform value to `false`
is a state-only no-op against reality and lets the next apply converge.

The existing `sftp-server` (amex) leaf has `monitoring = true` and was
applied before the policy was tightened to its current shape. Its state
file thinks detailed monitoring is on; AWS console says off. Same drift,
just not noticed because nothing has triggered a re-apply.

## Apply order

1. `terraform/live/production/claro-recordings`
2. `terraform/live/production/sftp-server-claro`
3. `terraform/live/perimeter/sftp-claro-nlb` (already in place; targets
   `10.12.1.51` over TGW)

CI does this automatically when the PR merges to main, in alphabetical
order, gated on the `production` GitHub environment for required
reviewer approval.

## Known follow-ups

### 1. Tighten NLB ingress

`terraform/live/perimeter/sftp-claro-nlb/terraform.tfvars` still has
`allowed_source_cidrs = ["0.0.0.0/0"]` (default) so initial connectivity
testing isn't blocked. Tighten to Claro's egress CIDRs as soon as they
are known. The NLB SG is the IP allowlist enforcement point;
`preserve_client_ip` is off so the SFTP server itself can't filter on
real client IPs.

### 2. Re-enable detailed monitoring (cross-cutting, separate PR)

Add `ec2:MonitorInstances` and `ec2:UnmonitorInstances` to the
`Ec2AppLayer` statement in
`aws-accelerator-config/iam-policies/terraform-execution-allow-policy.json`.
That's an LZA-config change, not a Terraform apply, so it goes through
the AWSAccelerator pipeline. After it lands, flip both `sftp-server`
and `sftp-server-claro` back to `monitoring = true` in the same PR.

### 3. Confirm root-only AMI is correct

Both leaves currently run with `data_volume_snapshot_id = ""` (no
separate data volume). Worth confirming with whoever did the source
migration that everything Claro needs is baked into the root snapshot
(`snap-04370f749b46cef5c`, 20 GiB). If files lived on a separate disk
in the source environment, the leaf needs a data volume snapshot ID.

### 4. (Optional) DNS

Neither SFTP server has a friendly hostname. If Claro's tooling needs
one, add a Route53 record pointing at the NLB's `dns_name` output.

### 5. Make SSM Session Manager the primary login method

The migrated AMI for both SFTP servers is Debian 13 (trixie). Debian
does **not** ship the `amazon-ssm-agent` package, which is why the
instances showed "offline" in SSM regardless of IAM, networking, or
endpoint reachability. Network plumbing (TGW routes, central interface
endpoints, PHZ associations, endpoint SG) was already correct.

Verified inside `i-02d255c498a798ab5` (10.12.1.50):

```
admin@ip-10-12-1-50:~$ getent hosts ssm.us-east-2.amazonaws.com
10.0.21.99      ssm.us-east-2.amazonaws.com
10.0.20.33      ssm.us-east-2.amazonaws.com
admin@ip-10-12-1-50:~$ curl -sv https://ssm.us-east-2.amazonaws.com   # TLS handshake starts
admin@ip-10-12-1-50:~$ systemctl status amazon-ssm-agent
Unit amazon-ssm-agent.service could not be found.
```

DNS resolves to private IPs in the Endpoints VPC, the TLS handshake
begins, and the service unit doesn't exist — agent missing, not network.

**Permanent fix**: extended the `user_data` in both SFTP leaves to
detect Debian / Ubuntu / RHEL family and install + enable the agent on
first boot. Idempotent: if the unit already exists (AL2/AL2023/Ubuntu
where the agent is preinstalled), it's a no-op. New replacements come
up Session-Manager-ready automatically.

**Manual remediation for the existing running instances** (one-time,
since the leaf module ignores `user_data` changes):

```bash
# EICE in to each box
aws ec2-instance-connect ssh --region us-east-2 \
  --instance-id i-02d255c498a798ab5 --connection-type eice --os-user admin

# Inside (Debian 13)
cd /tmp
sudo wget https://s3.us-east-2.amazonaws.com/amazon-ssm-us-east-2/latest/debian_amd64/amazon-ssm-agent.deb
sudo dpkg -i amazon-ssm-agent.deb
sudo systemctl enable --now amazon-ssm-agent
```

Done on `i-02d255c498a798ab5` (sftp-server, amex). Repeat for
`i-074b971f11e3a08ac` (sftp-server-claro).

**Verify both came online:**

```bash
aws ssm describe-instance-information --region us-east-2 \
  --filters "Key=InstanceIds,Values=i-02d255c498a798ab5,i-074b971f11e3a08ac" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion,PlatformName]' \
  --output table
# Both should show PingStatus=Online.
```

EICE remains wired up via `eice_security_group_id` in both leaves as a
fallback for when the agent itself is unhealthy, but day-to-day access
is now `aws ssm start-session --target <instance-id>`.

### 6. Session Manager KMS permission (followed on from #5)

After the agent registered, `aws ssm start-session` failed with:

```
AccessDeniedException: User: arn:aws:sts::395516496764:assumed-role/sftp-server-instance-role/...
is not authorized to perform: kms:Decrypt on resource:
arn:aws:kms:us-east-2:395516496764:key/f148edeb-221b-4a78-8367-96f95c1669c6
```

That's LZA's Session Manager streaming CMK
(`alias/accelerator/sessionmanager-logs/session`). It exists because
`global-config.yaml` has `sessionManager.sendToCloudWatchLogs: true`,
which encrypts session traffic with this CMK.

LZA wires the necessary `kms:Decrypt` + `kms:GenerateDataKey` onto the
roles listed in `sessionManager.attachPolicyToIamRoles` — currently
`[EC2-Default-SSM-Role]` only. Our dedicated
`sftp-server-instance-role` and `sftp-server-claro-instance-role` aren't
on that list (and shouldn't be — keeping them Terraform-managed avoids
the LZA-tag/SCP mutation problem).

**Fix landed**: both leaves' `iam.tf` now include a
`session-manager-kms` inline policy granting `kms:Decrypt` +
`kms:GenerateDataKey` on the alias, looked up via
`data "aws_kms_alias"`. After `terraform apply` on both leaves,
Session Manager works end-to-end.

## Verification checklist

After the apply on main goes green:

```bash
# AWS console / CLI in Production us-east-2
INSTANCE_ID=<from terraform output -raw instance_id>

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region us-east-2 \
  --query 'Reservations[0].Instances[0].[State.Name,PrivateIpAddress,IamInstanceProfile.Arn,Monitoring.State]'
# Expect: running | 10.12.1.51 | .../sftp-server-claro-instance-profile | disabled

aws s3api get-bucket-versioning --bucket claro-recordings-prod-395516496764
# Expect: { "Status": "Enabled" }

aws s3api get-object-lock-configuration --bucket claro-recordings-prod-395516496764
# Expect: ObjectLockEnabled = "Enabled"
```

```bash
# NLB target health (Perimeter us-east-2)
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names sftp-claro-nlb-tg --query 'TargetGroups[0].TargetGroupArn' --output text) \
  --region us-east-2
# Expect: Target 10.12.1.51:22 in "healthy"
```

```bash
# Smoke test via SSM Session Manager (primary login method).
aws ssm start-session --target "$INSTANCE_ID" --region us-east-2

# Or, if the SSM agent is offline for whatever reason, fall back to EICE
# (requires admin SSO and the eice_security_group_id wired in tfvars):
aws ec2-instance-connect ssh \
  --region us-east-2 \
  --instance-id "$INSTANCE_ID" \
  --connection-type eice \
  --os-user ec2-user

# Inside the box
sudo systemctl status sshd
sudo lsof -nP -i :22
sudo tail -50 /var/log/sftp-bootstrap.log
aws s3 ls s3://claro-recordings-prod-395516496764/
```

The `aws s3 ls` call uses the instance role, which now has the
scoped `claro-recordings-access` policy. If it returns without an
AccessDenied, the wiring is good end-to-end.
