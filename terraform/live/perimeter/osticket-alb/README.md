# osTicket ALB (Perimeter)

Dedicated internet-facing ALB fronting the osTicket instance in `shared-prod`,
migrated off Lightsail `osticket1`. Modelled on `../crm-alb/`.

```
internet
  → osticket-alb (Perimeter ingress VPC, public subnets)
    → TGW
      → 10.12.1.67:80  (osTicket / Apache, shared-prod-app-a, Production account)
```

Simpler than `crm-alb`: one hostname on one backend port, so the `alb` module's
default target group and listener default action are sufficient. No second
target group, no extra ALB egress rule, no host-header listener rules.

## Companion leaf

`terraform/live/production/osticket/` owns the instance and pins its private IP
to `10.12.1.67`. Apply that one first — this leaf's target attachment points at
that IP.

## Two-stage TLS

The certificate has to be ISSUED before an HTTPS listener can reference it, and
if the DNS zone is external Terraform cannot create the validation records.

**Stage 1 — `enable_https = false`** (current state in `terraform.tfvars`)
- Applies an HTTP-only ALB and creates the ACM cert in `PENDING_VALIDATION`.
- Read the `acm_validation_records` output and add the CNAME to DNS.
- Wait for the cert to reach `ISSUED`:
  ```bash
  aws acm describe-certificate --region us-east-2 \
    --certificate-arn <certificate_arn output> \
    --query 'Certificate.Status' --output text
  ```

**Stage 2 — `enable_https = true`**
- Re-apply. The HTTPS listener attaches and HTTP starts 301-redirecting to it.
- Point the hostname at `alb_dns_name` as a CNAME.

## Before the first apply

- [x] **Confirm `osticket_host`.** Settled on `osticket.insightgrouppr.com` — it
      already has a live A record, so it is the name in use rather than a new one.
      Keep it **lowercase**: ACM normalises the domain name, and a mixed-case
      value makes the `domain_validation_options` map key not match, which shows
      up as a perpetual diff on `acm_validation_records`.
      ⚠️ That A record resolves to `54.84.28.176`, **not** the Lightsail static IP
      `204.236.253.33` recorded in the production leaf. Confirm which box is
      actually serving before the DNS cutover.
- [ ] **Decide `allowed_source_cidrs`.** Defaults to `0.0.0.0/0` because a ticket
      portal is usually public. If it is staff-and-partners only, tighten it —
      ticketing systems are a common target.

## Changing the hostname after an apply

`osticket_host` is the ACM cert's `domain_name`, so editing it **replaces the
certificate**. That is cheap and safe while `enable_https = false` (nothing
references the cert yet) and expensive once the HTTPS listener is live — the
listener would briefly have no valid cert. Do hostname changes in stage 1.

The first apply went out with `tickets.insightgrouppr.com`, which does not exist
in DNS; the follow-up corrected it to `osticket.insightgrouppr.com` and the
`tickets` cert was replaced while still `PENDING_VALIDATION`.

## Cutover

1. Apply the production `osticket` leaf, confirm the app answers on `:80`.
2. Apply this leaf (stage 1), add the validation CNAME, wait for `ISSUED`.
3. Flip `enable_https = true`, re-apply.
4. Verify via the ALB DNS name directly before touching DNS.
5. Drop the existing record's TTL to 60s, then repoint the hostname at
   `alb_dns_name`.
6. Watch `RequestCount` / `HealthyHostCount` on the target group, and Lightsail's
   instance metrics dropping to zero.
7. Only then decommission the Lightsail instance. Keep the snapshot
   `osticket1-export-1`.

## Notes

- **The Lightsail static IP does not transfer.** `204.236.253.33` is a Lightsail
  construct. Inbound allowlists move to this ALB; **outbound** allowlists (mail
  relays, partner APIs) move to the egress NAT EIPs `3.151.88.5` /
  `3.133.15.33`. See `lightsail-migration-guide.md` step 9.
- `availability_zone = "all"` on the target attachment is required because the IP
  target is outside this ALB's VPC (shared-prod via TGW). Without it the
  attachment fails.
- `cross_zone_load_balancing = false` matches `crm-alb` and `sftp-nlb` — the
  backend is cross-VPC so cross-zone would add avoidable inter-AZ transfer.
- Health check allows `301,302` because osTicket's `/` normally redirects.
- Backend state key is `live/perimeter/osticket-alb/terraform.tfstate`. When
  copying a leaf this is the single most important edit — sharing a key would
  have this leaf take over another's state.
