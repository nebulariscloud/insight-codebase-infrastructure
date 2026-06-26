# Moodle (Production)

Lift-and-shift of the Lightsail Moodle box (`IT-Moodle-LAMP_PHP_8-3-16`, Bitnami LAMP / Debian 12) into `shared-prod` in `us-east-2`. Same stack inside the OS (Apache + PHP-FPM + MariaDB, all from Bitnami); the network around it changes from Lightsail-public to ingress-ALB-private.

## What this leaf creates

- One EC2 instance from the migrated AMI, pinned at `10.12.1.60`.
- A dedicated security group, ingress limited to HTTP from the perimeter ingress VPC CIDR (`10.0.0.0/20`).
- Optional SSH/22 from an EICE endpoint SG (set `eice_security_group_id`).
- First-boot user data that installs `amazon-ssm-agent` (the Bitnami Debian AMI ships without it).

## What this leaf does NOT create

- ALB target group / listener rule — those live in a future `terraform/live/perimeter/moodle-alb/` leaf, paired with this one the same way `sftp-nlb` pairs with `sftp-server`.
- DNS — done at the corp DNS provider once the ALB is live.
- In-OS config changes — `wwwroot`, `sslproxy`, etc. are edited via SSM Session Manager after first boot.

## Build trail for the AMI

| Step | Region | Artifact |
|---|---|---|
| Lightsail instance snapshot (source tenant) | us-east-1 | `snap-02a8e6434c2423dc2` |
| Re-encrypt under shareable CMK (source tenant) | us-east-1 | `snap-0995aaac879dc9155` |
| Cross-region copy + re-encrypt under LZA EBS key | us-east-2 | `snap-0a5eb336adef94c60` |
| `register-image` from destination snapshot | us-east-2 | `ami-0650031d536e756ab` |

Full procedure in [`lightsail-migration-guide.md`](../../../../lightsail-migration-guide.md).

## Apply

```bash
terraform init
terraform plan
terraform apply
```

## Post-apply cutover (one-time, via SSM Session Manager)

```bash
# Connect
aws ssm start-session --region us-east-2 --target <instance-id-from-outputs>

# Inside the instance
sudo -i
nano /opt/bitnami/apache/htdocs/config.php
#   $CFG->wwwroot  = 'https://moodle.<corp>.com';
#   $CFG->sslproxy = true;       # critical: ALB terminates TLS

/opt/bitnami/ctlscript.sh restart apache
curl -I http://localhost/login/index.php   # expect 200 or 303
```

Then add the ALB target group + host-header rule pointing at the `private_ip` output of this stack (`10.12.1.60`), and flip DNS.

## Verifying SSM registered

The Bitnami Debian 12 AMI ships without SSM agent. The user-data installs it on first boot. Wait ~2–3 minutes after apply, then:

```bash
aws ssm describe-instance-information --region us-east-2 \
  --filters "Key=InstanceIds,Values=<instance-id>" \
  --query 'InstanceInformationList[].{Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}' \
  --output table
```

`PingStatus: Online` = good. If it stays empty for >5 min, the user-data didn't run cleanly — the fallback is to use the EICE endpoint (set `eice_security_group_id`) to SSH in and install the agent by hand.

## Decommissioning the source

Leave the Lightsail instance running until at least:

- DNS has cut over and is serving the new ALB
- Outbound integrations have been re-keyed to the new NAT GW EIPs
- The Moodle admin has confirmed at least one full day of normal use

Then stop (don't delete) the Lightsail instance. Keep the Lightsail snapshot for the agreed retention window.
