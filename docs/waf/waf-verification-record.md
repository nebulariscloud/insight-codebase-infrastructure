# WAF — verification record

Post-deployment verification run by Nebularis Cloud LLC for the Insight Group AWS WAF Implementation SOW (March 2026).

Captures the exact AWS API calls made against the live environment after merge, with the responses observed. Use this as the audit trail for the SOW acceptance.

This is the **technical appendix**. For the client-facing summary — what was
verified, what failed, and the corrections to our own record — see
`waf-verification-report.md`.

| Item | Value |
|---|---|
| Environment | Insight Group AWS Organization, Perimeter account `713939170920`, region `us-east-2` |
| Web ACLs in scope | Round 1: `ingress-alb-waf`, `scriptcase-lb-waf`. Round 3 onward: all four, adding `crm-alb-waf` and `osticket-alb-waf` |
| Verification dates | Round 1: 2026-06-21 (V1, V2, V3, V4) · Round 2: 2026-08-08 (V3-R) · Round 3: 2026-08-10 (V5–V11) |
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

---

# Round 3 — 2026-08-10

Run after PRs #60/#65 (WAF on `crm-alb` and `osticket-alb`), #62 (per-Web-ACL
thresholds) and #63/#66 (pipeline hardening) were merged and applied.

Round 3 exists because rounds 1 and 2 checked the **two** Web ACLs that existed
in June. Two more were created in July. The checks below therefore enumerate
resources from AWS first and compare against configuration second, rather than
checking the resources the configuration happens to name. That ordering is what
surfaced V9 and V10.

## V5 — Every internet-facing ALB has a Web ACL attached

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
echo "account: $ACCT"
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT — need Perimeter"; exit 1; }

aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[?Type==`application`].[LoadBalancerName,LoadBalancerArn]' \
  --output text | while read -r name arn; do
    acl=$(aws wafv2 get-web-acl-for-resource --resource-arn "$arn" --region us-east-2 \
      --query 'WebACL.Name' --output text 2>/dev/null || echo "NONE")
    printf "%-16s WAF=%s\n" "$name" "$acl"
  done
```

**Result**

```
account: 713939170920

ingress-alb      WAF=ingress-alb-waf
scriptcase-lb    WAF=scriptcase-lb-waf
crm-alb          WAF=crm-alb-waf
osticket-alb     WAF=osticket-alb-waf
```

**Pass criteria met**

- Every application load balancer in the account returns a Web ACL. None report `NONE`.
- The ALB list is enumerated from AWS, not from the Terraform leaf list — so an ALB
  created outside the WAF programme would appear here rather than be invisible.

**Caveat.** This is four ALBs, up from the two at SOW signing. `crm-alb` and
`osticket-alb` were built in July, were internet-facing on `0.0.0.0/0`, and had
no Web ACL until 2026-08-10. Read this result as "all four *known* ALBs are
protected" until V10 is resolved — see the note there.

## V6 — Dashboard exists and is current

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

aws cloudwatch list-dashboards --region us-east-2 \
  --query 'DashboardEntries[?DashboardName==`perimeter-waf`].[DashboardName,LastModified]' \
  --output table
```

**Result**

```
perimeter-waf    2026-08-10T18:11:59+00:00
```

**Pass criteria met**

- Dashboard exists at the expected name.
- `LastModified` is post-namespace-fix, so it carries the corrected `AWS/WAFV2`
  widget definitions rather than the June ones.

**Not covered by this check:** whether the widgets actually render populated.
That needs a human to open the console. Tracked in `waf-finish-checklist.md`
step 1 and listed under "Not yet verified" in `waf-verification-report.md`.
Existence of a dashboard is not evidence that it displays anything — that is
precisely the mistake V3 made.

## V7 — All four Web ACLs return real metric datapoints

Extends V3-R from two Web ACLs to four.

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  n=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/WAFV2 --metric-name AllowedRequests \
    --dimensions Name=WebACL,Value=$acl Name=Region,Value=us-east-2 Name=Rule,Value=ALL \
    --start-time "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum --region us-east-2 \
    --query 'length(Datapoints)' --output text)
  printf "%-20s datapoints(2h)=%s\n" "$acl" "$n"
