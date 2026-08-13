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

**Full account-wide load balancer enumeration, run 2026-08-10 while chasing V10:**

```
aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,Type,DNSName]' --output table

sftp-nlb         internet-facing  network      sftp-nlb-34a55ff7c8bc1fe1.elb.us-east-2.amazonaws.com
sftp-claro-nlb   internet-facing  network      sftp-claro-nlb-355d444eae8c5f3a.elb.us-east-2.amazonaws.com
wazuh-nlb        internet-facing  network      wazuh-nlb-c809fdc006300e6f.elb.us-east-2.amazonaws.com
ingress-alb      internet-facing  application  ingress-alb-122459471.us-east-2.elb.amazonaws.com
scriptcase-lb    internet-facing  application  scriptcase-lb-1093571739.us-east-2.elb.amazonaws.com
crm-alb          internet-facing  application  crm-alb-142110994.us-east-2.elb.amazonaws.com
osticket-alb     internet-facing  application  osticket-alb-343594101.us-east-2.elb.amazonaws.com
```

Seven load balancers, four of them application. No `icc-alb`.

**Pass criteria met**

- Every application load balancer in the account returns a Web ACL. None report `NONE`.
- The ALB list is enumerated from AWS, not from the Terraform leaf list — so an ALB
  created outside the WAF programme would appear here rather than be invisible.
- The enumeration is complete: exactly four ALBs exist and all four are covered.

**The three NLBs cannot carry a Web ACL.** AWS WAF is a layer-7 control and
attaches to ALBs, CloudFront, API Gateway, AppSync, Cognito user pools and App
Runner — not to Network Load Balancers. `sftp-nlb`, `sftp-claro-nlb` and
`wazuh-nlb` front TCP services (SFTP and Wazuh agent traffic), not HTTP, so WAF
is not the applicable control. Their exposure is managed by security-group
scoping. Recorded here so the count "4 of 4" is not mistaken for "4 of 7".

**Note.** This is four ALBs, up from the two at SOW signing. `crm-alb` and
`osticket-alb` were built in July, were internet-facing on `0.0.0.0/0`, and had
no Web ACL until 2026-08-10.

The first draft of this check qualified the result as "all four *known* ALBs"
pending V10. **That qualification is now lifted** — the enumeration above is
account-wide, so the ALB inventory is known complete and "4 of 4" is
unconditional.

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

**Status: PASSED — 2026-08-10, Perimeter `713939170920`. 20 alarms.**

```
$ aws cloudwatch describe-alarms --alarm-name-prefix perimeter-waf- \
    --region us-east-2 --query 'length(MetricAlarms)' --output text
20
```

Matches the designed set: five alarms per Web ACL (`blocked-total`,
`common-ruleset`, `known-bad-inputs`, `rate-limit`, `no-metrics` liveness) across
four Web ACLs. PR #62's apply landed correctly; the six-alarm capture that
prompted the discrepancy below was a stale reading taken before the expansion.

The history is retained below rather than deleted, because how the discrepancy
was handled is the part worth keeping.

---

### Why this was recorded as NOT VERIFIED first

PR #62 expanded the alarm set from 6 to an expected **20** — five per Web ACL
(`blocked-total`, `common-ruleset`, `known-bad-inputs`, `rate-limit`, and the
`no-metrics` liveness alarm) across four Web ACLs — with per-Web-ACL thresholds
derived from `waf-traffic-baseline.md`. That leaf was applied via
`workflow_dispatch` after its original apply was cancelled.

Internal notes from 2026-08-10 recorded the 20-alarm inventory as verified. A
later capture of `describe-alarms` output, however, listed only the original six
alarm names. Those two records could not be reconciled from the evidence on
hand, so **no pass was claimed and the check was left open for a re-run.**

Carrying forward an unconfirmed monitoring claim is exactly the failure V3
represents. The re-run returned 20 and the check passes — but the correct move
was to spend the command rather than pick the record we preferred.

**Command used to close it** (keep this as the standing inventory check)

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

- Count is 20. **Met — 20.**
- Every `Namespace` reads `AWS/WAFV2`.
- The four `*-no-metrics` liveness alarms are present and `OK`.
- Thresholds match the baseline-derived values: ingress 4000/700/600/100,
  scriptcase 600/400/250/100, and crm + osticket on the module defaults
  600/400/300/100.

The count is confirmed. The per-alarm namespace and threshold columns are worth
eyeballing on the same command output when the dashboard is opened for checklist
step 1, since both come from the same `describe-alarms` call.

If a future run returns 6, the `waf-monitoring` leaf did not apply and needs
re-driving via `workflow_dispatch` with `apply=true`.

