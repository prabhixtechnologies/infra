# Deployer permissions

`iam-platform-deployer.json` is an inline policy for the IAM user that runs deployments, currently
`prabhix`. Attach it under **IAM → Users → prabhix → Add permissions → Create inline policy → JSON**
and name it `prabhix-platform-deployer`.

Nothing in it was guessed from the plan. Each statement corresponds to a runbook step that returned
`AccessDenied` when the account was probed, so the policy is the measured gap and not a wishlist.

## Why the resource scopes look the way they do

Everything is pinned to account `029096972251` and region `ap-south-1`. The wildcards that remain
are ones the API forces: `ecr:GetAuthorizationToken`, the ElastiCache describes and the SES calls
are account-level operations that reject a resource ARN, so scoping them would make the policy
invalid rather than tighter.

`AccountWideEnumeration` exists because of a mistake worth not repeating. Actions that list an
entire account — `ecr:DescribeRepositories`, `logs:DescribeLogGroups`, `secretsmanager:ListSecrets`,
`ssm:DescribeParameters`, `s3:ListAllMyBuckets`, `iam:ListOpenIDConnectProviders` — are authorized
against `*`, not against the resources they happen to return. Putting them in a statement scoped to
`.../prabhix/*` looks tighter and is simply unsatisfiable: the call is denied no matter what exists.
The first version of this policy did exactly that, and the symptom was six services still reporting
`AccessDenied` after the policy had been attached. Keep enumeration separate from the scoped
statements that grant real access to named resources.

IAM is deliberately the narrowest part. `iam:CreateRole` across the account would let this user mint
a role with any permissions and assume it, which is a privilege escalation dressed as a deployment
convenience. So role creation is limited to the two names the GitHub OIDC federation needs, the OIDC
provider statement is limited to GitHub's issuer, and `iam:PassRole` is limited to the EC2 pull role
and conditioned on the service it may be passed to.

## What was already allowed, and what is not a permissions problem

The probe found `prabhix` already has EC2 read and write, and `prabhixDBAdmin` already has RDS read
and write. Those two cover the instance and database work, so this policy does not restate them.

One blocker is not about permissions at all. Changing the instance type fails with
`FreeTierRestrictionError`, because the account is on the AWS Free Plan:

```
An error occurred (FreeTierRestrictionError) when calling the ModifyInstanceAttribute operation:
This operation is not available for free plan accounts.
```

`t3.medium` is not free-tier eligible, so no policy will unblock it. That needs the account moved to
a paid plan, and until then production stays on `t3.small` with 1.9 GiB, against a stack whose memory
budget was written for 4 GiB.

## Verifying the policy took effect

```powershell
aws ecr describe-repositories                 # expect an empty list, not AccessDenied
aws elasticache describe-serverless-caches    # expect the Valkey cache
aws sesv2 get-account --query ProductionAccessEnabled
```
