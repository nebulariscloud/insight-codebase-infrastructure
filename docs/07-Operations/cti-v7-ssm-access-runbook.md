# Grant one person SSM-only shell access to the CTI v7 server — from scratch

Goal: create a brand-new IAM Identity Center **permission set** that lets exactly one
principal open a **Session Manager shell** on **only** `i-04dc1a79b8277f654`
(CTI v7, Production `395516496764`, `us-east-2`) — no SSH key, no access to any
other instance.

**Fixed values used below**

| Thing | Value |
|---|---|
| SSO instance ARN | `arn:aws:sso:::instance/ssoins-6684f792209778d4` |
| Target account | `395516496764` |
| Region | `us-east-2` |
| Target instance | `i-04dc1a79b8277f654` |
| Session-log CMK | `arn:aws:kms:us-east-2:395516496764:key/f148edeb-221b-4a78-8367-96f95c1669c6` |
| Policy file | `docs/07-Operations/cti-v7-ssm-access-policy.json` |

Run all `sso-admin` / `identitystore` commands from a session that has **Identity
Center admin** (your `AWSAdministratorAccess` in `066971257969` — the SSO management
account). The `ssm start-session` test at the end runs as the **end user**, not you.

---

## Step 0 — Confirm the instance is actually an SSM managed node

**This is the step that was never checked and would make everything else pointless.**
If the agent isn't connected, no policy will help.

```bash
aws ssm describe-instance-information \
  --region us-east-2 \
  --filters "Key=InstanceIds,Values=i-04dc1a79b8277f654" \
  --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}"
```

Run it with a role that can read SSM in `395516496764` (your PowerUser there is fine).

- **Returns a row with `"Ping": "Online"`** → good, continue to Step 1.
- **Returns `[]` (empty)** → the box is not registered. Stop here and fix that first:
  the instance needs (a) the SSM agent running, and (b) an instance profile with
  `AmazonSSMManagedInstanceCore`, and (c) network egress to the SSM endpoints. See
  the SSM-agent install notes in the journal. No user permission set works until this
  returns `Online`.

---

## Step 1 — Create the permission set

```bash
aws sso-admin create-permission-set \
  --instance-arn arn:aws:sso:::instance/ssoins-6684f792209778d4 \
  --name cti-v7-ssm-vendor \
  --description "SSM Session Manager shell to CTI v7 (i-04dc1a79b8277f654) only" \
  --session-duration PT4H
```

From the output, copy the `PermissionSetArn` (looks like
`arn:aws:sso:::permissionSet/ssoins-6684f792209778d4/ps-XXXXXXXXXXXX`). **Export it so
the rest of the steps are copy-paste:**

```bash
export PS_ARN="arn:aws:sso:::permissionSet/ssoins-6684f792209778d4/ps-XXXXXXXXXXXX"
export INSTANCE_ARN="arn:aws:sso:::instance/ssoins-6684f792209778d4"
```

> `PT4H` = 4-hour session. Adjust if you want shorter. The old set used `PT1H`, which
> is why cached creds kept biting — a longer session is fine for a vendor doing real work.

---

## Step 2 — Attach the scoped inline policy

The policy is already written to `docs/07-Operations/cti-v7-ssm-access-policy.json`.
Feed it directly (no hand-pasting):

```bash
aws sso-admin put-inline-policy-to-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --inline-policy file://docs/07-Operations/cti-v7-ssm-access-policy.json
```

Verify it landed:

```bash
aws sso-admin get-inline-policy-for-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN"
```

You should see `SSM-SessionManagerRunShell` in the output. That document is what a
plain `aws ssm start-session` / console "Connect" uses.

> **Critical:** the RunShell document ARN must include the **account ID**
> (`arn:aws:ssm:us-east-2:395516496764:document/SSM-SessionManagerRunShell`), because
> this account has Session Manager preferences configured, which makes the document
> account-owned. The account-less form (`ssm:us-east-2::document/...`) does NOT match
> and silently denies. This was the 2-hour bug. See
> `ssm-session-manager-runshell-arn-gotcha.md`. The policy file already has the correct
> ARN.

---

## Step 3 — Find the user (or group) to assign

Get the Identity Store ID first:

```bash
aws sso-admin list-instances \
  --query "Instances[0].IdentityStoreId" --output text
```