## V9 — WAF log records actually landing in S3, per Web ACL

**Status: FAILED on first run, remediated and fully re-verified the same day.
PASSED 2026-08-10 — all four Web ACLs delivering.**

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

**Result — first run, before remediation**

```
ingress-alb-waf      log objects=28812
scriptcase-lb-waf    log objects=15492
crm-alb-waf          log objects=0
osticket-alb-waf     log objects=0
```

**Fail.** Two of four protected resources had never delivered a log record.

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

**Remediation — merged and applied 2026-08-10.** PR **#69** replaced the fixed
variable pair with a `web_acl_names` list covering all four. The plan was
create-only, exactly as predicted — the `waf-logs` module keys
`aws_wafv2_web_acl_logging_configuration` by Web ACL ARN, and both existing ARNs
were unchanged, so the two live configurations kept their state addresses and did
not appear in the plan at all:

```
+ module.waf_logs.aws_wafv2_web_acl_logging_configuration.this["arn:...regional/webacl/crm-alb-waf/4fae2434-cd14-4cdb-b55d-62ccea26e7a9"]
+ module.waf_logs.aws_wafv2_web_acl_logging_configuration.this["arn:...regional/webacl/osticket-alb-waf/2a40b8db-cfb1-4730-b957-9f9da997cb6f"]

Plan: 2 to add, 0 to change, 0 to destroy.
```

No `ALLOW-DESTROY` was needed. An earlier internal prediction that this fix would
require destroy authorisation — on the assumption the state addresses would
change to name-keyed — was wrong; the module was already ARN-keyed.

**Result — re-run after apply**

```
ingress-alb-waf      log objects=28830
scriptcase-lb-waf    log objects=15502
crm-alb-waf          log objects=1
osticket-alb-waf     log objects=0
```

**3 of 4 confirmed.** `crm-alb-waf` moved 0 → 1. The transition from zero to one
is the meaningful signal: it proves the logging configuration, the bucket policy
and the KMS grant all work for a newly enrolled Web ACL. Volume follows traffic
from there.

`osticket-alb-waf` still read 0 at this point. Its logging configuration was
attached and byte for byte identical to the one proven on `crm-alb-waf`; WAF
writes an object only after inspecting a request, and the osTicket ALB had
received none since the apply. That was recorded as unconfirmed rather than
assumed, because assuming is how V3 went wrong.

**Closing step — forced request, run 2026-08-10**

```bash
# Force one inspected request. Plain HTTP because the cert is still pending (V11).
curl -sS -o /dev/null -w 'http status: %{http_code}\n' \
  http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/

sleep 360   # WAF batches to S3 in roughly 5-minute windows

aws s3 ls \
  "s3://aws-waf-logs-713939170920-us-east-2/AWSLogs/713939170920/WAFLogs/us-east-2/osticket-alb-waf/" \
  --recursive | wc -l
```

**Result**

```
http status: 500
4
```

**PASS.** Four log objects under the `osticket-alb-waf` prefix. WAF inspected the
request and delivered the record. That was the only thing this check tested, and
the HTTP status is irrelevant to it — a 200, 302, 404 or 500 all prove inspection
happened.

**Final V9 state — all four Web ACLs delivering:**

| Web ACL | Before #69 | After |
|---|---|---|
| `ingress-alb-waf` | 28812 | 28830 |
| `scriptcase-lb-waf` | 15492 | 15502 |
| `crm-alb-waf` | **0** | 1 → growing |
| `osticket-alb-waf` | **0** | **4** |

The SOW logging deliverable now covers every protected resource.

