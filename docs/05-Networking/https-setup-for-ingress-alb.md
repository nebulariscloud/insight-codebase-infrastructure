# HTTPS Setup for the Ingress ALB

This guide walks through getting a publicly trusted HTTPS certificate on the ingress ALB using AWS Certificate Manager (ACM) and a domain the client owns. Once complete, applications behind the ALB are reachable at `https://<your-domain>` with no browser warnings, automatic certificate renewal, and proper session cookie handling.

## Prerequisites

- A domain the client owns (registered anywhere — Route 53, GoDaddy, Cloudflare, Namecheap, etc.)
- Access to the domain's DNS settings (to add a validation record)
- Access to the **Perimeter account** (where the ALB lives)
- The ALB already deployed (DNS: `ingress-alb-122459471.us-east-2.elb.amazonaws.com`)

## Decision: subdomain or apex domain

Decide what you want users to type in the browser:

| Option | Example | Notes |
|---|---|---|
| Subdomain | `wazuh.example.com` | Cleanest. Each app gets its own subdomain. Recommended. |
| Apex domain | `example.com` | Only works if the apex isn't already used for a website. Requires Route 53 alias records. |
| Wildcard | `*.example.com` | One cert covers all subdomains. Useful if multiple apps will share the ALB. |

This guide uses `wazuh.example.com` as the working example. Replace with your real subdomain.

## Step 1 — Request the certificate (ACM, Perimeter account)

1. Sign in to the **Perimeter account**, region **us-east-2**
2. Go to **AWS Certificate Manager** → **Request certificate**
3. Choose **Request a public certificate** → Next
4. Fully qualified domain name: `wazuh.example.com`
   - Add `*.example.com` as an additional name if you want a wildcard
5. Validation method: **DNS validation** (preferred — auto-renews)
6. Key algorithm: **RSA 2048** (default, fine for ALB)
7. Tags (optional): `Accelerator = AWSAccelerator`
8. **Request**

The certificate enters **Pending validation** status.

## Step 2 — Validate the domain

ACM gives you a CNAME record per domain to add to your DNS provider.

1. Click into the new certificate
2. In the **Domains** section, you'll see a CNAME name and CNAME value, e.g.:
   ```
   Name:  _abc123def456.wazuh.example.com.
   Value: _xyz789.acm-validations.aws.
   ```

### If the domain is on Route 53 (any AWS account)

Click **Create records in Route 53** — ACM creates the CNAME automatically. Skip to Step 3.

### If the domain is on a third-party provider

Log into the DNS provider and add a CNAME:

| Field | Value |
|---|---|
| Type | CNAME |
| Name/Host | `_abc123def456.wazuh` (provider may strip the domain part) |
| Value/Target | `_xyz789.acm-validations.aws.` |
| TTL | 300 (or default) |

Save. Validation typically completes in 5-30 minutes.

## Step 3 — Wait for "Issued"

Refresh the ACM page. When status flips from **Pending validation** to **Issued**, copy the certificate ARN. It looks like:

```
arn:aws:acm:us-east-2:713939170920:certificate/abc12345-6789-0abc-def0-1234567890ab
```

## Step 4 — Add the cert ARN to LZA config

Edit `thenew-aws-accelerator-config/customizations-config.yaml`:

Find the commented-out lines:

```yaml
# - name: CertificateArn
#   value: arn:aws:acm:us-east-2:PERIMETER_ACCOUNT_ID:certificate/your-cert-id-here
```

Uncomment and replace with the real ARN:

```yaml
- name: CertificateArn
  value: arn:aws:acm:us-east-2:713939170920:certificate/abc12345-6789-0abc-def0-1234567890ab
```

## Step 5 — Push to LZA and run the pipeline

```bash
cd /Users/alexgonzdev/Downloads/lza-universal-config-hub-and-spoke-v1.1.0/thenew-aws-accelerator-config && zip -r ../aws-accelerator-config.zip . -x ".*" -x "__MACOSX/*" -x ".DS_Store"
```

