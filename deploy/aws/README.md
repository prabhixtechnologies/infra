# AWS resources the deployment expects

Applied by hand today. Nothing here is created by `deploy.sh`, which only ever restarts containers
on an existing box.

## `ses-send-policy.json` — outbound mail through SES

The EC2 instance profile has **no SES permissions**, so attaching this is what makes
`MAIL_TRANSPORT=SES` work. `SesTransport` authenticates through the default credential chain
whenever `SES_ACCESS_KEY` is blank, so the instance role is enough and no static keys are needed.

```bash
aws iam create-policy \
  --policy-name PrabhixSesSend \
  --policy-document file://ses-send-policy.json

# Attach to the role behind the instance profile, not to the profile itself.
aws iam attach-role-policy \
  --role-name <instance-role> \
  --policy-arn arn:aws:iam::<account-id>:policy/PrabhixSesSend
```

The `ses:FromAddress` condition means a leaked instance role cannot be used to send as anyone
else's domain, which is the difference between a compromised box and a compromised sender
reputation.

## Before SES can deliver anything

Three things are independent of the code and each will silently ruin deliverability on its own.
`docs/MAIL.md` has the detail; in short:

1. **Verify the domain identity** in SES and publish the three DKIM CNAMEs it issues.
2. **Add `include:amazonses.com` to SPF.** The live record is
   `v=spf1 include:secureserver.net -all`, and that `-all` hard-fails SES. With DMARC at
   `p=quarantine`, the mail is not marked, it is filed away unseen.
3. **Leave the SES sandbox.** In the sandbox, SES accepts mail only to verified addresses, and
   rejects everything else with `MessageRejected` — visible in `mail_outbox.last_error`.

Only step 1 and 2 need DNS. Step 3 is a support request and usually same-day.