> ### Unrelated finding: osTicket returned HTTP 500
>
> The `500` above is not a WAF result and does not affect V9, but it should not
> pass without comment.
>
> The `osticket-alb` listener is a plain forward to `10.12.1.67:80` — no
> host-based routing rules, no fixed-response default action. So the 500 came
> from the osTicket application itself, not from the load balancer. An ALB with
> no healthy targets returns 503, and a malformed target response returns 502;
> a 500 means a target answered and the app errored.
>
> **Most likely explanation, not yet confirmed:** the request used the raw ALB
> DNS name as the `Host` header. osTicket stores an absolute helpdesk URL in
> `ost-config.php` and commonly errors when reached on an unexpected hostname.
> The target group's health check uses `/` with matcher `200,301,302` and sends
> the target IP as `Host`, so the target can be healthy while a
> wrong-`Host` request 500s. That is consistent with what was observed.
>
> **The test that settles it** — same request with the correct host header:
>
> ```bash
> curl -sS -o /dev/null -w 'correct Host: %{http_code}\n' \
>   -H 'Host: osticket.insightgrouppr.com' \
>   http://osticket-alb-343594101.us-east-2.elb.amazonaws.com/
>
> ACCT=$(aws sts get-caller-identity --query Account --output text)
> [ "$ACCT" != "713939170920" ] && { echo "WRONG ACCOUNT ($ACCT)"; exit 1; }
>
> tg=$(aws elbv2 describe-target-groups --region us-east-2 \
>   --query "TargetGroups[?contains(TargetGroupName,'osticket')].TargetGroupArn | [0]" \
>   --output text)
> aws elbv2 describe-target-health --target-group-arn "$tg" --region us-east-2 \
>   --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
>   --output table
> ```
>
> A 200/301/302 with the correct `Host` and a `healthy` target means the portal
> works and the 500 was an artefact of testing by IP. Anything else is a real
> osTicket problem, and it belongs to the migration workstream rather than to
> this document. Tracked as step 8d of `waf-finish-checklist.md`.

## V10 — Terraform state inventory for orphans and duplicates

**Status: FAILED, then REMEDIATED — PASSED 2026-08-10.**

Scenario (c): the ALB was already destroyed, but the destroy was partial and left
`icc-alb-sg` (`sg-076c916a807936cee`) behind, unmanaged. Both the security group
and the stale state object have now been removed.

```
$ aws ec2 delete-security-group --group-id sg-076c916a807936cee --region us-east-2
{"Return": true, "GroupId": "sg-076c916a807936cee"}

$ aws s3 cp s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate \
    ./icc-alb-orphan-state-backup.json
download: ... to ./icc-alb-orphan-state-backup.json

$ aws s3 rm s3://lza-terraform-state-547368325532/live/perimeter/icc-alb/terraform.tfstate
delete: s3://.../live/perimeter/icc-alb/terraform.tfstate

$ aws dynamodb delete-item --table-name lza-terraform-locks \
    --key '{"LockID":{"S":".../live/perimeter/icc-alb/terraform.tfstate-md5"}}'
(no output)
```

`Return: true` rather than `DependencyViolation` is the authoritative confirmation
that nothing referenced the security group.

**Certificate inventory afterwards — four, all accounted for:**

```
wazuh.insightgrouppr.com      ISSUED               InUse=True
sc.insightgrouppr.com         ISSUED               InUse=True
crm.insightgrouppr.com        ISSUED               InUse=True
osticket.insightgrouppr.com   PENDING_VALIDATION   InUse=False
```

No `icc-alb` leftover. `crm.insightgrouppr.com` is managed by the live `crm-alb`
leaf, which creates `aws_acm_certificate.icc` under that same resource name — the
leaf was built from `icc-alb`. Nothing was left unmanaged by removing the old
state object.

**Method note.** The `describe-security-groups` reference query used here searches a
single account. Security groups can be referenced across accounts over a peered VPC
or a same-region Transit Gateway with referencing enabled, so that query can be
incomplete. It did not matter in this estate — the `alb` module writes CIDR-only
rules and the only SG-to-SG references in `terraform/` are to
`var.eice_security_group_id` in Production — but the general lesson is to **attempt
the delete and let AWS answer**, because `delete-security-group` is non-destructive
on failure. A check that cannot be incomplete beats a query that can.

The concern this raised was whether a second internet-facing load balancer was
running outside the WAF programme. An account-wide `describe-load-balancers` on
2026-08-10 (full output in V5) returned seven load balancers, four of them
application, and **no `icc-alb`**. Every ALB present carries a Web ACL.

Scenario (b) below is therefore ruled out. What remains is removing a stale state
object so two states can never contend over one set of resources.

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

**Scenarios:**

| | Scenario | Status |
|---|---|---|
| **(a)** | The state describes the same resources `crm-alb` now manages | **RULED OUT 2026-08-10** — the state's ALB DNS name is `icc-alb-396237492.us-east-2.elb.amazonaws.com`, not `crm-alb-142110994...`. Different load balancer; `crm-alb` was rebuilt, not renamed in place. |
| **(b)** | A separate `icc-alb` ALB is still running | **RULED OUT 2026-08-10** — account-wide `describe-load-balancers` shows no `icc-alb`, and all four ALBs present have a Web ACL. |
| **(c)** | The resources are already gone; the state is purely stale | **CONFIRMED 2026-08-10 — with a partial-destroy wrinkle.** See below. |

**Measured**

