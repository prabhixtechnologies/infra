# AWS resources the deployment expects

Applied by hand today. Nothing here is created by `deploy.sh`, which only ever restarts containers
on an existing box.

## `ses-send-policy.json` — outbound mail through SES

The instance role `PrabhixTechnologies` (account `029096972251`, instance `i-05496f940af0517ae`)
has **no SES permissions**, so attaching this is what makes `MAIL_TRANSPORT=SES` work. `SesTransport`
authenticates through the default credential chain whenever `SES_ACCESS_KEY` is blank, so the
instance role is enough and no static keys are needed.

Neither the `prabhix` IAM user nor the instance role can run these — both are denied `iam:*` — so
they need root or an administrator.

```bash
aws iam create-policy \
  --policy-name PrabhixSesSend \
  --policy-document file://ses-send-policy.json

# Attach to the role behind the instance profile, not to the profile itself.
aws iam attach-role-policy \
  --role-name PrabhixTechnologies \
  --policy-arn arn:aws:iam::029096972251:policy/PrabhixSesSend
```

The `ses:FromAddress` condition means a leaked instance role cannot be used to send as anyone
else's domain, which is the difference between a compromised box and a compromised sender
reputation.

The policy also grants `ses:GetAccount` and `ses:GetEmailIdentity`. They are reads, and they are what
`SesTransport.healthy()` uses to report *why* mail is not leaving — an unverified domain and a
sandboxed account are otherwise indistinguishable from mail that vanishes. Omit them and the
transport still sends; `/actuator/health` just says the sender identity is unconfirmed.

## Before SES can deliver anything

Three things are independent of the code and each will silently ruin deliverability on its own.
`docs/MAIL.md` has the detail; in short:

1. **Verify the domain identity** in SES and publish the three DKIM CNAMEs it issues.

   ```bash
   aws sesv2 create-email-identity \
     --region ap-south-1 \
     --email-identity prabhixtechnologies.com \
     --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT

   # The three CNAMEs to add at GoDaddy.
   aws sesv2 get-email-identity \
     --region ap-south-1 \
     --email-identity prabhixtechnologies.com \
     --query 'DkimAttributes.Tokens'
   ```

   Each token `T` becomes a CNAME `T._domainkey` → `T.dkim.amazonses.com`.

2. **Add `include:amazonses.com` to SPF.** The live record is
   `v=spf1 include:secureserver.net -all`, and that `-all` hard-fails SES. With DMARC at
   `p=quarantine`, the mail is not marked, it is filed away unseen. The record becomes:

   ```
   v=spf1 include:secureserver.net include:amazonses.com -all
   ```

   This is additive — GoDaddy keeps working, so existing mailboxes are unaffected.

3. **Leave the SES sandbox.** In the sandbox, SES accepts mail only to verified addresses, and
   rejects everything else with `MessageRejected` — visible in `mail_outbox.last_error`.

Only steps 1 and 2 need DNS. Step 3 is a support request and usually same-day.

### Checking it worked without sending anything

`SesTransport` probes SES once a minute and says which of the three steps is outstanding. The
health endpoint is public, so it is deliberately terse (`show-details: never`) and gives only
`status`; the reason is in the log:

```bash
# On the box. Silence here means SES is usable.
docker logs prabhix-backend-1 --since 5m | grep -E 'SES cannot send|sandbox'
```

Once mail is flowing, `/actuator/health` returns 200 again. It reports `DOWN` for as long as nothing
can deliver, which is the intended meaning — see the health section of `docs/MAIL.md`. Nothing
orchestration-level reads it: the container healthcheck, `deploy.sh` and `deploy/smoke.ps1` all use
`/actuator/health/readiness`, a separate group that excludes mail.

A failed send records the same string in `mail_outbox.last_error`, so a specific message can be
diagnosed after the fact:

```sql
SELECT to_addresses, status, attempt_count, transport_used, last_error
FROM mail_outbox ORDER BY created_at DESC LIMIT 5;
```
