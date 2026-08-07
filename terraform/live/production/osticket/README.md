# osTicket (Production / shared-prod)

Migration of the Lightsail instance `osticket1` out of the source tenant into
`shared-prod` / us-east-2. Private instance, Apache on 80, fronted by an ALB in
the Perimeter account over the TGW.

Follows `lightsail-migration-guide.md` (osTicket is server #3 in its inventory).

## Source → destination

| | Source (Lightsail, us-east-1) | Destination |
|---|---|---|
| Instance | `osticket1` | `t3a.micro` |
| Spec | 512 MB / 2 vCPU / 20 GB | 1 GB / 2 vCPU / 20 GB gp3 |
| Address | static IP `204.236.253.33` | private `10.12.1.67`, no public IP |
| Inbound | Lightsail firewall | ALB in Perimeter → IP target over TGW |
| Outbound | Lightsail-managed | TGW → egress NAT (`3.151.88.5`, `3.133.15.33`) |
| Admin | SSH | SSM Session Manager (verify the agent — see below) |
| Disk encryption | `aws/ebs` (AWS-managed) | LZA EBS key |

## AMI provenance

```
Lightsail osticket1
  └─ create-instance-snapshot  osticket1-export-1
     └─ export-snapshot        → ami-00eabb892818fe746 / snap-008eb67444ffc1818
                                 (source tenant, encrypted with aws/ebs — NOT shareable)
        └─ copy-snapshot re-encrypted to transfer CMK e861c20e-209b-4a96-a184-10cf2e3c0c0d
           → snap-0de2c604079d26516, shared to Production 395516496764
           └─ copy-snapshot us-east-1 → us-east-2, re-encrypted with the LZA EBS key
              → snap-04d151958cfa98c62
              └─ register-image → ami-069893c2d380d4dfb   ← what this leaf uses
```

Verified on the final AMI: `State: available`, `ProductCodes: none`,
`/dev/xvda`, `x86_64`, ENA true, sriov simple, boot mode null.

> The `aws/ebs` key is AWS-managed and cannot be shared cross-account, hence the
> transfer-CMK hop. Same wall `webapps-php73` and `ws-aheeva` hit — identical key
> `6e7aced8-e4e6-4060-8b71-b00099d5412f`.

## After apply — do these

1. **Verify SSM registration.** Migrated AMIs have repeatedly arrived without a
   working agent (the `webapps` box at `.65` still has none):
   ```bash
   aws ssm describe-instance-information --region us-east-2 \
     --filters "Key=InstanceIds,Values=<new-id>" --output table | cat
   ```
   If empty, install the agent inside the OS before relying on Session Manager.

2. **Confirm the app comes up** on port 80 and that Apache/MySQL client config
   survived the move.

3. **Leave the DB pointing at the SOURCE.** osTicket writes to `iccmaindb`, and
   the destination DB is a read-only replica until cutover. Its config is
   `include/ost-config.php`. A read-only reachability test against the
   destination is fine and useful:
   ```sql
   SELECT 1; SELECT NOW();
   ```

4. **osTicket's cron.** Mail fetching depends on a cron entry that ships in the
   AMI. Confirm it is still scheduled and that outbound IMAP/SMTP works — the
   source IP changed, so any mail provider allowlisting the old Lightsail IP
   needs updating.

5. **Register with an ALB** (separate Perimeter leaf — see below), then DNS.

## ALB placement — decision needed

Two options in Perimeter:

- **Dedicated `osticket-alb` leaf**, modelled on `terraform/live/perimeter/crm-alb/`.
  That leaf has a working staged-TLS flow (apply HTTP-only → ACM cert validates →
  set `enable_https = true`). Clean ownership, own hostname and health check.
  Costs an extra ALB (~$16–20/month).
- **Add a target group + host rule to the LZA-managed shared `ingress-alb`**
  (`aws-accelerator-config/custom-stacks/ingress-alb.yaml`). No extra ALB cost,
  but the ALB is CloudFormation-managed while the target group would be
  Terraform — one logical thing split across two tools.

Note there is no `webapps-alb` leaf despite references to it elsewhere; it was
never committed.

## Gotchas encoded here

- `monitoring = false` — `ec2:MonitorInstances` is absent from the
  TerraformExecution allow-policy; leaving it on fails the apply with
  `UnauthorizedOperation`.
- `.gitignore` carries `!terraform.tfvars` to override the root `*.tfvars`
  ignore, or CI fails with "Given variables file terraform.tfvars does not exist".
- `private_ip` is pinned and was verified free — a previous leaf hit
  `InvalidIPAddress.InUse` on `10.12.1.60`.
- The backend state key is `live/production/osticket/terraform.tfstate`. When
  copying a leaf, changing this is the single most important edit — sharing a key
  would have this leaf take over another's state.

## Rollback

The source Lightsail instance is untouched and still serving. Before DNS cutover,
rollback is simply "don't flip DNS" and destroy this leaf. The Lightsail snapshot
`osticket1-export-1` remains in the source tenant as the long-term artifact.