```
$ aws s3 cp s3://.../live/perimeter/icc-alb/terraform.tfstate - \
    | jq -r '.resources[] | select(.type=="aws_lb") | .instances[].attributes | "\(.name)  \(.dns_name)"'
icc-alb  icc-alb-396237492.us-east-2.elb.amazonaws.com

$ aws ec2 describe-security-groups --region us-east-2 \
    --filters "Name=group-name,Values=*icc*" --query 'SecurityGroups[].[GroupId,GroupName]'
sg-076c916a807936cee   icc-alb-sg          <- STILL EXISTS, unmanaged

$ aws acm list-certificates --region us-east-2 \
    --query 'CertificateSummaryList[?contains(DomainName,`icc`)]...'
(empty)
```

**The destroy that removed `icc-alb` did not finish.** `icc-alb-sg` survives with
no Terraform state pointing at it. That is the signature of a
`DependencyViolation` — AWS refuses to delete a security group while a network
interface still references it — which was hit at destroy time and never revisited.

**Practical consequence: none.** An unused security group costs nothing and grants
nothing while no ENI uses it. Untidy rather than risky. But it must be confirmed
unreferenced before deletion, and the check has to cover **rules in other security
groups that allow traffic from it**, not just attached ENIs. The second is the one
that gets missed.

Distinguishing (a) from (c) is no longer urgent — neither is an exposure — but it
is worth one command before deletion, because it also reveals whether the
`aws_security_group` and `aws_acm_certificate` in that state are shared with
`crm-alb` or are unmanaged leftovers. Neither carries cost, but an unmanaged
security group in the Perimeter account is worth knowing about.

**Command to distinguish (a) from (c)**

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

- The ARN from (2) matches `crm-alb`'s ARN → scenario (a). Resolution: back up,
  then remove the orphaned state object. No infrastructure change.
- The ARN from (2) does not resolve at all → scenario (c), the resources are
  already gone. Same resolution.
- (1) lists an **extra** load balancer beyond the four in V5 → scenario (b).
  **This did not occur** — the enumeration returned exactly four ALBs. Retained
  for the record: had it occurred, the resolution would have been to confirm
  nothing depends on it, then decommission through the normal PR flow with
  explicit `ALLOW-DESTROY`, never out of band.

Also worth checking while in there, since the state claims them:

```bash
# Is the security group from the orphaned state still alive, and does anything use it?
aws ec2 describe-security-groups --region us-east-2 \
  --filters "Name=group-name,Values=*icc*" \
  --query 'SecurityGroups[].[GroupId,GroupName,Description]' --output table

# Is the ACM certificate still there?
aws acm list-certificates --region us-east-2 \
  --query 'CertificateSummaryList[?contains(DomainName,`icc`)].[CertificateArn,DomainName,Status]' \
  --output table
```

Neither costs anything if it exists unused, but an unmanaged security group is
worth knowing about, and an unused certificate is worth deleting for tidiness.

Tracked as step 7 of `waf-finish-checklist.md`.

**Effect on V5.** The first draft of V5 was qualified as "all four *known* ALBs"
pending this check. Chasing V10 is what produced the account-wide load balancer
enumeration, which lifted the qualification. V5 is now unconditional. That is the
useful outcome of this finding, independent of the state cleanup.

## V11 — HTTPS on every public endpoint

**Status: FAILED, and materially worse than first assessed. The osTicket portal
is unusable through its ALB: osTicket 301s to `https://` and the ALB has no 443
listener. Blocked on Insight Group's DNS administrator, which is now on the
critical path rather than a cosmetic follow-up. Full write-up in
`waf-verification-report.md` Correction 5 and `waf-finish-checklist.md` step 8d.**

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

**Fail — and the consequence is larger than "traffic is unencrypted".**

Measured 2026-08-10 while closing V9:

```
request by the ALB's own DNS name              ->  500
request with Host: osticket.insightgrouppr.com ->  301
                                                   Location: https://osticket.insightgrouppr.com/
target group health                            ->  10.12.1.67 unhealthy
                                                   Target.ResponseCodeMismatch
```

**osTicket redirects to `https://`, and there is no 443 listener.**
`enable_https = false` leaves `certificate_arn` empty, and the `alb` module gates
`aws_lb_listener.https` on `count = var.certificate_arn == "" ? 0 : 1`. So:

```
GET http://osticket.insightgrouppr.com/
  -> ALB :80 forwards to 10.12.1.67:80
  -> osTicket 301 -> https://osticket.insightgrouppr.com/
  -> ALB :443  ... no listener. Connection refused.
```

The portal is **unusable through this ALB** for any client that follows the
redirect, which is every browser.

