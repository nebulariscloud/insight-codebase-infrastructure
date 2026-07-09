# Webapps ALB (Perimeter) — dedicated ALB for the CTI v7 cluster webapps

A **dedicated** internet-facing Application Load Balancer for this cluster's two
web apps. Deliberately separate from the shared `ingress-alb` so the cluster
owns its own routing, WAF, and access logs and can be managed/torn down
independently.

## What this owns

- A dedicated ALB + its security group (80/443 from `allowed_source_cidrs`).
- Two target groups (IP targets, cross-VPC over TGW to shared-prod):
  - default = **webapps server** (`../../production/webapps`)
  - **webapps php7.3** (`../../production/webapps-php73`)
- HTTP→HTTPS redirect + HTTPS listener (needs an ACM cert).
- Two host-header listener rules routing each hostname to its target group.

## What this does NOT own

- The webapp EC2 instances (the `production/webapps*` leaves).
- DNS records (create A-alias records pointing both hostnames at `alb_dns_name`).
- The ACM certificate (create/import in ACM us-east-2, Perimeter account).

## Order of operations

1. Apply `production/webapps` and `production/webapps-php73` first.
2. Grab each `private_ip` output → put in this leaf's tfvars
   (`webapps_server_private_ip`, `webapps_php73_private_ip`).
3. Ensure an ACM cert covering both hostnames exists in us-east-2 (Perimeter);
   put its ARN in `certificate_arn`.
4. Apply this leaf.
5. Create Route53 (or external DNS) A-alias records:
   `webapps.<corp>` and `php73.<corp>` → `alb_dns_name` (`alb_zone_id`).

## Notes

- Backends serve plain HTTP on `target_port` (80); TLS terminates at the ALB.
  If the apps must be reached over HTTPS end-to-end, set `target_protocol` in
  the module call to HTTPS and adjust `target_port`.
- IP targets use `availability_zone = "all"` because the backends live in
  shared-prod (another VPC) reached via TGW — same pattern as `sftp-nlb`.
- If `certificate_arn` is empty the HTTPS listener and host-header rules are
  skipped and the ALB serves plain HTTP via the default target group (webapps
  server only). Provide a cert for real use.

## See also

- `terraform/live/perimeter/sftp-nlb/` — sibling perimeter ingress leaf (TGW IP-target pattern)
- `terraform/modules/alb/` — the ALB module this uses
- `terraform/live/production/webapps/`, `.../webapps-php73/` — the backends