done
```

> `date -u -v-2H` is BSD/macOS. On Linux use `date -u -d '2 hours ago'`.

**Result**

```
ingress-alb-waf      datapoints(2h)=36
scriptcase-lb-waf    datapoints(2h)=19
crm-alb-waf          datapoints(2h)=3
osticket-alb-waf     datapoints(2h)=5
```

**Pass criteria met**

- All four non-zero on the exact `[WebACL, Region, Rule]` dimension set the alarms use.
- The lower counts on `crm-alb-waf` and `osticket-alb-waf` track their genuinely
  lower request volume, not a broken pipeline. A pipeline fault would read `0`,
  which is what the June namespace defect produced.

## V8 — Alarm inventory and deployed thresholds

**Status: NOT VERIFIED.** Recorded as an open gap rather than a pass.

PR #62 expanded the alarm set from 6 to an expected **20** — five per Web ACL
(`blocked-total`, `common-ruleset`, `known-bad-inputs`, `rate-limit`, and the
`no-metrics` liveness alarm) across four Web ACLs — with per-Web-ACL thresholds
derived from `waf-traffic-baseline.md`. That leaf was applied via
`workflow_dispatch` after its original apply was cancelled.

Internal notes from 2026-08-10 record the 20-alarm inventory as verified. A
later capture of `describe-alarms` output, however, listed only the original six
alarm names. **Those two records cannot be reconciled from the evidence on
hand, so no pass is claimed.**

Carrying forward an unconfirmed monitoring claim is exactly the failure V3
represents. Settling it is one command.

**Command to close this**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

echo "alarm count: $(aws cloudwatch describe-alarms \
  --alarm-name-prefix perimeter-waf- --region us-east-2 \
  --query 'length(MetricAlarms)' --output text)   (expected 20)"

aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
  --region us-east-2 \
  --query 'sort_by(MetricAlarms,&AlarmName)[].[AlarmName,StateValue,Namespace,Threshold]' \
  --output table
```

**Pass criteria**

- Count is 20.
- Every `Namespace` reads `AWS/WAFV2`.
- The four `*-no-metrics` liveness alarms are present and `OK`.
- Thresholds match the baseline-derived values: ingress 4000/700/600/100,
  scriptcase 600/400/250/100, and crm + osticket on the module defaults
  600/400/300/100.

If the count comes back as 6, the `waf-monitoring` leaf did not apply and needs
re-driving via `workflow_dispatch` with `apply=true`.

## V9 — WAF log records actually landing in S3, per Web ACL

**Status: FAILED.** This check found a real gap.

V2 confirmed logging was *attached*. It did not confirm records were *arriving*,
and it only covered the two Web ACLs that existed at the time. This check does
both, for all four.

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

for acl in ingress-alb-waf scriptcase-lb-waf crm-alb-waf osticket-alb-waf; do
  n=$(aws s3 ls \
    "s3://aws-waf-logs-713939170920-us-east-2/AWSLogs/713939170920/WAFLogs/us-east-2/$acl/" \
    --recursive 2>/dev/null | wc -l | tr -d ' ')
  printf "%-20s log objects=%s\n" "$acl" "$n"
done
```

**Result**

```
ingress-alb-waf      log objects=28812
scriptcase-lb-waf    log objects=15492
crm-alb-waf          log objects=0
osticket-alb-waf     log objects=0
```

**Fail.** Two of four protected resources have never delivered a log record.

**Root cause.** `terraform/live/perimeter/waf-logs` took one variable per Web
ACL:

```hcl
ingress_web_acl_name    = "ingress-alb-waf"
scriptcase_web_acl_name = "scriptcase-lb-waf"
```

with no way to express a third or fourth. When `crm-alb` and `osticket-alb` were
built in July and given Web ACLs, no mechanism existed to enrol them. Nothing
failed — the leaf planned clean and applied clean the entire time.

Same shape as the namespace defect in V3: an uncovered case that produced no
error signal. Both were found only by asserting on observed data.

This is a **delivery miss on the SOW logging deliverable**, not a change
request. It had also been mischaracterised internally as an optional refactor.

**Remediation.** PR **#69** replaces the fixed variable pair with a
`web_acl_names` list covering all four. The plan is create-only — the
`waf-logs` module keys `aws_wafv2_web_acl_logging_configuration` by Web ACL
ARN, and both existing ARNs are unchanged, so the two live configurations keep
their state addresses:

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

**Re-verification after #69 applies:** re-run the command above. Pass is all
four above zero. Allow ~5 minutes for the first batch; `crm-alb-waf` and
`osticket-alb-waf` may need a request generated against them if idle.

## V10 — Terraform state inventory for orphans and duplicates

**Status: FAILED — root cause not yet determined.**

Not an obvious WAF check, but V5's conclusion depends on having the complete
list of load balancers. This enumerates state files in the backend and looks for
any that no live leaf corresponds to.

**Command**

```bash
# SharedServices 547368325532 holds the state backend.
aws s3 ls s3://lza-terraform-state-547368325532/live/ --recursive \
  | grep 'terraform.tfstate$'