**Separately, the target group has been unhealthy the whole time.** ALB health
checks address the target by IP and ELBv2 has no `HealthCheckHost` parameter; the
check requests `/` with matcher `200,301,302`; osTicket returns 500 on an
unrecognised host; mismatch. Traffic still flowed because when every target in a
group is unhealthy the ALB routes to all of them regardless — a single unhealthy
target means it fails open, silently.

**Not a WAF defect.** The Web ACL inspects and logs that traffic correctly, as V5,
V7 and V9 confirm. Recorded here because it was found during WAF verification.

**Not a live outage — confirmed 2026-08-10.** `osticket.insightgrouppr.com` has not
been pointed at this ALB, and the validation CNAME is deliberately held until the
cutover window rather than overlooked. The help desk is still on the pre-migration
host, so both faults are **latent**.

Two consequences that still hold:

1. **`osticket-alb-waf` is not yet in front of real user traffic.** It is deployed,
   attached, logging and alarming, and acceptance criterion 1 is satisfied on the
   ALB — but until DNS moves it inspects test traffic. Recorded so "all four
   protected" is not read as "the osTicket application is protected today".
2. **Both faults must close before cutover, not after.** Move DNS with either in
   place and the help desk breaks at the worst moment: browsers follow the redirect
   to a closed port, and the ALB has no health signal exactly when one is wanted.

**Cutover ordering** — all reversible, none touching the live help desk, so do them
ahead of the window rather than inside it:

1. Validation CNAME at Network Solutions (`ns47.worldnic.com` / `ns48.worldnic.com`)
   using the Name and Value above → cert `ISSUED`.
2. `enable_https = true` on the `osticket-alb` leaf → adds the 443 listener and
   converts the port-80 listener to a redirect. This is what gives osTicket's own
   redirect somewhere to land.
3. Health check pointed at a static file the web server answers for any `Host`,
   bypassing PHP — **not** widening the matcher to accept 500, which would
   reproduce the rev 2 mistake of a monitor unable to report failure.
4. Then move DNS.

Detail in `waf-finish-checklist.md` step 8d. Belongs on the osTicket migration
checklist rather than carried as an open WAF item.

## Verification summary

| Verification | Status |
|---|---|
| V1 — Logs bucket exists, KMS-encrypted, hardened | Pass (2026-06-21) |
| V2 — Logging attached to both Web ACLs with header redaction | Pass (2026-06-21) |
| V3 — All 6 CloudWatch alarms exist and healthy | **Alarms exist: pass. "Healthy" conclusion RETRACTED 2026-08-06** — see the callout in V3. Namespace typo meant the alarms watched a non-existent namespace. |
| V3-R — Alarm metric pipeline publishes real datapoints | **Pass (2026-08-08)** — 500,210 metrics in `AWS/WAFV2`; 24 and 14 datapoints on the alarm dimension set; 8 alarms on the corrected namespace; liveness alarms `OK` |
| V4 — All 3 SNS topic subscriptions confirmed | Pass (2026-06-21) |
| V5 — Every internet-facing ALB has a Web ACL attached | **Pass (2026-08-10)** — 4 of 4, enumerated account-wide. Qualification lifted; the ALB inventory is known complete |
| V6 — Dashboard `perimeter-waf` exists and is post-fix | **Pass (2026-08-10)** — `LastModified 2026-08-10T18:11:59`. Console eyeball still outstanding |
| V7 — All four Web ACLs return metric datapoints | **Pass (2026-08-10)** — 36 / 19 / 3 / 5 |
| V8 — Alarm inventory (20 expected) and thresholds | **Pass (2026-08-10)** — 20 confirmed. First recorded as NOT VERIFIED on a stale six-alarm capture; re-run settled it |
| V9 — Log records actually landing in S3, per Web ACL | **FAIL, then PASS (2026-08-10)** — was 28812/15492/**0**/**0**; PR #69 merged and applied; now 28830/15502/**1**/**4**. All four Web ACLs delivering |
| V10 — State backend free of orphans / duplicates | **FAIL, then PASS (2026-08-10)** — scenario (c): state ALB was `icc-alb-396237492...`, not `crm-alb-142110994...`, and no `icc-alb` existed. Partial destroy had left `sg-076c916a807936cee`; security group deleted, state object and lock digest removed, backup taken. Cert inventory clean |
| V11 — HTTPS on every public endpoint | **FAIL — latent, not live (2026-08-10)** — osTicket 301s to `https://` and the ALB has no 443 listener; target group also unhealthy behind a fail-open ALB. **Not user-facing:** DNS still points at the pre-migration host and the validation CNAME is deliberately held for the cutover window. Cutover prerequisite for the osTicket migration |

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
