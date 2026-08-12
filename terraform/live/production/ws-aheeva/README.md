# WS Aheeva (Production / shared-prod) — Wave 2

Lift-and-shift of the WS Aheeva file-loader from the source tenant
(`254422596287` / `us-east-1`, `i-025bede8c30dbcece`, `172.30.2.200`) into
`shared-prod` / `us-east-2`.

WS Aheeva is the box **clients drop daily files onto over FTPS**; it processes
them and writes into the RDS (`iccmaindb`). It is the disk-mutable, client-
facing member of the cluster, so it migrates in **Wave 2** and cuts over with
the RDS.

## Source facts

| Fact | Value |
|---|---|
| Source instance | `i-025bede8c30dbcece`, `t3a.medium` |
| Root volume | `vol-0e72a3800ccb08eec`, 80 GiB gp2, **encrypted (aws/ebs — unshareable)** |
| Source AMI | `ami-0f38562b9d4de0dfe` — ⚠️ **deregistered, no longer exists.** Irrelevant: we build a fresh AMI from the running instance. Check product codes on the **instance**, not this. |
| File-drop | **FTPS**: control 990 (implicit TLS) + passive 40000-40500 |
| Source SG | `sg-0236c297e78a62ab2` (WebServerAWS) — full inventory below |
| DB role | Writes to `iccmaindb`; also a 3306 client of it |
| Platform | ✅ **Windows.** `Platform: windows`, `PlatformDetails: Windows`, `ProductCodes: []`, root `/dev/sda1`, single volume. Confirmed on the instance 2026-08-07. |

## This is a Windows box — read this before anything else

The only Windows server in the migration. Everything else in this cluster is Linux, so
several habits from the other leaves do not transfer.

**Licensing carries over cleanly.** `PlatformDetails` is `Windows`, not `Windows BYOL`,
so the license is included in the AMI and travels with the `copy-image`. Nothing to
arrange. Do budget for it though — a License Included Windows instance costs
meaningfully more per hour than the same size running Linux, and this is a `t3a.medium`
running 24/7.

**`key_name` is meaningless here, and `get-password-data` will not help you.** That
mechanism only produces a password on AMIs prepared with Sysprep/EC2Launch. This is a
lift-and-shift of a live box, so **the existing Windows credentials come across in the
image** and are the only way in. Get the current local Administrator password from the
client *before* cutover, not during it.

**If the box is domain-joined, check that first.** A domain-joined server that lands in
a VPC with no path to a domain controller will refuse domain logins, and you will be
locked out unless a working *local* administrator account exists. Verify on the source:
```powershell
(Get-WmiObject Win32_ComputerSystem).PartOfDomain
```
If `True`, confirm a local admin account works before taking the final AMI.

**Access path is SSM, and no ingress rule is needed for it.** The SSM agent ships on
Windows Server AMIs and normally survives a lift-and-shift, so this box has a better
chance of arriving SSM-manageable than the Linux ones did. For the GUI — which you will
want, because the FTP config is far easier there — use SSM port forwarding rather than
opening 3389:
```bash
aws ssm start-session --region us-east-2 --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["13389"]}'
# then RDP to localhost:13389
```
That tunnels over the agent's outbound connection, so `3389` stays closed in the
security group. The leaf's `eice_security_group_id` variable opens port **22** and is
therefore useless here — leave it unset.

**⚠️ Windows Firewall is a second, invisible firewall.** This is the failure most likely
to eat an afternoon. The security group can be perfect and FTPS still silently blocked
inside the OS. Worse, the NLB SNATs, so traffic arrives from NLB private IPs in
`10.0.0.0/20` rather than the client public IPs — **any Windows Firewall rule or IIS FTP
IPv4-address-restriction scoped to those client IPs will stop matching.** Audit and fix
before testing, not after:
```powershell
Get-NetFirewallRule -Enabled True | Where-Object { $_.Direction -eq 'Inbound' } |
  Get-NetFirewallPortFilter | Where-Object { $_.LocalPort -match '990|400' }
Get-NetFirewallRule -DisplayName '*FTP*' | Get-NetFirewallAddressFilter
```

