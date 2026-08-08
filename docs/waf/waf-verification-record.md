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

> ### ⚠️ V3 CONCLUSION RETRACTED — 2026-08-06
>
> The original text of this section read: *"Every alarm is in `OK` state, which
> means CloudWatch is receiving metric data and no threshold has been breached
> on cold-start."*
>
> **That inference was invalid.** Every alarm in this module sets
> `treat_missing_data = "notBreaching"`, so an alarm watching a metric that
> does not exist also reports `OK`. The observed `OK` state was equally
> consistent with zero metrics, and in fact that is what it was.
>
> **Root cause:** the `waf-monitoring` module specified the CloudWatch
> namespace as `AWS/WAFv2` (lowercase `v`). The real namespace is `AWS/WAFV2`
> (capital `V`) — see the AWS WAF developer guide, *Viewing metrics and
> dimensions*: "The AWS WAF namespace is `AWS/WAFV2`". CloudWatch namespaces
> are case-sensitive, so all six alarms and every dashboard widget resolved
> against a namespace with no metrics in it.
>
> **Impact:** from 2026-06-21 to 2026-08-06 the WAF alarms could not fire under
> any circumstances and the dashboard rendered empty. WAF itself was
> unaffected throughout — traffic was inspected, rules were enforced, and logs
> were delivered normally (V1/V2/V4 all remain valid). The defect was confined
> to the observability layer.
>
> **How it was found:** `aws cloudwatch list-metrics --namespace AWS/WAFv2
> --region us-east-2` returned `[]` while `AWS/ApplicationELB` `RequestCount`
> showed all four ALBs actively serving traffic (ingress-alb 1268 req/3h,
> crm-alb 484, osticket-alb 216, scriptcase-lb 20).
>
> **Remediation:** namespace corrected to `AWS/WAFV2` in all 8 occurrences in
> `terraform/modules/waf-monitoring/main.tf`, plus a new per-Web-ACL
> dead-man's-switch alarm (`<name>-<key>-no-metrics`: `AllowedRequests < 1`
> with `treat_missing_data = "breaching"`) so that "this alarm is watching
> nothing" becomes a firing condition instead of a silent pass.
>
> **Process lesson:** never accept alarm *state* as evidence that a metric
> pipeline works. Assert on the datapoints. See V3-R below for the corrected
> verification.

## V3-R — Alarm metric pipeline actually publishes data (re-verification)

Added 2026-08-06 to replace the retracted V3 check. The lesson from the
namespace defect is that alarm *state* proves nothing when
`treat_missing_data = "notBreaching"`. This check asserts on datapoints.

**Status: PENDING** — run after the namespace fix is merged and applied.

**Command**

```bash
# 1. The namespace must be non-empty. This is the check that would have
#    caught the original defect.
aws cloudwatch list-metrics --namespace AWS/WAFV2 --region us-east-2 \
  --query 'length(Metrics)' --output text
# PASS: a number > 0.   FAIL: 0 or empty.

# 2. Dimension sets AWS actually emits must match what the alarms specify.
aws cloudwatch list-metrics --namespace AWS/WAFV2 --region us-east-2 \
  --query 'Metrics[].{Metric:MetricName,Dims:Dimensions[].{N:Name,V:Value}}' \
  --output json | head -40
# PASS: dimension names are exactly WebACL / Region / Rule.

# 3. A real datapoint must exist for each Web ACL.
for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  n=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/WAFV2 --metric-name AllowedRequests \
    --dimensions Name=WebACL,Value=$acl Name=Region,Value=us-east-2 Name=Rule,Value=ALL \
    --start-time "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum --region us-east-2 \
    --query 'length(Datapoints)' --output text)
  printf "%-20s datapoints(2h)=%s\n" "$acl" "$n"
done
# PASS: every Web ACL reports a non-zero count.

# 4. The liveness alarms must exist and must NOT be in INSUFFICIENT_DATA
#    once metrics are flowing.
aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
  --region us-east-2 \
  --query 'MetricAlarms[].[AlarmName,StateValue,Namespace]' --output table
# PASS: Namespace column reads AWS/WAFV2 on every row; the -no-metrics
#       alarms sit in OK (they alarm on absence, so OK = metrics present).
```

**Pass criteria**

- `AWS/WAFV2` namespace returns a non-zero metric count.
- Emitted dimension names match the alarm definitions exactly.
- Every Web ACL has at least one real datapoint in a recent window.
- Every alarm's `Namespace` field reads `AWS/WAFV2`.
- The four `-no-metrics` liveness alarms report `OK`, proving positively that
  metrics are arriving rather than merely that no threshold was crossed.

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
| V1 — Logs bucket exists, KMS-encrypted, hardened | Pass (2026-06-21) |
| V2 — Logging attached to both Web ACLs with header redaction | Pass (2026-06-21) |
| V3 — All 6 CloudWatch alarms exist and healthy | **Alarms exist: pass. "Healthy" conclusion RETRACTED 2026-08-06** — see the callout in V3. Namespace typo meant the alarms watched a non-existent namespace. |
| V3-R — Alarm metric pipeline publishes real datapoints | **Pending** — run after the namespace fix applies |
| V4 — All 3 SNS topic subscriptions confirmed | Pass (2026-06-21) |

V1, V2 and V4 remain valid — the filtering, logging and notification paths were
never affected. V3's *existence* check was valid; its *health* conclusion was
not, and is superseded by V3-R.

**What was actually broken, stated plainly:** for seven weeks the WAF inspected
traffic, enforced rules and delivered logs correctly, but nobody would have been
emailed if it had started blocking heavily, and the dashboard was blank. The
protection worked; the alerting did not.

## Items not part of this verification

These are deliberately out of scope for this verification document and tracked elsewhere:

- **Traffic baseline capture.** Requires 7 days of dashboard data. Tracked in `docs/waf/waf-traffic-baseline.md`.
- **Threshold narrowing based on baseline.** Follow-up after baseline capture. Default thresholds are intentionally generous to avoid alarm-storm on cold start.
- **PCI Web ACL deployment.** Gated on the PCI account / VPC / cert landing. Template (`aws-accelerator-config/custom-stacks/pci-alb.yaml`) is built and tuned, deployment block in `customizations-config.yaml` is commented out pending pre-reqs.
- **Bot Control rollout.** Module supports it (`enable_bot_control` toggle). Default off — opt-in cost decision per `docs/waf/waf-design-decisions.md` D6.