```bash
export IDSTORE="d-XXXXXXXXXX"   # value from the command above
```

Look up the user by their sign-in username:

```bash
aws identitystore list-users \
  --identity-store-id "$IDSTORE" \
  --query "Users[?UserName=='vendor.username'].{Name:UserName,Id:UserId}"
```

```bash
export PRINCIPAL_ID="<UserId from above>"
```

> If the person doesn't have an Identity Center user yet, create them in the Identity
> Center console (Users → Add user) or via `identitystore create-user`, then re-run the
> lookup. Assigning a **group** instead of a user works the same way — use
> `--principal-type GROUP` and a group id in Step 4.

---

## Step 4 — Assign the permission set to that user on the CTI v7 account

```bash
aws sso-admin create-account-assignment \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --principal-type USER \
  --principal-id "$PRINCIPAL_ID" \
  --target-id 395516496764 \
  --target-type AWS_ACCOUNT
```

This one call does two things: it provisions the permission set into `395516496764`
(creating the `AWSReservedSSO_cti-v7-ssm-vendor_*` role) **and** grants the user access
to it. No separate `provision-permission-set` needed on first assignment.

Confirm it finished:

```bash
aws sso-admin list-account-assignments \
  --instance-arn "$INSTANCE_ARN" \
  --account-id 395516496764 \
  --permission-set-arn "$PS_ARN"
```

You should see your `PRINCIPAL_ID` listed.

---

## Step 5 — The user connects (clean session — this is where every prior test failed)

The end user (or you, testing as them) runs this. **The `unset` + cache purge are
mandatory** — they force fresh credentials minted *after* the policy exists, instead of
reusing a stale cached session:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sso logout
rm -rf ~/.aws/sso/cache ~/.aws/cli/cache
aws sso login
```

At the SSO portal / role picker they choose **`cti-v7-ssm-vendor`** on account
`395516496764`. Then:

```bash
aws ssm start-session --target i-04dc1a79b8277f654 --region us-east-2
```

Expected: a shell prompt on the box. Done.

To prove the scoping works, they can try any other instance id — it should be denied.

---

## If Step 5 still denies on `SSM-SessionManagerRunShell`

At this point the policy, the document grant, and a fresh session are all guaranteed
correct, so a remaining denial means the account-side role didn't sync. Force it:

```bash
# Re-provision the permission set explicitly
aws sso-admin provision-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --target-id 395516496764 --target-type AWS_ACCOUNT
# grab RequestId from output, poll to SUCCEEDED:
aws sso-admin describe-permission-set-provisioning-status \
  --instance-arn "$INSTANCE_ARN" \
  --provision-permission-set-request-id <RequestId>
```

Then the user re-runs the Step 5 clean-session block. If it *still* denies after a
confirmed-fresh login, the only thing left is an account-side inspection of the
`AWSReservedSSO_cti-v7-ssm-vendor_*` role by someone with **IAM read in
`395516496764`** (your PowerUser there cannot read IAM) — compare its inline policy to
the permission set and re-sync by removing + re-adding the account assignment.

---

## Cleanup / revoke (when the vendor is done)

```bash
# Remove the user's access
aws sso-admin delete-account-assignment \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --principal-type USER --principal-id "$PRINCIPAL_ID" \
  --target-id 395516496764 --target-type AWS_ACCOUNT

# (optional) delete the whole permission set once no one is assigned
aws sso-admin delete-permission-set \
  --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN"
```

---

## Notes

- **Why a new permission set instead of reusing `aheeva-cti-v7-access`:** clean state,
  and it's scoped/named for the vendor so their access is separately auditable and
  revocable. Don't put the vendor on your own identity's permission set — session logs
  should be attributable to them.
- **Session logging:** this account has `sessionManager.sendToCloudWatchLogs = true`
  (LZA global-config), so shell sessions are KMS-encrypted and streamed to CloudWatch —
  that's why the policy includes `kms:Decrypt` + `kms:GenerateDataKey` on the
  session-log CMK. Every keystroke/output is recorded and attributable to the vendor's
  principal.
- **No inbound rule, no SSH key:** Session Manager is agent-initiated outbound over 443.
  You do not open port 22 for this and you never hand out a key.
