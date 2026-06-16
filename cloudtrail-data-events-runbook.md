# CloudTrail S3 Data Events — Runbook

## What this runbook is for

The Control Tower trail `aws-controltower-BaselineCloudTrail` (in the Management account, deployed in `us-east-2`) ships management events org-wide but has no S3 **data** event selectors configured. That gap fails Security Hub controls `S3.22` (object-level write events) and `S3.23` (object-level read events) for every account in the org.

This runbook is the canonical procedure for adding S3 read+write data event selectors to that trail. It is the resolution of decision item **D-9** in `.kiro/specs/security-hub-findings-remediation-strategy/design.md` (option C: one-time manual change documented in a runbook).

It is intentionally not automated. Three reasons:

1. The trail lives in the Management account, which the repo's Terraform credential model deliberately excludes (`terraform/README.md` and `terraform-execution-policy.json`).
2. Event selectors are stable configuration. Once set, they don't drift on their own.
3. Automating a single API call would require either eroding the Management-account fence or building a CloudFormation stack via LZA `customizations-config.yaml` — both expensive solutions to a five-minute problem.

The mitigation for "stable but not in version control" is this document, plus a quarterly reminder to re-verify and a Control Tower upgrade re-check step.

## Findings closed by this runbook

| Control | Title | Standard |
|---|---|---|
| `S3.22` | S3 general purpose buckets should log object-level write events | AWS FSBP, NIST 800-53 r5 |
| `S3.23` | S3 general purpose buckets should log object-level read events | AWS FSBP, NIST 800-53 r5 |

The fix is org-wide. Once applied, both controls move to `PASSED` for every account in the organization, not just PCI.

## When to run this

Run the procedure once. Re-run it only after:

- An AWS Control Tower landing-zone upgrade (`aws controltower update-landing-zone` or the equivalent Console action). Major upgrades have historically reset some Control Tower-managed configuration.
- A change to the Control Tower trail name or location.
- A Security Hub re-aggregation showing `S3.22` or `S3.23` failing again on accounts that previously passed.

The quarterly verification step below catches all three cases.

## Prerequisites

- Console access to the **Management account** with permissions to modify CloudTrail trails (`AdministratorAccess` permission set in Identity Center, or equivalent).
- The Management account ID and the trail ARN. Both are available in the Control Tower console under Landing Zone settings, and in CloudTrail under the trail's overview.
- AWS CLI v2 installed locally, configured with Management-account credentials.

## Procedure

### Step 1 — Capture the trail's current configuration

This gives you the baseline to compare against and a rollback target.

```bash
# Substitute the Management account ID. The trail is in us-east-2.
aws cloudtrail get-event-selectors \
  --trail-name arn:aws:cloudtrail:us-east-2:<management-account-id>:trail/aws-controltower-BaselineCloudTrail \
  --region us-east-2 \
  > before.event-selectors.json

aws cloudtrail get-trail-status \
  --name arn:aws:cloudtrail:us-east-2:<management-account-id>:trail/aws-controltower-BaselineCloudTrail \
  --region us-east-2 \
  > before.trail-status.json
```

Save both files alongside this runbook in your evidence store. Expect `before.event-selectors.json` to show only management-event selectors and no data resources.

### Step 2 — Apply the new event selectors

The new configuration keeps existing management-event coverage and adds two data event selectors covering all S3 buckets, one for ReadOnly and one for WriteOnly. Splitting Read and Write keeps the Security Hub finding mapping clean and lets you tune them independently later.

```bash
aws cloudtrail put-event-selectors \
  --trail-name arn:aws:cloudtrail:us-east-2:<management-account-id>:trail/aws-controltower-BaselineCloudTrail \
  --region us-east-2 \
  --event-selectors '[
    {
      "ReadWriteType": "All",
      "IncludeManagementEvents": true,
      "DataResources": []
    },
    {
      "ReadWriteType": "ReadOnly",
      "IncludeManagementEvents": false,
      "DataResources": [
        { "Type": "AWS::S3::Object", "Values": ["arn:aws:s3"] }
      ]
    },
    {
      "ReadWriteType": "WriteOnly",
      "IncludeManagementEvents": false,
      "DataResources": [
        { "Type": "AWS::S3::Object", "Values": ["arn:aws:s3"] }
      ]
    }
  ]'
```

Notes:

- `arn:aws:s3` as the value covers every bucket in every account ingested by the org trail. AWS treats this as the wildcard for all S3 objects.
- The first selector preserves management events, exactly as the trail had before.
- `IncludeManagementEvents: false` on the data-only selectors avoids double-billing for management events.

If you prefer the Console:

1. Sign in to the Management account.
2. CloudTrail → Trails → `aws-controltower-BaselineCloudTrail`.
3. **Data events** → Edit → Add data event.
4. Resource type: **S3**. Log selector template: **Log all events**. Save.
5. Repeat with selector **Log readOnly events** and **Log writeOnly events** if you prefer separate selectors. The CLI version above is the canonical config; the Console produces equivalent state.

