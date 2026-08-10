# WAF — verification record

Post-deployment verification run by Nebularis Cloud LLC for the Insight Group AWS WAF Implementation SOW (March 2026).

Captures the exact AWS API calls made against the live environment after merge, with the responses observed. Use this as the audit trail for the SOW acceptance.

| Item | Value |
|---|---|
| Environment | Insight Group AWS Organization, Perimeter account `713939170920`, region `us-east-2` |
| Web ACLs in scope | `ingress-alb-waf`, `scriptcase-lb-waf` |
| Verification date | 2026-06-21 (V1, V2, V4) / 2026-08-08 (V3-R) |
| Run by | Nebularis Cloud LLC |
| Method | AWS CLI calls executed in the Perimeter account, read-only |

> ## ⚠️ RUN EVERY CHECK IN PERIMETER `713939170920`
>
> All WAF resources — Web ACLs, the logs bucket and CMK, the alarms, dashboard
> and SNS topics — live in **Perimeter**. Production `395516496764` holds the
> EC2/RDS workloads and the shared-prod VPC but **no WAF at all**.
>
> Querying WAF from Production returns zero metrics, no Web ACLs and no alarms,
> which is **indistinguishable from a broken pipeline**. That mistake cost
> several hours of misdiagnosis on 2026-08-08. Every block below therefore opens
> with an account assertion. Do not remove it, and do not record a result
> without stating the account it came from.
>
> ```bash
> ACCT=$(aws sts get-caller-identity --query Account --output text)
> echo "account: $ACCT"
> [ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT — need Perimeter 713939170920"; exit 1; }
> ```
>
> Account map:
>
> | Account | ID | Holds |
> |---|---|---|
> | **Perimeter** | `713939170920` | All Web ACLs, all four public ALBs, waf-logs bucket + CMK, waf-monitoring alarms/dashboard/SNS |
> | Production | `395516496764` | shared-prod VPC, EC2 workloads, RDS. No WAF. |
> | PCI | `247514667218` | Empty VPC, no workload |
>
> **Account confirmed for V1/V2/V4:** Perimeter `713939170920`. Verified
> retroactively from the recorded outputs, which contain the
> `aws-waf-logs-713939170920-us-east-2` bucket name and
> `arn:aws:wafv2:us-east-2:713939170920:regional/webacl/...` ARNs. The original
> record only implied this; it is now stated.

## V1 — WAF logs bucket exists and is properly encrypted

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

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
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

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
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

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

**Status: PASSED — 2026-08-08, Perimeter `713939170920` / us-east-2.**

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
echo "account: $ACCT"
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT — need Perimeter"; exit 1; }

# 1. The namespace must be non-empty. This is the check that would have
#    caught the original defect.
aws cloudwatch list-metrics --namespace AWS/WAFV2 --region us-east-2 \
  --query 'length(Metrics)' --output text

# 2. Dimension sets AWS actually emits must include what the alarms specify.
aws cloudwatch list-metrics --namespace AWS/WAFV2 --region us-east-2 \
  --query 'Metrics[:5].{M:MetricName,D:Dimensions[].Name}' --output json

# 3. A real datapoint must exist for each Web ACL.
for acl in ingress-alb-waf scriptcase-lb-waf; do
  n=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/WAFV2 --metric-name AllowedRequests \
    --dimensions Name=WebACL,Value=$acl Name=Region,Value=us-east-2 Name=Rule,Value=ALL \
    --start-time "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum --region us-east-2 \
    --query 'length(Datapoints)' --output text)
  printf "%-20s datapoints(2h)=%s\n" "$acl" "$n"
done

# 4. Alarms must all report the corrected namespace.
aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
  --region us-east-2 \
  --query 'MetricAlarms[].[AlarmName,StateValue,Namespace]' --output table
```

**Result**

```
account: 713939170920

1. AWS/WAFV2 metric count: 500210

2. Emitted dimension sets (sample):
   AllowedRequests  -> [WebACL, Country, Region]
   BlockedRequests  -> [WebACL, Country, Region]
   CountRuleMatch   -> [Resource, LabelName, ResourceType, LabelNamespace]
   SampleBlockedRequest -> [VerificationStatus, Organization, WebACL,
                            BotCategory, Region, Intent, BotName]

3. ingress-alb-waf      datapoints(2h)=24
   scriptcase-lb-waf    datapoints(2h)=14

