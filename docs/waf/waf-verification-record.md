# WAF — verification record

Post-deployment verification run by Nebularis Cloud LLC for the Insight Group AWS WAF Implementation SOW (March 2026).

Captures the exact AWS API calls made against the live environment after merge, with the responses observed. Use this as the audit trail for the SOW acceptance.

| Item | Value |
|---|---|
| Environment | Insight Group AWS Organization, Perimeter account `713939170920`, region `us-east-2` |
| Web ACLs in scope | `ingress-alb-waf`, `scriptcase-lb-waf` |
| Verification date | 2026-06-21 |
| Run by | Nebularis Cloud LLC |
| Method | AWS CLI calls executed in the Perimeter account, read-only |

## V1 — WAF logs bucket exists and is properly encrypted

**Command**

```bash
aws s3api get-bucket-encryption \
  --bucket aws-waf-logs-713939170920-us-east-2 \
  --region us-east-2
```

**Result**

```json
{
  "ServerSideEncryptionConfiguration": {
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms",
          "KMSMasterKeyID": "arn:aws:kms:us-east-2:713939170920:key/be1ae97a-dec4-4aef-8e00-ebf0965b6af4"
        },
        "BucketKeyEnabled": true,
        "BlockedEncryptionTypes": {
          "EncryptionType": ["SSE-C"]
        }
      }
    ]
  }
}
```

**Pass criteria met**

- Bucket exists at the expected name (`aws-waf-logs-<account>-<region>`, the WAF-required `aws-waf-logs-` prefix).
- Encryption is `aws:kms` with a dedicated customer-managed CMK (key id `be1ae97a-dec4-4aef-8e00-ebf0965b6af4`), not the AWS-managed `aws/s3` key.
- Bucket key is enabled (cost optimization for KMS calls).
- SSE-C client-supplied keys are blocked.

## V2 — WAF logging is attached to both Web ACLs

**Commands**

```bash
INGRESS_ARN=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
  --query "WebACLs[?Name=='ingress-alb-waf'].ARN | [0]" --output text)

SCRIPTCASE_ARN=$(aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 \
  --query "WebACLs[?Name=='scriptcase-lb-waf'].ARN | [0]" --output text)

aws wafv2 get-logging-configuration --resource-arn "$INGRESS_ARN" --region us-east-2
aws wafv2 get-logging-configuration --resource-arn "$SCRIPTCASE_ARN" --region us-east-2
```

**Result — `ingress-alb-waf`**

```json
{
  "LoggingConfiguration": {
    "ResourceArn": "arn:aws:wafv2:us-east-2:713939170920:regional/webacl/ingress-alb-waf/65a8e9c4-f94b-48a3-b188-6bbe44fd5477",
    "LogDestinationConfigs": [
      "arn:aws:s3:::aws-waf-logs-713939170920-us-east-2"
    ],
    "RedactedFields": [
      { "SingleHeader": { "Name": "authorization" } },
      { "SingleHeader": { "Name": "cookie" } }
    ],
    "ManagedByFirewallManager": false,
    "LogType": "WAF_LOGS",
    "LogScope": "CUSTOMER"
  }
}
```

**Result — `scriptcase-lb-waf`**

```json
{
  "LoggingConfiguration": {
    "ResourceArn": "arn:aws:wafv2:us-east-2:713939170920:regional/webacl/scriptcase-lb-waf/c148f8d2-5198-4718-9dfe-b8cc65af6083",
    "LogDestinationConfigs": [
      "arn:aws:s3:::aws-waf-logs-713939170920-us-east-2"
    ],
    "RedactedFields": [
      { "SingleHeader": { "Name": "authorization" } },
      { "SingleHeader": { "Name": "cookie" } }
    ],
    "ManagedByFirewallManager": false,
    "LogType": "WAF_LOGS",
    "LogScope": "CUSTOMER"
  }
}
```

**Pass criteria met**

