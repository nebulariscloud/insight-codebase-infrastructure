# Webapps ALB (Perimeter)

Internet-facing ALB in the perimeter ingress VPC that reproduces the
source-tenant **WebappsALB** URI routing for `webapps.insightgrouppr.com`,
fronting the two migrated webapp boxes in shared-prod (Production account) over
the perimeter <-> shared-prod TGW. Same shape as [`crm-alb`](../crm-alb/).

## What the source ALB did (and this reproduces)

The source `WebappsALB` (`254422596287` / `us-east-1`) had an HTTPS :443
listener that split by path across two backends:

| Source target group | Source instance | Now | Gets |
|---|---|---|---|
| `abbvieTG` | `i-02a7982851dd09a0b` (webapps php7.3) | `10.12.1.61` | the named app paths |
| `webappsTG` | `i-0fb5b86437a72deb5` (webapps server) | `10.12.1.65` | everything else (`*`) |

Both backends serve plain **HTTP :80**, health check `/healthy.txt` -> `200`.
TLS terminates at the ALB (ACM cert for `webapps.insightgrouppr.com`).

The named app paths routed to php73 (verbatim from the source rules):

```
/island/*  /webhook/*  /abbvie_aheeva/*  /ah_amex/*  /AAA-BI/*
/AAA_Survey/*  /sss_holiday/*  /aaa_aheeva_survey_reports/*  /electric/*
/testing/*  /testing_admin/*  /testing2/*  /ssspq*/*  /sss_agencias_*/*
/clarocrm/*  /aaa_referidos/*  /ehret/*  /aeronet/*
```

These are grouped into ALB listener rules of <= 5 patterns each (ALB's
per-condition limit) in `var.php73_path_groups`. Everything not matching falls
through to the listener default action -> the webapps (catch-all) box, exactly
like the source `*` rule.

### What was dropped

The source had a second HTTPS listener on **:3000** -> a `Grafana` target group
with **zero registered targets**. It served nothing, so it is not reproduced.
If Grafana is later stood up somewhere and needs fronting, add a `:3000`
listener + target group then.

## Architecture

```
client -> https://webapps.insightgrouppr.com
  │  TCP/443 (TLS terminates here)
  ▼
[ Webapps ALB (Perimeter ingress) ] --WAF--+
  │                                          │ path match?
  ├── named app paths ───────────────────────┼──► php73 TG   ──► 10.12.1.61:80  (webapps-php73)
  └── everything else (default action) ──────┴──► webapps TG ──► 10.12.1.65:80  (webapps)
        (both cross-VPC over TGW, target az="all")
```

## TLS staging (same as crm-alb)

`insightgrouppr.com` DNS is external (not Route53), so Terraform can't create
the ACM validation record. Two-step:

1. Apply with `enable_https = false` -> HTTP-only ALB + ACM cert in `PENDING`.
   Read `acm_validation_records`, add the CNAME to the external DNS. Cert ->
   `ISSUED`.
2. Set `enable_https = true`, re-apply -> HTTPS listener + path rules attach,
   HTTP 301-redirects to HTTPS. Point `webapps.insightgrouppr.com` at
   `alb_dns_name`.

While `enable_https = false`, the path rules attach to the HTTP listener so you
can smoke-test routing over HTTP before the cert validates.

## Prerequisites

Both backend boxes must already be applied and reachable on :80:

- `../../production/webapps/` -> `10.12.1.65`
- `../../production/webapps-php73/` -> `10.12.1.61`

Their instance SGs already allow :80 from the ingress VPC CIDR (`10.0.0.0/20`),
so no change to those leaves is needed.

## Verifying

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)

# catch-all -> webapps box
curl -sik "https://$ALB_DNS/" -H "Host: webapps.insightgrouppr.com" | head -5

# a named path -> php73 box
curl -sik "https://$ALB_DNS/clarocrm/" -H "Host: webapps.insightgrouppr.com" | head -5
```

Check target health in the console (or `aws elbv2 describe-target-health`) —
both target groups should show their single IP target `healthy`. If a target is
`unhealthy`, confirm the box answers `GET /healthy.txt` with `200` on :80 and
that its SG allows :80 from `10.0.0.0/20`.

## See also

- `terraform/live/perimeter/crm-alb/` — the reference ALB leaf (host/path rules + ACM staging + WAF)
- `terraform/live/production/webapps/` + `webapps-php73/` — the two backends
- `cti-v7-cluster-migration-plan.md` — the overall cluster plan (Wave 1)
