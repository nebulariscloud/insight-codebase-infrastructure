# ACM Certificate Provisioning and HTTPS Wiring Guide

End-to-end guide for issuing an ACM (AWS Certificate Manager) public certificate
and plugging it into an LZA-managed Application Load Balancer behind AWS Global
Accelerator. Written against the Scriptcase ALB / Scriptcase GA setup but the
flow is identical for any other ALB you front with GA in this org.

---

## Why HTTPS End-to-End

Global Accelerator is a **TCP/UDP layer 4 pass-through**. It forwards bytes; it
does not terminate TLS, does not generate certs, does not understand HTTP. So if
a vendor calls `https://<GA-IP>:443`, the TLS handshake terminates on the **ALB**
sitting behind GA. That means:

- The ALB must have a listener on 443
- The ALB must present a real ACM certificate
- The cert must match the hostname the vendor connects to

Plain HTTP-only is acceptable when the vendor explicitly opted in (rare in 2026
and never recommended for anything sensitive). Default to HTTPS.

---

## Architecture Recap

```
Vendor
  │   https://scriptcase.example.com
  ▼
Global Accelerator (us-west-2 control plane, global data plane)
  │   2 static IPv4 anycast IPs
  ▼
Application Load Balancer (Perimeter / us-east-2)
  │   HTTPS :443 listener with ACM cert
  ▼
Target Group (IP target type)
  │   HTTP :8091 (or whatever Scriptcase listens on)
  ▼
Scriptcase EC2 instance (shared-prod / us-east-2, private IP via TGW)
```

The cert lives **on the ALB** in **us-east-2**. GA passes TLS through unchanged.

---

## Prerequisites

- A DNS hostname you control. Examples:
  - `scriptcase.insightgrouppr.com` (subdomain of an existing Route53 zone)
  - `scriptcase.nebulariscloud.com`
  - Any external DNS provider works the same way
- Access to whatever DNS provider hosts that zone (Route53, Cloudflare, GoDaddy)
- The Scriptcase ALB already deployed in the Perimeter account / us-east-2
  (it is - `scriptcase-lb`, ARN
  `arn:aws:elasticloadbalancing:us-east-2:713939170920:loadbalancer/app/scriptcase-lb/1e9fb498cb0ab723`)
- Access to the Perimeter account's CloudShell or your local AWS CLI configured
  for the Perimeter account

---

## Step 1 - Pick the Hostname

Decide on the public hostname the vendor will call. Two common shapes:

| Pattern | Example | Notes |
|---|---|---|
| Subdomain of corporate domain | `scriptcase.insightgrouppr.com` | Cleanest, professional, easy DNS |
| New apex/subdomain | `scriptcase.app.example` | Fine, requires DNS provisioning |

If the vendor only allowlists IPs (not hostnames), the hostname still matters
because the cert must match the SNI the vendor sends. Most vendors send the
hostname as SNI even when calling an IP literal.

For the rest of this guide assume the chosen hostname is `scriptcase.example.com`.

---

## Step 2 - Request the ACM Certificate

Run from the **Perimeter** account in **us-east-2** (where the ALB lives).
ACM certs are regional - the cert must live in the same region as the ALB.

```bash
aws acm request-certificate \
  --region us-east-2 \
  --domain-name scriptcase.example.com \
  --validation-method DNS \
  --key-algorithm RSA_2048 \
  --tags Key=Name,Value=scriptcase-lb-cert Key=Accelerator,Value=AWSAccelerator
```

Output gives you the cert ARN. Save it:

```bash
CERT_ARN=$(aws acm list-certificates --region us-east-2 \
  --query "CertificateSummaryList[?DomainName=='scriptcase.example.com'].CertificateArn" \
  --output text)
echo $CERT_ARN
```

State will be `PENDING_VALIDATION`. ACM is now waiting for you to prove you
control the domain.

---

## Step 3 - Pull the DNS Validation Record

