# Making outbound mail actually send

Production currently cannot send mail, and the health endpoint says so: `MailTransportHealthIndicator`
reports DOWN, which is why `/actuator/health` returns DOWN while both liveness and readiness are 200.
That is the indicator doing its job. Mail is genuinely broken, and it is broken in three separate
places that have to be fixed together.

This runbook is the measured state of the account and the domain as of the RDS cutover, not a plan.

    10|## Where it stands

| Piece | State |
| --- | --- |
| SES account | Sandbox. `ProductionAccessEnabled: false`, 200 messages/day, 1/second |
| SES identities | Domain `prabhixtechnologies.com` created with Easy DKIM, **not yet verified** |
| DKIM DNS | The three CNAMEs are **not published** |
| SPF | `v=spf1 include:secureserver.net -all` — hard fail, and SES is not included |
| DMARC | `v=DMARC1; p=quarantine; adkim=r; aspf=r` — relaxed alignment, so DKIM alone can satisfy it |
| MX | `smtp.secureserver.net` / `mailstore1.secureserver.net` — inbound mail goes to GoDaddy, not here |
    20|| App config | `MAIL_TRANSPORT=SMTP_RELAY` with `SMTP_HOST=localhost`, where nothing listens |
| Credentials | The backend container has no AWS credentials, so the SES transport could not authenticate even once the domain verifies |

The `SMTP_HOST=localhost` value is a leftover: it was recovered from the environment of the old
running container when the production `.env` was found missing, and it was already wrong then.

## Step 1 — publish the DKIM CNAMEs (GoDaddy, manual)

Three records. Type CNAME, and GoDaddy appends the domain itself, so enter the **Name** exactly as
shown without the trailing `.prabhixtechnologies.com`.

    30|| Name | Value |
| --- | --- |
| `ehdrb2ujuqw3oowt5yqo6azgdws5grij._domainkey` | `ehdrb2ujuqw3oowt5yqo6azgdws5grij.dkim.amazonses.com` |
| `ntedfrg6o2rcbjazasfow4ngfgxyxwmn._domainkey` | `ntedfrg6o2rcbjazasfow4ngfgxyxwmn.dkim.amazonses.com` |
| `m223l6zqfwz753he5s5tdtwdvlta34jk._domainkey` | `m223l6zqfwz753he5s5tdtwdvlta34jk.dkim.amazonses.com` |

These tokens belong to the identity created on 2026-08-30. If the identity is ever deleted and
recreated, the tokens change and this table is stale — read the current ones with:

```powershell
    40|aws sesv2 get-email-identity --email-identity prabhixtechnologies.com `
  --query "DkimAttributes.Tokens"
```

Then wait for verification, which is SES polling DNS rather than anything to trigger:

```powershell
aws sesv2 get-email-identity --email-identity prabhixtechnologies.com `
  --query "{Verified:VerifiedForSendingStatus,Dkim:DkimAttributes.Status}"
```

    50|## Step 2 — add SES to SPF (GoDaddy, manual)

The existing record ends in `-all`, which is a hard fail, so mail sent through SES fails SPF today.
Edit the root TXT record to:

```
v=spf1 include:secureserver.net include:amazonses.com -all
```

Keep `-all`. Keep `include:secureserver.net`, or inbound-replying from GoDaddy webmail breaks.

    60|DMARC passes on DKIM alone here, because `adkim=r` is relaxed and SES signs with the organizational
domain once step 1 completes. SPF is still worth fixing: some receivers weight both, and a hard-fail
SPF with a passing DKIM is a worse signal than both passing.

## Step 3 — give the backend credentials to call SES

The container has no AWS credentials. Do not put an access key in `deploy/.env.prod`; attach a role
to the instance instead, which is also what the ECR pull path needs.

`deploy/aws/ses-send-policy.json` holds the send permissions. Attach it to the instance role
alongside the ECR pull policy, then confirm from inside the container:
    70|
```bash
docker exec prabhix-backend-1 sh -lc 'curl -s http://169.254.169.254/latest/meta-data/iam/info'
```

## Step 4 — switch the transport

Once steps 1-3 are done, in `deploy/.env.prod`:

```
MAIL_TRANSPORT=SES
    80|AWS_REGION=ap-south-1
```

and remove `SMTP_HOST`/`SMTP_PORT`, which the SES transport does not read. Redeploy and check that
the health indicator has gone UP — that is the assertion, not the absence of an error in the log.

## The sandbox, and what it costs you

In sandbox SES will only deliver to verified addresses, so transactional mail to real customers
silently fails until production access is granted. Request it from **SES → Account dashboard → Request
production access**; it is a support request, usually answered within a day, and it wants to know
    90|what the mail is and how bounces are handled. The platform already records bounces and complaints
through `SesFeedbackService` and `SesWebhookService`, which is the substance of that answer.

Until then, verify the individual addresses used for testing:

```powershell
aws sesv2 create-email-identity --email-identity you@example.com
```

## Inbound mail is a separate question

    100|MX points at GoDaddy, so mail addressed to `@prabhixtechnologies.com` is delivered there and never
reaches this box. The six mailboxes the seed created — `owner@`, `support@`, `billing@`, `careers@`,
`security@`, `no-reply@` — exist as rows in the `oneops` database, not as anything that can receive
mail today.

Repointing MX here means running the mail server profile and accepting responsibility for inbound
spam filtering and storage. Leaving MX at GoDaddy and reading it over IMAP is the smaller move, and
is what Mailroom's IMAP support is for. That decision is not made yet and should not be made by
whoever next edits this file without asking.
