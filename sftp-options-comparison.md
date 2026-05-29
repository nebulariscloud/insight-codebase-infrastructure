# SFTP on AWS: Transfer Family vs Self-Managed EC2

A brief comparison to help decide which approach fits a given client engagement.

## TL;DR

- **Pick AWS Transfer Family** when reliability, compliance, and reduced operational burden matter more than monthly spend.
- **Pick self-managed EC2** only when cost is the primary constraint, traffic is predictable, and the team is comfortable owning patching and HA.

---

## AWS Transfer Family

Fully managed SFTP/FTPS/FTP service backed by S3 or EFS.

### Benefits

- **Zero server management.** No OS patching, no OpenSSH CVEs to chase, no capacity planning.
- **Native S3 integration.** Files land directly in S3, so versioning, lifecycle policies, replication, KMS encryption, and event triggers (Lambda, EventBridge) all work out of the box.
- **Built-in high availability.** Multi-AZ by default. No load balancer or failover engineering required.
- **Flexible authentication.** Service-managed users, AWS Managed Microsoft AD, or a custom identity provider via Lambda/API Gateway for SSO or database-backed auth.
- **Logical directories.** Map each user to their own S3 prefix without exposing bucket structure.
- **Compliance-friendly.** CloudTrail, CloudWatch Logs, structured audit logs, FIPS endpoints, and HIPAA/PCI/SOC eligibility.
- **VPC endpoint support.** Run private-only with security groups and Network ACLs, or expose publicly with IP allow-lists.
- **Workflows.** Post-upload processing (virus scan, decryption, tagging, copy/move) without writing your own daemon.

### Drawbacks

- **Cost floor.** ~$0.30/hour per enabled protocol endpoint (~$216/month) just to keep it running, plus $0.04/GB transferred. Idle endpoints still bill.
- **Less protocol customization.** You configure what AWS exposes. Custom SSH banners, exotic ciphers, or chroot tricks are constrained to the supported security policies.
- **Per-user limits.** Soft quotas on concurrent users and sessions per endpoint. Heavy fan-out may need multiple endpoints.
- **Vendor lock-in.** Migration off Transfer Family means rebuilding auth and workflows elsewhere.

---

## Self-Managed EC2 (OpenSSH or sftpgo)

EC2 instance running OpenSSH or [sftpgo](https://github.com/drakkan/sftpgo), with EBS or S3-backed storage.

### Benefits

- **Low cost at small scale.** A t4g.small with EBS and an Elastic IP runs ~$15-25/month. Big difference for cost-sensitive clients.
- **Full control.** Any cipher, banner, chroot config, custom PAM module, or quota system you want.
- **Flexible storage.** Local EBS, EFS, or mount S3 with mountpoint-s3 or s3fs depending on access patterns.
- **Easy lift-and-shift.** If migrating from an on-prem SFTP, the config often ports directly.
- **No per-protocol hourly fee.** Pay for the instance whether 1 user or 100 connect.

### Drawbacks

- **You own everything.** Patching, kernel upgrades, OpenSSH CVEs, log rotation, monitoring, alerting, backups.
- **HA is your problem.** Single instance is a single point of failure. True HA means an NLB, multiple instances, shared storage, and session handling - which erodes the cost advantage.
- **Auth integration is manual.** AD or SSO means installing SSSD, realmd, or a custom PAM stack and maintaining it.
- **Compliance overhead.** Audit logging, file integrity monitoring, and evidence collection all need to be wired up by hand.
- **Scaling is lumpy.** Vertical scaling means downtime; horizontal scaling means rearchitecting around shared state.
- **Security blast radius.** A misconfigured sshd or stale package becomes the client's incident.

---

## Side-by-side

| Dimension | Transfer Family | Self-Managed EC2 |
|---|---|---|
| Monthly base cost | ~$216 + data | ~$15-50 |
| Patching | AWS handles | You handle |
| HA | Built in | DIY |
| S3 integration | Native | Via mountpoint-s3/s3fs |
| AD/SSO | Native connectors | Manual setup |
| Audit logging | CloudWatch + CloudTrail | Configure yourself |
| Custom SSH config | Limited | Full |
| Time to deploy | Hours | Days for a hardened build |
| Operational toil | Minimal | Ongoing |

---

## Cost break-even

Transfer Family pays for itself once any of these is true:

- Client requires multi-AZ HA (a 2-instance EC2 setup with NLB is already $60-80/month before management time).
- Compliance requires documented patching, audit logs, and evidence collection.
- The team's hourly rate makes a few hours/month of EC2 maintenance more expensive than the Transfer Family premium.
- Uptime SLAs are part of the engagement.

A rough rule: under ~10 hours/year of ops attention, Transfer Family wins on total cost of ownership for most managed-service engagements.

---

## Recommendation for client work

Default to **Transfer Family**. The premium buys reduced risk, faster delivery, and a clean compliance story - all things that matter more in a client engagement than the raw AWS bill. Reserve self-managed EC2 for cases where the client has explicitly traded support burden for cost savings, or where requirements fall outside what Transfer Family supports.