ACM gives you a CNAME pair (one record) you put in DNS. Once it sees the record,
it issues the cert.

```bash
aws acm describe-certificate \
  --region us-east-2 \
  --certificate-arn $CERT_ARN \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
  --output table
```

You'll get back something like:

```
| Name  | _abc123.scriptcase.example.com.       |
| Type  | CNAME                                 |
| Value | _xyz789.acm-validations.aws.          |
```

Add that exact CNAME at your DNS provider. Two cases:

### Case A - Hostname is in Route53 in this org

If your DNS zone is hosted in Route53 in any account in this org, you can
upsert the validation record from CLI. Run from the account that owns the zone:

```bash
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name example.com. \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')

# Replace <NAME> and <VALUE> with the ResourceRecord from above
cat > /tmp/validate.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "<NAME>",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{ "Value": "<VALUE>" }]
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file:///tmp/validate.json
```

### Case B - DNS is at an external provider

Add the CNAME manually in their UI (Cloudflare, GoDaddy, Squarespace, etc).

---

## Step 4 - Wait for Validation

ACM polls DNS every minute or so. Validation usually completes in 1-5 minutes
once the record propagates.

```bash
aws acm wait certificate-validated \
  --region us-east-2 \
  --certificate-arn $CERT_ARN

aws acm describe-certificate \
  --region us-east-2 \
  --certificate-arn $CERT_ARN \
  --query 'Certificate.Status' --output text
```

Expected: `ISSUED`. If it stays `PENDING_VALIDATION` past 10 minutes, the CNAME
isn't visible publicly. Check with `dig`:

```bash
dig +short CNAME _abc123.scriptcase.example.com
```

That should resolve to the ACM validation host.

---

## Step 5 - Wire the Cert Into the LZA Config

Edit `thenew-aws-accelerator-config/customizations-config.yaml`. Find the
`ScriptcaseLB` block and replace the empty `CertificateArn` parameter:

```yaml
        - name: CertificateArn
          value: arn:aws:acm:us-east-2:713939170920:certificate/<your-cert-id>
```

Commit and push. The next pipeline run will:

1. CFN sees `CertificateArn` is now non-empty
2. The `HasCertificate` condition flips true
3. The `HttpsListener` resource gets created on port 443
4. The `HttpListener` on port 80 switches from "forward to TG" to "redirect to 443"

The ALB is updated in place. No downtime.

---

## Step 6 - Add the Public DNS Record for the Scriptcase Hostname