**The FTPS server is IIS FTP or FileZilla Server, not vsftpd.** See runbook Part 3 for
the passive-range procedure for each. Both need the passive range narrowed to
`40000-40019` *and* an external-IP setting pointed at the NLB's public IP.

## Source security group — full inventory (read 2026-08-07)

`sg-0236c297e78a62ab2`. This is the design input for the new SG, and it is **not**
copied wholesale. Recorded here because it is the kind of thing nobody re-derives
under cutover pressure.

| Port | Sources | Carried over? |
|---|---|---|
| **990** (FTPS control) | 8 /32s: Insight WNet `64.89.2.20`, QNAP217 `64.89.2.21`, Insight FiberX `154.64.223.34`, Insight Liberty `24.139.143.242`, HCS `162.246.173.122`, Accepta PY `20.75.27.51` + `104.209.183.94`, Gonzalo `97.102.155.98` | **Yes** — at the NLB SG, same 8 |
| **40000-40500** (FTPS passive) | Same 8 /32s | **Yes, narrowed to 40000-40019** |
| **8081** | `10.0.100.0/24` ("Aheeva-srv-wsIF") + **`0.0.0.0/0`** + Gonzalo | **Partly** — CTI v7 only (`10.12.0.42/32`). The world-open rule is not carried. |
| **8025** | **`0.0.0.0/0`**, no description | **No** — purpose unknown, not reproducing a world-open port |
| **8078** | `34.239.135.131` ("GQA test") | **No** — looks like a test fixture; confirm before adding |
| **3389** (RDP) | 5 admin /32s | **No** — use SSM. If Windows and RDP is unavoidable, tunnel it via SSM port forwarding |
| **22** (SSH) | 8 CIDRs of Five9 ("F9") Santa Clara + Atlanta space, including a `/19` | **No** — third-party vendor access, needs an owner and a justification first |
| **all traffic** (`-1`) | 16 sources: QNAP217, Aheeva V8 `54.89.207.172`, Aheeva_DEV_8-6 `3.217.85.105`, Aheeva dev local `10.0.1.92`, InConcert `38.130.241.177` + `179.6.4.123`, ALF `3.92.107.195` + `52.54.91.163`, gqa_otva `108.188.17.180`, WNet Colo `23.249.138.106`, Kennedy `64.89.2.105`, FiberX `154.64.223.34`, **CTI v7 subnet `10.0.100.0/24`**, **CTI v7 old public IP `54.152.253.96`**, Gonzalo, Alex | **No** — the legacy sprawl rule |

### The two things this table changes

**`8081` is load-bearing and easy to miss.** `10.0.100.0/24` is CTI v7's subnet in the
source (it sits at `10.0.100.227`), and the rule is described `Aheeva-srv-wsIF` — so
CTI v7 calls WS Aheeva's web-service interface on 8081. Miss it and the cluster is
broken in a way that FTPS testing will never surface. CTI v7 is `10.12.0.42` here.

**The all-traffic rule hides the real port list.** Because CTI v7's subnet and its old
public IP are both inside it, 8081 could be one of several ports CTI v7 actually uses —
the specific 8081 rule may just be a leftover from before the blanket rule existed.
Same exercise the DB's 18-IP list needed: every entry gets an owner, a port and a
yes/no. Until that is done, treat the port list here as provisional.

### Client IP visibility

The NLB SNATs (`preserve_client_ip = false`), which is not optional — the target is
cross-VPC over the TGW, so preserving the client IP would make WS Aheeva reply via its
own default route instead of back through the NLB, and the connection would hang. The
consequence is that **WS Aheeva's FTPS logs will show NLB private IPs, not client
addresses.** For a file-drop service where "who sent this file" matters, lean on the
authenticated FTPS username for attribution — which is the better identity anyway — and
know that per-client IP ACLs configured *inside* the FTPS server will no longer match.

## What this leaf owns

- One EC2 instance from the migrated AMI (private, no public IP).
- Instance SG: FTPS control + passive from the perimeter ingress NLB CIDR, plus
  optional extra Aheeva app/admin ports scoped to admin CIDRs.