### Step 3 — Verify the change

```bash
aws cloudtrail get-event-selectors \
  --trail-name arn:aws:cloudtrail:us-east-2:<management-account-id>:trail/aws-controltower-BaselineCloudTrail \
  --region us-east-2 \
  > after.event-selectors.json

diff before.event-selectors.json after.event-selectors.json
```

Expect the diff to show two new selectors (ReadOnly and WriteOnly) targeting `AWS::S3::Object` with value `arn:aws:s3`.

### Step 4 — Generate test events and confirm delivery

The trail aggregates to the central log bucket in LogArchive. Wait ~10 minutes for the first event to land, then:

```bash
# In any spoke account with at least one S3 bucket. Generate one read and one write event.
TEST_BUCKET=<some-existing-bucket>
echo "test" > /tmp/cloudtrail-data-events-test.txt
aws s3 cp /tmp/cloudtrail-data-events-test.txt s3://$TEST_BUCKET/cloudtrail-data-events-test.txt
aws s3 cp s3://$TEST_BUCKET/cloudtrail-data-events-test.txt /tmp/cloudtrail-data-events-readback.txt
aws s3 rm s3://$TEST_BUCKET/cloudtrail-data-events-test.txt
```

In LogArchive (or wherever you query CloudTrail logs — Athena, CloudWatch Logs Insights, Security Lake), search for `eventName=PutObject` and `eventName=GetObject` matching the test object. Both should appear within 10–15 minutes.

### Step 5 — Capture compliance evidence

Required artifacts for the audit/evidence store:

1. `before.event-selectors.json` and `after.event-selectors.json` from Steps 1 and 3.
2. Console screenshot of the trail's **Data events** tab showing the new selectors.
3. Athena/Insights query result showing the test `PutObject`/`GetObject` events from Step 4.
4. Security Hub finding export filtered by `S3.22` and `S3.23`, run 1–2 hours after Step 2, showing both controls in `PASSED` state.

Store these in the same evidence location used by the parent strategy spec.

## Rollback

If the change causes a problem (it shouldn't — adding selectors does not affect existing logs), restore the prior state:

```bash
# Apply the captured baseline. Replace the file with before.event-selectors.json from Step 1.
aws cloudtrail put-event-selectors \
  --trail-name arn:aws:cloudtrail:us-east-2:<management-account-id>:trail/aws-controltower-BaselineCloudTrail \
  --region us-east-2 \
  --cli-input-json file://before.event-selectors.json
```

Verify with `get-event-selectors` and confirm no data resources are present.

## Cost considerations

CloudTrail data events are billed at **$0.10 per 100,000 events delivered**. The cost is only the events themselves; storage in S3 is separate.

A rough sizing for an org of a few accounts with normal S3 activity: expect tens of thousands to low millions of events per month. At 1M events/month/account that's $1.00 per account per month. Heavy S3 workloads (data pipelines, content stores) can push this higher; quiet accounts are negligible.

There is no double-billing risk because there is only one trail. (This is exactly why D-9 chose option (c) — adding a second trail would have doubled the bill.)

If costs become a concern, the future tightening path is to scope the data resources to specific bucket ARNs instead of `arn:aws:s3`, accepting that newly-created buckets won't be covered until the selector is updated.

## Quarterly verification

Add a recurring calendar event for the security owner: every quarter, run

```bash
aws cloudtrail get-event-selectors \
  --trail-name arn:aws:cloudtrail:us-east-2:<management-account-id>:trail/aws-controltower-BaselineCloudTrail \
  --region us-east-2
```

and confirm both ReadOnly and WriteOnly S3 data selectors are still present. If they're gone, run the procedure again and capture fresh evidence. Likely cause: a Control Tower landing-zone upgrade between checks.

## Control Tower upgrade re-check

Whenever you upgrade the Control Tower landing zone (the "Update available" banner in the Control Tower Console, or `aws controltower update-landing-zone`), re-run **Step 3** of this runbook within 24 hours of the upgrade completing. If the selectors were reset, re-apply with **Step 2**.

This is the only known scenario where the selectors can be silently dropped.

## Cross-references

- `.kiro/specs/security-hub-findings-remediation-strategy/design.md` — parent strategy, decision item D-9, disposition table rows 9 and 10.
- `.kiro/specs/security-baseline-terraform-module/requirements.md` — Requirement 10.1 documents that S3.22 and S3.23 are out of scope for the Terraform module precisely because of the Management-account boundary that motivates this runbook.
- `pci-onboarding-guide.md` — also references this runbook as part of the PCI baseline checklist.

## Change log

| Date | Author | Change |
|---|---|---|
| 2026-06-15 | Cloud Platform / Security | Runbook created as resolution of decision item D-9. |
