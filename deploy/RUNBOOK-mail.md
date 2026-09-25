# Making outbound mail actually send

**Outbound mail works now.** `/actuator/health` reports UP, the backend logs *"SES transport ready in
region ap-south-1"* on startup, and a message sent from the instance returned a MessageId. The steps
below are done unless marked otherwise; two DNS-level items remain and are listed first.

## What is still open

**MX still points at GoDaddy**, so hosted addresses do not receive internet mail here. Inbound
transport is decided below; do not treat Mailroom as live until MX is moved.

## Inbound transport decision

Outbound is SES in `ap-south-1`. Inbound is a separate choice.

**Decision: SES inbound receiving in ap-south-1 is the intended path**, once ingest is wired.
The region has an email-receiving endpoint (`inbound-smtp.ap-south-1.amazonaws.com`). The shape
is SES receipt rules → S3 (raw MIME) → SNS notification → the existing `MailIngestionService`
(`InboundSource.WEBHOOK` / `stageRaw`). That ingest path is **not built yet**: today's inbound
code is LMTP from Postfix (`POST /api/v1/oneops/mail/inbound/lmtp`) and IMAP poll. The SES SNS webhook
that exists today is bounce and complaint feedback only.

Until ingest exists, **do not flip MX**. Leave it at GoDaddy (`smtp.secureserver.net` /
`mailstore1.secureserver.net`). Mailroom stays unlisted as live in marketing for that reason.

**Fallback if SES ingest is delayed or we need on-box delivery:** a dedicated mail-server
(Postfix + Dovecot + Rspamd) via the `mailserver` compose profile:

```
docker compose -f docker-compose.yml -f ../Mailroom/mail-server/docker-compose.mail.yml --profile mailserver up -d
```

That profile stays opt-in. Enabling it opens 25/587/993 and accepts MX; it is a part-time ops
job (PTR, blocklists, port 25 unblock). Prefer SES receiving when the webhook/S3 ingest is
ready rather than running Postfix on the same t3.medium as the rest of the platform.

The Mailroom **web** service is a different profile (`mailroom`) and is unrelated to inbound MX.

## Remaining DNS and SES sandbox

**SPF still fails.** The record is `v=spf1 include:secureserver.net -all`, which does not include SES
and ends in a hard fail. DKIM passes and this domain's DMARC uses relaxed alignment, so mail
authenticates on DKIM alone and is not being quarantined — but SPF actively *fails* rather than being
absent, because `-all` tells receivers to reject anything unlisted. Receivers that weigh SPF
separately from DMARC will count that against the domain. In GoDaddy, change the TXT record on `@` to:

```
v=spf1 include:secureserver.net include:amazonses.com -all
```

Keep `secureserver.net`: it is what GoDaddy's own mail sends through, and removing it breaks whatever
still sends from there.

**SES is still in sandbox**, at 200 messages/day and 1/second, so mail reaches addresses at verified
identities only — your own domain works, Gmail does not. Requesting production access is a support
case needing a description of the mail's purpose and how bounces are handled, so it is deliberately
not automated here: it asks for business statements that should not be invented.

## What was wrong, and what fixed it

| Piece | Then | Now |
| --- | --- | --- |
| SES identity | Created, not verified | **Verified**, `DkimStatus: SUCCESS` |
| DKIM CNAMEs | Not published | Published, all three resolve |
| Transport | `MAIL_TRANSPORT=SMTP_RELAY` at `localhost:587`, nothing listening | `MAIL_TRANSPORT=SES` |
| Credentials | Backend had none, so SES could not authenticate | Instance role `prabhix-ec2-ecr-pull` carries `ses-send-policy.json`; the SDK resolves them from instance metadata, with no static keys |
| Health | DOWN | UP |

The health endpoint was right the whole time. `MailTransportHealthIndicator` returned DOWN while
liveness and readiness returned 200, which is the indicator doing its job rather than a false alarm.

Everything from here down is the state measured at the RDS cutover, kept as the record of how it was
diagnosed.

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

## Inbound mail

MX still points at GoDaddy, so `@prabhixtechnologies.com` is not delivered to this box. The
mailboxes in the database cannot receive internet mail until MX moves. See **Inbound transport
decision** at the top of this file: SES receiving in ap-south-1 is the intended path once ingest
is wired; the mail-server profile is the fallback. Do not flip MX, and do not mark Mailroom live,
until one of those receivers is actually ingesting.