```

**Finding**

```
s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate
  serial: 2
  lineage: 4d7fafc8-9e41-1cdf-d9e3-14c241ab8901
  last modified: 2026-07-17
  resource_count: 13

  addresses:
    aws_lb.this
    aws_security_group.alb
    aws_acm_certificate.icc
    aws_lb_target_group.this, aws_lb_target_group.dev
    aws_lb_target_group_attachment.prod, aws_lb_target_group_attachment.dev
    aws_lb_listener.http
    aws_lb_listener_rule.prod_host, aws_lb_listener_rule.dev_host
    aws_vpc_security_group_ingress_rule.http
    aws_vpc_security_group_ingress_rule.https
    aws_vpc_security_group_egress_rule.to_targets
```

`crm-alb` was renamed from `icc-alb` in PR #45. There is no
`terraform/live/perimeter/icc-alb` leaf on `main`, so nothing plans against this
state — but it claims 13 live resources.

**Two possibilities, not yet distinguished:**

| | Scenario | Implication |
|---|---|---|
| **(a)** | The state describes the same resources `crm-alb` now manages | Dual-management hazard. Two state files claiming one set of resources; a future apply against either could fight the other. No extra cost, no extra exposure. |
| **(b)** | A separate `icc-alb` ALB is still running | An internet-facing load balancer outside the WAF programme — unprotected, unmonitored, and billing. |

**Command to distinguish them**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

# 1. Every load balancer AWS knows about, with its WAF status.
aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,DNSName,LoadBalancerArn]' \
  --output table

# 2. The ALB ARN recorded in the orphaned state (run where you can read the
#    SharedServices state bucket).
aws s3 cp s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate - \
  | jq -r '.resources[] | select(.type=="aws_lb") | .instances[].attributes.arn'
```

**Interpretation**

- The ARN from (2) appears in (1) **and** that ALB is named `crm-alb` → scenario
  (a). Resolution: remove the orphaned state object. No infrastructure change.
- (1) lists an **extra** load balancer beyond the four in V5 → scenario (b).
  Resolution: confirm nothing depends on it, then decommission it through the
  normal PR flow. Do not delete it out of band.
- The ARN from (2) does not resolve at all → the resources are already gone and
  the state is purely stale. Resolution: remove the state object.

Tracked as step 7 of `waf-finish-checklist.md`. Until it is settled, V5 reads as
"all four *known* ALBs are protected".

## V11 — HTTPS on every public endpoint

**Status: FAILED — blocked on Insight Group's DNS administrator.**

**Command**

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT) — need Perimeter"; exit 1; }

aws acm describe-certificate --region us-east-2 \
  --certificate-arn arn:aws:acm:us-east-2:713939170920:certificate/8c2c365f-a408-4bbf-8f6e-187a28665057 \
  --query 'Certificate.{Status:Status,Domain:DomainName,Validation:DomainValidationOptions[0].ResourceRecord}' \
  --output json