Upload the zip to the LZA config S3 bucket (or push to CodeCommit if you're on the git workflow), then trigger the pipeline.

When the pipeline finishes, the ALB will have:
- An **HTTPS:443 listener** with the new cert
- An updated **HTTP:80 listener** that auto-redirects to HTTPS
- The same target group routing as before

## Step 6 — Point the domain at the ALB

The cert validates that you own the domain. Now you tell DNS where the domain should resolve to.

### If using Route 53

1. Route 53 → Hosted zones → click the zone for `example.com`
2. **Create record**
3. Record name: `wazuh`
4. Record type: **A**
5. **Alias**: enable
6. Route traffic to: **Alias to Application and Classic Load Balancer**
7. Region: **us-east-2 (Ohio)**
8. Load balancer: select `ingress-alb`
9. Save

### If using a third-party DNS provider

Third-party providers can't do AWS aliases, so use a CNAME:

| Field | Value |
|---|---|
| Type | CNAME |
| Name/Host | `wazuh` |
| Value | `ingress-alb-122459471.us-east-2.elb.amazonaws.com` |
| TTL | 300 |

Save.

> **Note on apex domains:** Most third-party DNS providers can't CNAME the apex (`example.com` itself). If you need the bare apex pointing at the ALB, transfer DNS hosting to Route 53 and use an alias record. Subdomains have no such restriction.

## Step 7 — Test

After DNS propagates (1-15 minutes):

```bash
dig wazuh.example.com
```

Should return the ALB's IPs.

Open in browser:

```
https://wazuh.example.com
```

You should see the application with a **valid certificate** (lock icon, no warnings).

## Step 8 — Re-secure the Wazuh session cookie

If you previously set `opensearch_security.cookie.secure: false` to log in over HTTP, revert it now:

1. SSM → Session Manager → start session on the Wazuh instance
2. ```bash
   sudo nano /etc/wazuh-dashboard/opensearch_dashboards.yml
   ```
3. Change `opensearch_security.cookie.secure: false` to `true` (or remove the line)
4. ```bash
   sudo systemctl restart wazuh-dashboard
   ```

The cookie now requires HTTPS, which the ALB now provides.

## Adding a second app on a different subdomain

Once the cert is in place, exposing more apps under the same domain is just listener rules. Per app:

1. ACM → request a cert for the new subdomain (e.g., `grafana.example.com`)
2. Validate via DNS as before
3. ALB → Listeners → HTTPS:443 → **Manage listener** → **Add certificate**
4. Add a host-header rule: `grafana.example.com` → forward to the Grafana target group
5. DNS: CNAME `grafana` → ALB DNS

You can attach **up to 25 certificates per ALB** (more with quota increases) and use SNI to serve multiple domains from the same listener.

### Easier option: wildcard cert

If you'll have many subdomains, request `*.example.com` once. The ALB serves any `<anything>.example.com` from the same cert. You only manage host header rules going forward, not certs.

## Troubleshooting

| Symptom | Fix |
|---|---|
| ACM stuck on "Pending validation" for hours | DNS record wrong or not propagated. Verify with `dig _abc123.wazuh.example.com CNAME` — should return the `acm-validations.aws.` value |
| Browser says "certificate not trusted" | DNS still resolving to old endpoint. Wait or flush DNS cache (`sudo dscacheutil -flushcache` on macOS) |
| `ERR_CERT_COMMON_NAME_INVALID` | Cert covers a different domain than what you typed. Re-check ACM cert SANs |
| Pipeline succeeds but ALB still shows HTTP only | `CertificateArn` value typo. Check the ARN matches exactly what ACM shows |
| `502 Bad Gateway` on HTTPS | ALB can't reach backend. Confirm target group health, security group allows `10.0.0.0/20` |
| HTTP works, HTTPS times out | HTTPS listener didn't deploy. Check CloudFormation events for `IngressALB` stack in Perimeter account |

## Cost

- ACM public certificates: **$0**
- ACM auto-renewal: **$0**
- The HTTPS listener: included in ALB pricing (no extra cost vs HTTP listener)
- DNS records: free in Route 53 (other providers vary, typically free)

## Maintenance

Certificates issued via DNS validation auto-renew **forever** as long as the validation CNAME stays in DNS. Don't delete that CNAME — ACM uses it to re-validate ownership before each renewal (~60 days before expiry).

If you ever need to use a different domain, request a new cert and update the `CertificateArn` value in `customizations-config.yaml`. CloudFormation swaps the listener cert in place, no downtime.

## What's deployed at the end

```
User → https://wazuh.example.com
   │
   ▼
[Route 53 / DNS] → resolves to ALB IPs
   │
   ▼
[ALB HTTPS:443 listener] → terminates TLS with ACM cert
   │
   ▼
[Target group] → forwards to Wazuh on 10.12.1.121:443 (HTTPS)
   │
   ▼
[Wazuh dashboard] → returns secure session cookie
```

HTTP requests to the same hostname auto-redirect 301 → HTTPS.
