# Deployer permissions

`iam-platform-deployer.json` grants the IAM user that runs deployments, currently `prabhix`, the
access the runbooks need.

**It has to be a customer managed policy, not an inline one.** An inline policy on a user is capped
at 2048 characters and this document is about 6000, so the console will not accept it in the inline
editor. Attach it as:

    10|**IAM → Policies → Create policy → JSON**, paste the file, name it `prabhix-platform-deployer`,
then **IAM → Users → prabhix → Add permissions → Attach policies directly** and select it.

This matters because of how the first attempt failed. After the policy was reported as attached,
every statement with `"Resource": "*"` worked and every statement with a scoped ARN was still
denied — `ecr:CreateRepository` on the exact ARN the policy names came back as *"no identity-based
policy allows"* it, which is what IAM says when the statement is absent rather than when it is
present and narrower than the request. A policy trimmed to fit the inline limit, keeping the short
wildcard statements and dropping the long scoped ones, produces exactly that pattern.

    20|After attaching, verify with the commands at the bottom of this file rather than trusting the
console's success message.

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

One blocker was never about permissions. Changing the instance type used to fail with
`FreeTierRestrictionError`, because the account was on the AWS Free Plan and no policy can unblock
that. The account has since been moved to a paid plan and the instance is now `c7i-flex.large`, so
the stack has the 4 GiB its memory budget was written for. Resolved, and recorded here only because
the error names a restriction rather than a permission and is easy to misread as one.

## Why the policy can now read itself

Two statements, `ReadOwnPermissionsForDiagnosis` and `ReadPolicyDocumentsForDiagnosis`, let this user
list its own attached policies and read policy documents. They grant no ability to change anything.

They exist because of a specific dead end. ECR was reported as attached and was still denied, and the
obvious next question — *what is actually attached to this user?* — could not be answered, because
`iam:ListAttachedUserPolicies` was itself denied. That left no way to distinguish "the policy is
absent" from "the policy is present and something else is wrong", so the only available move was to
ask for it to be pasted again and hope. With these statements the question is answerable:

```powershell
aws iam list-attached-user-policies --user-name prabhix
aws iam get-policy-version --policy-arn arn:aws:iam::029096972251:policy/prabhix-platform-deployer `
  --version-id v1 --query "PolicyVersion.Document.Statement[].Sid"
```

The second command lists the Sids that are really in force. If `EcrRepositoryLifecycle` is missing
from that list, the document was truncated on the way in, which is the failure this whole file exists
to catch.

## Verifying the policy took effect

Run all four. The first two are the ones that were denied while the policy appeared to be attached,
so they are the ones that distinguish "attached" from "attached and complete".

```powershell
aws ecr describe-repositories                 # expect an empty list, not AccessDenied
aws ecr create-repository --repository-name prabhix/probe `
  --image-tag-mutability IMMUTABLE           # the scoped statement; delete the repo afterwards
aws elasticache describe-serverless-caches    # expect the Valkey cache
aws sesv2 get-account --query ProductionAccessEnabled
```