```

**Result**

```json
{
  "Status": "PENDING_VALIDATION",
  "Domain": "osticket.insightgrouppr.com",
  "Validation": {
    "Name": "_59bfd12229b222d5a7e78deac7838a08.osticket.insightgrouppr.com.",
    "Type": "CNAME",
    "Value": "_10c4856142562dfe22916aa3cfd5e334.jkddzztszm.acm-validations.aws."
  }
}
```

**Fail.** The osTicket portal is served over plain HTTP. The Web ACL inspects
the traffic either way, so this is not a WAF defect, but credentials submitted
to the ticket portal travel unencrypted and that belongs in the same record.

**Blocked on:** one CNAME at Network Solutions (`ns47.worldnic.com` /
`ns48.worldnic.com`), using the Name and Value above. Once ACM reads `ISSUED`,
set `enable_https = true` on the `osticket-alb` leaf — a one-line PR.

## Verification summary

| Verification | Status |
|---|---|
| V1 — Logs bucket exists, KMS-encrypted, hardened | Pass (2026-06-21) |
| V2 — Logging attached to both Web ACLs with header redaction | Pass (2026-06-21) |
| V3 — All 6 CloudWatch alarms exist and healthy | **Alarms exist: pass. "Healthy" conclusion RETRACTED 2026-08-06** — see the callout in V3. Namespace typo meant the alarms watched a non-existent namespace. |
| V3-R — Alarm metric pipeline publishes real datapoints | **Pass (2026-08-08)** — 500,210 metrics in `AWS/WAFV2`; 24 and 14 datapoints on the alarm dimension set; 8 alarms on the corrected namespace; liveness alarms `OK` |
| V4 — All 3 SNS topic subscriptions confirmed | Pass (2026-06-21) |
| V5 — Every internet-facing ALB has a Web ACL attached | **Pass (2026-08-10)** — 4 of 4, enumerated from AWS. Qualified by V10 |
| V6 — Dashboard `perimeter-waf` exists and is post-fix | **Pass (2026-08-10)** — `LastModified 2026-08-10T18:11:59`. Console eyeball still outstanding |
| V7 — All four Web ACLs return metric datapoints | **Pass (2026-08-10)** — 36 / 19 / 3 / 5 |
| V8 — Alarm inventory (20 expected) and thresholds | **NOT VERIFIED** — internal notes and a later capture disagree; no pass claimed. One command to settle |
| V9 — Log records actually landing in S3, per Web ACL | **FAIL (2026-08-10)** — `crm-alb-waf` and `osticket-alb-waf` at 0 objects. Fix in PR #69 |
| V10 — State backend free of orphans / duplicates | **FAIL (2026-08-10)** — orphaned `icc-alb` state claiming 13 resources. Root cause undetermined |
| V11 — HTTPS on every public endpoint | **FAIL (2026-08-10)** — osTicket on plain HTTP; ACM cert `PENDING_VALIDATION` awaiting a client-side DNS record |

Round 3 changed the method, not just the coverage. V1–V4 asked "does the thing
the configuration names exist?" V5, V9 and V10 enumerate from AWS first and
compare against configuration second. That ordering is the only reason V9 and
V10 were found — the configuration was internally consistent in both cases and
would have kept passing a config-driven check indefinitely.

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

- **Dashboard widgets rendering populated.** Needs a human in the console. `waf-finish-checklist.md` step 1.
- **Incident response runbook exercised.** Written but never run. Block/unblock exercise, ~30 min. `waf-finish-checklist.md` step 2.
- **`crm-alb-waf` / `osticket-alb-waf` traffic baselines.** Need a week of data; both currently run on module-default thresholds. Tracked in `docs/waf/waf-traffic-baseline.md`.
- **PCI Web ACL deployment.** Gated on the PCI account / VPC / cert landing. Template (`aws-accelerator-config/custom-stacks/pci-alb.yaml`) is built and tuned, deployment block in `customizations-config.yaml` is commented out pending pre-reqs.
- **Bot Control rollout.** Module supports it (`enable_bot_control` toggle). Default off — opt-in cost decision per `docs/waf/waf-design-decisions.md` D6.
- **Custom application-specific rules.** Capability delivered, none defined. Needs four owner conversations; template in `docs/waf/waf-custom-rules-finding.md`.

## Method note — why rounds differ

Round 1 verified that each resource the Terraform configuration named existed in
AWS. Every check passed, and two of the conclusions were wrong.

Round 3 inverted the direction: enumerate from AWS, then compare against
configuration. `describe-load-balancers` before checking WAF attachment.
`s3 ls` object counts before trusting `get-logging-configuration`. Every state
file in the backend, not the leaves on `main`.

Config-driven checks can only find defects the configuration knows about. V9 and
V10 are both cases where the configuration was internally consistent and simply
did not describe reality — a config-driven check would have kept passing on both
indefinitely. Keep round 3's ordering for any future verification.