Now point the hostname at Global Accelerator. GA exposes both a DNS name and
two static IPs - either works. Aliasing to GA gives free DNS-level updates if
GA ever changes its IPs (it won't, but).

Get the GA endpoints:

```bash
# From any account that has a Perimeter or management profile
aws cloudformation describe-stacks --region us-west-2 \
  --query 'Stacks[?contains(StackName,`ScriptcaseGA`)].Outputs' \
  --output json
```

You get back:

- `AcceleratorDnsName` - e.g. `a1b2c3d4e5f6.awsglobalaccelerator.com`
- `AcceleratorIps` - e.g. `99.83.182.10, 75.2.61.40`

### Option A - CNAME the hostname to the GA DNS name (recommended)

```
Type:  CNAME
Name:  scriptcase
Value: a1b2c3d4e5f6.awsglobalaccelerator.com
TTL:   300
```

### Option B - A records pointing to the GA static IPs

```
Type:  A
Name:  scriptcase
Value: 99.83.182.10
       75.2.61.40
TTL:   300
```

Option B is the right choice if the vendor's app refuses to follow CNAMEs (rare).

If your zone is in Route53 you can use an alias record to GA, which behaves
like A records but updates dynamically:

```bash
cat > /tmp/scriptcase-record.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "scriptcase.example.com",
      "Type": "A",
      "AliasTarget": {
        "DNSName": "a1b2c3d4e5f6.awsglobalaccelerator.com",
        "HostedZoneId": "Z2BJ6XQ5FK7U4H",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file:///tmp/scriptcase-record.json
```

Note the `HostedZoneId` value `Z2BJ6XQ5FK7U4H` is the AWS-published hosted-zone
ID for Global Accelerator (constant across all accelerators).

---

## Step 7 - Validate End-to-End

From any laptop (after DNS has propagated, ~5 min):

```bash
# DNS resolves to the GA IPs
dig +short scriptcase.example.com

# TLS handshake completes with the right cert
curl -vI https://scriptcase.example.com 2>&1 | grep -E "subject|issuer|HTTP"

# Cert SAN matches
echo | openssl s_client -connect scriptcase.example.com:443 -servername scriptcase.example.com 2>/dev/null \
  | openssl x509 -noout -text \
  | grep -A1 "Subject Alternative"
```

Expected:
- `dig` returns 2 GA static IPs
- `curl` returns `HTTP/1.1 200` (or whatever Scriptcase serves at `/`)
- TLS subject CN is `scriptcase.example.com`

Then in the **Perimeter** account, confirm the ALB target is healthy:

```bash
aws elbv2 describe-target-health --region us-east-2 \
  --target-group-arn $(aws elbv2 describe-target-groups --region us-east-2 \
    --names scriptcase-lb-tg --query 'TargetGroups[0].TargetGroupArn' --output text) \
  --output table
```

If `unhealthy`, check:
- The Scriptcase EC2 IP is registered as a target (manual step from
  `scriptcase-migration-guide.md` Step 6)
- Scriptcase's SG allows TCP 8091 from `10.0.0.0/20` (the perimeter ingress CIDR)
- Scriptcase actually responds on `/` with status 200 or 302
  (`curl -I http://<scriptcase-ip>:8091/` from anywhere in shared-prod)

---

## Common Pitfalls

| Symptom | Cause |
|---|---|
| `PENDING_VALIDATION` stuck for 10+ min | DNS CNAME not added, or wrong value, or external DNS still propagating |
| `curl` returns `SSL: certificate verify failed` | Hostname mismatch - cert was issued for a different name |
| Vendor sees `connection refused` on 443 | ALB has no HTTPS listener (config not yet applied, or `CertificateArn` still empty) |
| TLS works on IP but fails on hostname | Cert SAN doesn't include the hostname |
| Healthy in TG but vendor times out | Vendor's source IP not getting through. Check WAF metrics, then SG, then NACLs |
| Targets always `unhealthy` | No targets registered. Run elbv2 register-targets per the migration guide |

---

## Adding Additional Hostnames Later

Need `scriptcase-uat.example.com` in addition to `scriptcase.example.com`?

ACM lets you request multi-SAN certs:

```bash
aws acm request-certificate \
  --region us-east-2 \
  --domain-name scriptcase.example.com \
  --subject-alternative-names scriptcase-uat.example.com \
  --validation-method DNS
```

You'll get one CNAME per name to validate. Apply both, wait, swap the cert ARN
in `customizations-config.yaml`, push.

ALB listeners can also have multiple certs - useful when names belong to
unrelated certs. That's a `AWS::ElasticLoadBalancingV2::ListenerCertificate`
resource added to the LB stack. Not needed for the simple single-hostname case.

---

## Renewal

ACM auto-renews public DNS-validated certs as long as:

1. The validation CNAME stays in DNS
2. The cert is associated with at least one AWS resource (the ALB counts)

You'll get a renewal email 45/30/14/7/3 days before expiry. Nothing manual to
do unless ACM can't reach the validation record - then it'll alert and you fix
DNS.

---

## Cost

- **ACM public certs**: free
- **ALB HTTPS listener**: same cost as the ALB itself ($16/mo + LCUs)
- **Global Accelerator**: ~$18/mo per accelerator + per-GB data transfer
- **Route53 hosted zone**: $0.50/zone/mo if you create a new one

For one Scriptcase setup: zero incremental cert cost, the GA is the only added
line item over the LB you already have.