4. perimeter-waf-ingress-blocked-total             OK   AWS/WAFV2
   perimeter-waf-ingress-common-ruleset-blocks     OK   AWS/WAFV2
   perimeter-waf-ingress-no-metrics                OK   AWS/WAFV2
   perimeter-waf-ingress-rate-limit-blocks         OK   AWS/WAFV2
   perimeter-waf-scriptcase-blocked-total          OK   AWS/WAFV2
   perimeter-waf-scriptcase-common-ruleset-blocks  OK   AWS/WAFV2
   perimeter-waf-scriptcase-no-metrics             OK   AWS/WAFV2
   perimeter-waf-scriptcase-rate-limit-blocks      OK   AWS/WAFV2
```

**Pass criteria met**

- `AWS/WAFV2` returns **500,210** metrics. Non-zero, so the namespace resolves.
- Emitted dimensions include the `[WebACL, Region, Rule]` combination the alarms
  use. WAF fans out several dimension combinations per metric (per-country,
  per-label, per-bot-category), which is why the namespace holds half a million
  entries — the alarms target the right combination, proven by check 3.
- Both Web ACLs return real datapoints on the exact alarm dimension set.
- Every alarm's `Namespace` reads `AWS/WAFV2`.
- **The two `-no-metrics` liveness alarms report `OK`, which is the meaningful
  signal.** They alarm on *absence* (`treat_missing_data = "breaching"`), so
  `OK` positively confirms metrics are arriving. This is precisely the ambiguity
  D13 was designed to remove: in June, `OK` on the threshold alarms meant
  nothing; here, `OK` on the liveness alarms means something.

**Confirms the namespace typo was a real defect, not cosmetic.** `AWS/WAFV2`
holds 500K metrics; `AWS/WAFv2` is not a namespace WAF publishes to. The June
alarms had no data source and could never have fired under any circumstances.

**Process note.** An earlier attempt at this check returned `0` and was briefly
recorded as "the fix did not work". That measurement was taken in **Production**,
where no WAF exists. The conclusion was withdrawn. Hence the account assertion
now leading every block in this document.

## V4 — SNS subscriptions confirmed for all three severity tiers

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

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
| V3-R — Alarm metric pipeline publishes real datapoints | **Pass (2026-08-08)** — 500,210 metrics in `AWS/WAFV2`; 24 and 14 datapoints on the alarm dimension set; 8 alarms on the corrected namespace; liveness alarms `OK` |
| V4 — All 3 SNS topic subscriptions confirmed | Pass (2026-06-21) |

V1, V2 and V4 remain valid — the filtering, logging and notification paths were
never affected. V3's *existence* check was valid; its *health* conclusion was
not, and is superseded by V3-R, which now passes.

**What was actually broken, stated plainly:** from 2026-06-21 to 2026-08-08 the
WAF inspected traffic, enforced rules and delivered logs correctly, but nobody
would have been emailed if it had started blocking heavily, and the dashboard was
blank. The protection worked; the alerting did not.

**What went unreported during that window.** Two consecutive-period threshold
breaches on `ingress-alb-waf` — 2026-08-06 19:23→19:28 (1958 then 1055 blocks per
5 min) and 2026-08-07 00:23→00:28 (2225 then 1081) — both exceeded the configured
threshold with `evaluation_periods = 2` and should have alarmed. Per-rule
analysis shows both were ~65% `AWS-IPReputation`, i.e. botnet and mass-scanner
traffic that WAF blocked correctly. **No evidence of an unhandled targeted
attack.** The gap was in being told, not in being protected. Full numbers in
`waf-traffic-baseline.md`.

## Items not part of this verification

These are deliberately out of scope for this verification document and tracked elsewhere:

- **Traffic baseline capture.** Requires 7 days of dashboard data. Tracked in `docs/waf/waf-traffic-baseline.md`.
- **Threshold narrowing based on baseline.** Follow-up after baseline capture. Default thresholds are intentionally generous to avoid alarm-storm on cold start.
- **PCI Web ACL deployment.** Gated on the PCI account / VPC / cert landing. Template (`aws-accelerator-config/custom-stacks/pci-alb.yaml`) is built and tuned, deployment block in `customizations-config.yaml` is commented out pending pre-reqs.
- **Bot Control rollout.** Module supports it (`enable_bot_control` toggle). Default off — opt-in cost decision per `docs/waf/waf-design-decisions.md` D6.