- Both Web ACLs have an active logging configuration.
- Both point to the verified bucket from V1.
- Both redact `authorization` and `cookie` headers, so credentials and session tokens never land in the log records.
- `ManagedByFirewallManager: false` confirms Terraform owns the config (not a Firewall Manager policy that could overwrite it).

## V3 — CloudWatch alarms exist and are healthy

**Command**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
  --region us-east-2 \
  --query 'MetricAlarms[].[AlarmName,StateValue]' \
  --output table
```

**Result**

```
+--------------------------------------------------+-----+
|  perimeter-waf-ingress-blocked-total             |  OK |
|  perimeter-waf-ingress-common-ruleset-blocks     |  OK |
|  perimeter-waf-ingress-rate-limit-blocks         |  OK |
|  perimeter-waf-scriptcase-blocked-total          |  OK |
|  perimeter-waf-scriptcase-common-ruleset-blocks  |  OK |
|  perimeter-waf-scriptcase-rate-limit-blocks      |  OK |
+--------------------------------------------------+-----+
```

**Pass criteria met**

- All 6 expected alarms exist (3 alarm types × 2 Web ACLs).
- Naming pattern matches the design: `perimeter-waf-<webacl>-<alarm-type>`.
- Every alarm is in `OK` state, which means CloudWatch is receiving metric data and no threshold has been breached on cold-start. Cold-start `INSUFFICIENT_DATA` would also have been acceptable; `ALARM` would have flagged a threshold sized too tightly. Neither is the case.

## V4 — SNS subscriptions confirmed for all three severity tiers

**Command**

```bash
for sev in high medium low; do
  echo "=== $sev ==="
  TOPIC_ARN=$(aws sns list-topics --region us-east-2 \
    --query "Topics[?contains(TopicArn,'perimeter-waf-${sev}')].TopicArn | [0]" \
    --output text)
  aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region us-east-2 \
    --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
done
```

**Result — high**

```
| insightgroup-security-high@nebulariscloud.com | arn:aws:sns:us-east-2:713939170920:perimeter-waf-high:d8a8b2fe-1f20-42cb-9116-6e69e2a3b592 |
```

**Result — medium**

```
| insightgroup-security-medium@nebulariscloud.com | arn:aws:sns:us-east-2:713939170920:perimeter-waf-medium:cad42902-0c08-42ea-9599-d91643ffa1cd |
```

**Result — low**

```
| insightgroup-security-low@nebulariscloud.com | arn:aws:sns:us-east-2:713939170920:perimeter-waf-low:c2ea33bd-cf55-43ee-887f-91834bb3a8df |
```

**Pass criteria met**

- Three SNS topics exist, one per severity tier.
- Each topic has the matching `insightgroup-security-{high,medium,low}@nebulariscloud.com` distribution list subscribed.
- The `SubscriptionArn` column shows real ARNs, not `PendingConfirmation`. Confirmation links from AWS were clicked before the verification ran, so alarms now have a working email path.

## Verification summary

| Verification | Status |
|---|---|
| V1 — Logs bucket exists, KMS-encrypted, hardened | Pass |
| V2 — Logging attached to both Web ACLs with header redaction | Pass |
| V3 — All 6 CloudWatch alarms exist and healthy | Pass |
| V4 — All 3 SNS topic subscriptions confirmed | Pass |

All four verifications passed on first run. The WAF deployment is operationally live.

## Items not part of this verification

These are deliberately out of scope for this verification document and tracked elsewhere:

- **Traffic baseline capture.** Requires 7 days of dashboard data. Tracked in `docs/waf/waf-traffic-baseline.md`.
- **Threshold narrowing based on baseline.** Follow-up after baseline capture. Default thresholds are intentionally generous to avoid alarm-storm on cold start.
- **PCI Web ACL deployment.** Gated on the PCI account / VPC / cert landing. Template (`aws-accelerator-config/custom-stacks/pci-alb.yaml`) is built and tuned, deployment block in `customizations-config.yaml` is commented out pending pre-reqs.
- **Bot Control rollout.** Module supports it (`enable_bot_control` toggle). Default off — opt-in cost decision per `docs/waf/waf-design-decisions.md` D6.