- Optional EICE admin SSH.

## What this does NOT own

- The FTPS ingress NLB — sibling leaf `terraform/live/perimeter/ws-aheeva-ftps-nlb/`.
- The RDS (`terraform/live/production/iccmaindb/`).
- The AMI copy (one-time, transfer-CMK dance — below).

## Prerequisite — AMI via transfer-CMK re-encrypt (source is aws/ebs)

The source root volume is encrypted with `aws/ebs` (AWS-managed, unshareable), so a
plain cross-account share fails. The transfer CMK from the osTicket migration —
`e861c20e-209b-4a96-a184-10cf2e3c0c0d`, confirmed **CUSTOMER-managed and Enabled** on
2026-08-07 — is reused rather than creating a third one.

**The full procedure lives in `docs/07-Operations/cti-v7-wave2-runbook.md` Part 2**,
which was rewritten on 2026-08-07 to use `copy-image` instead of
`copy-snapshot` + `register-image`. Short version:

1. `create-image` from `i-025bede8c30dbcece` with `--no-reboot`.
2. `copy-image` **same-region** with `--encrypted --kms-key-id <transfer CMK>` — this
   re-encrypts *and* carries every boot attribute and block device mapping.
3. Share three things, not one: the AMI's launch permission, `createVolumePermission`
   on each snapshot, and a transfer-CMK key policy granting Production `DescribeKey`,
   `Decrypt`, `ReEncrypt*`, `CreateGrant`.
4. From Production, `copy-image --source-region us-east-1` with the LZA EBS key.

Put the resulting AMI ID in `terraform.tfvars`.

> **Do not pre-flight the product code against `ami-0f38562b9d4de0dfe`** — it has been
> deregistered and `describe-images` returns nothing for it. Query the running instance
> instead:
> ```bash
> aws ec2 describe-instances --region us-east-1 --instance-ids i-025bede8c30dbcece \
>   --query 'Reservations[].Instances[].{Codes:ProductCodes,Platform:Platform,PlatformDetails:PlatformDetails,Root:RootDeviceName,BDMs:BlockDeviceMappings[].DeviceName}' \
>   --output json | cat
> ```
> The July inventory recorded this instance as having no product code, so `copy-image`
> should work — but the instance is the authoritative source, and `Platform` answers
> the Windows question at the same time.

> **Mutable disk:** WS Aheeva's inbox changes as clients drop files. Take the
> FINAL AMI at the cutover window AFTER pausing client sends and draining the
> queue, so no in-flight file is lost. A baseline AMI can be made earlier to
> pre-stage, but the authoritative one is at cutover.

## Cutover (with the RDS)

1. Tell FTPS clients to pause sends; drain the inbound queue on the source.
2. Take the final AMI (above), deploy this leaf.
3. Point WS Aheeva's DB connection at the promoted `iccmaindb` endpoint
   (config edit inside the box, over SSH/SSM).
4. Apply the FTPS NLB leaf; give clients the NLB endpoint + allowlist the NLB's
   public IPs; they resume sends.
5. Verify a test file lands and processes end-to-end into the new RDS.

## FTPS client coordination

The eight FTPS clients must be told the new endpoint, and must allowlist the NLB's
public IPs for their own **outbound** traffic — **both** of them, since the NLB spans two
AZs while the FTPS server can only advertise one address in its `PASV` replies.

Their source CIDRs live in `allowed_source_cidrs` in the **NLB leaf**, not here. This
leaf has no client-IP variable on purpose: the NLB SNATs, so this instance never sees a
client address — only NLB private IPs from `ingress_vpc_cidr`. Any client-IP allowlist
configured here, or inside the FTPS server, would match nothing.

## See also

- `terraform/live/perimeter/ws-aheeva-ftps-nlb/` — the FTPS ingress NLB
- `terraform/live/production/iccmaindb/` — the RDS this box writes to
- `terraform/live/production/webapps-php73/` — the transfer-CMK AMI pattern
- `cti-v7-cluster-migration-plan.md` — overall plan
