# LimeSurvey ALB (Perimeter)

Internet-facing ALB in the perimeter ingress VPC that fronts the ICC LimeSurvey
box in [`terraform/live/production/icc-limesurvey/`](../../production/icc-limesurvey/),
reached cross-VPC over the perimeter <-> shared-prod TGW. Same shape as
[`osticket-alb`](../osticket-alb/), minus the ACM cert (interim HTTP-only).

## Interim: HTTP on the ALB's own DNS name, no domain needed

There is no ACM cert yet. With `certificate_arn = ""` the `alb` module's HTTP
listener **forwards** to the backend (it only redirects-to-HTTPS when a cert is
present), so LimeSurvey is reachable **today** at:

```
http://<alb_dns_name>/
```

`alb_dns_name` is an output. No external DNS, no cert, nothing to wait on.

**Survey traffic is unencrypted in transit until a cert is added.** That's
acceptable here only because access is restricted to the partner allowlist
(below) and this is a temporary state until the domain is ready.

## When the domain is ready — add HTTPS

Mirror `osticket-alb`:

1. Add an `aws_acm_certificate` for the hostname (DNS validation), emit the
   validation records as an output.
2. Set the module's `certificate_arn` to the cert ARN and `enable_https = true`.
3. Re-apply. HTTP 301-redirects to HTTPS; point the hostname (CNAME) at
   `alb_dns_name`.

No structural change to this leaf or the production leaf — just the cert + flip.

## Access — partner allowlist

`allowed_source_cidrs` defaults (in `variables.tf`) to the ~30-entry partner
allowlist carried over from the source `webserver` SG's `:443` rule. LimeSurvey
is not a public portal, so the ALB is locked to those sources, not the
internet. The bogus `0.0.0.0/32` entries in the source SG were dropped.

## Architecture

```
partner (allowlisted IP)
  │  HTTP/80  (HTTPS/443 once a cert is added)
  ▼
[ LimeSurvey ALB (Perimeter ingress) ] --WAF
  │  HTTP/80  via TGW
  ▼
[ icc-limesurvey (shared-prod, 10.12.1.83:80) ]
```

## Prerequisite

The `icc-limesurvey` box must be applied first (it prints `private_ip`, pinned
to `10.12.1.83`). Its instance SG already allows :80 from the ingress CIDR.

## Verifying

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)
curl -sI "http://$ALB_DNS/" | head -5   # from an allowlisted source
```

Target health should show the single IP `healthy` (LimeSurvey answers
`GET /` with 200/302 on :80).

## See also

- `terraform/live/production/icc-limesurvey/` — the box this fronts
- `terraform/live/perimeter/osticket-alb/` — the reference ALB leaf (with the cert block to copy when adding HTTPS)
