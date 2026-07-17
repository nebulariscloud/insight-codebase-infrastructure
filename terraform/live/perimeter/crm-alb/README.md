# crm-alb (Perimeter)

Dedicated internet-facing ALB fronting the ICC CRM APIs. Sibling of
`webapps-alb` — same ingress VPC, same cross-VPC-over-TGW pattern.

Both APIs run on the **same** box (`insight-ubuntu-dev`, `10.12.1.71` in
shared-prod), on different ports:

| Hostname | Port | Target group |
|---|---|---|
| `crm.insightgrouppr.com` | `10.12.1.71:80` (prod API) | module default TG |
| `crm-dev.insightgrouppr.com` | `10.12.1.71:81` (dev API) | `crm-alb-dev-tg` |

Host-header rules on the listener split the two. Targets are IP-type with
`availability_zone = "all"` because they live in another VPC (shared-prod) via
the TGW.

## TLS is a two-step apply (external DNS)

`insightgrouppr.com` DNS is managed **outside Route53**, so Terraform can't
create the ACM validation records or the traffic records. An ELB HTTPS listener
can only attach an **issued** cert, so:

### Step 1 — first apply, HTTP-only
`enable_https = false` (the committed default). CI applies:
- ALB + SG + both target groups + both attachments + host rules on the **HTTP** listener
- ACM cert for `crm` + `crm-dev` in **PENDING_VALIDATION**

Then read the outputs and hand them to whoever runs `insightgrouppr.com` DNS:
- `acm_validation_records` — add each as a **CNAME** (name → value). Cert → **ISSUED** (minutes).
- The API is reachable over **HTTP** at `alb_dns_name` immediately for wiring/testing.

### Step 2 — flip HTTPS on
Once the cert shows ISSUED, set `enable_https = true` and re-apply:
- HTTPS (443) listener attaches with the cert; HTTP redirects to HTTPS
- Host rules move to the HTTPS listener

Then point both hostnames at the ALB (CNAME → `alb_dns_name`), per the
`dns_setup_instructions` output.

## Health checks

Health check is `GET /` expecting `200,301,302`. If the ICC APIs return
something else at the root (e.g. `404` when healthy, or a `/health` path),
adjust `health_check_path` / `health_check_matcher`. Until the app is actually
listening on `:80` and `:81`, targets show **unhealthy** — expected.

## Notes

- No `aws_acm_certificate_validation` resource on purpose — it would block
  apply waiting on DNS records Terraform doesn't control.
- Deletion protection is on. WAF is optional (`waf_web_acl_arn`).

## See also

- `webapps-alb/` — the pattern this leaf follows (dedicated ALB, TGW IP targets)
- `../../production/icc-crm-backend/` — the data plane these APIs use
- `../../production/insight-ubuntu-dev/` — the box the APIs run on (`10.12.1.71`)
