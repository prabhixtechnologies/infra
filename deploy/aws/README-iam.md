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

## Why the GitHub trust policy matches on an account ID and not a name

`github-oidc-trust.json` matches `repo:*@320051589/*:ref:refs/heads/main` and the `master`
equivalent. That looks alarmingly loose and is not: `320051589` is this account's GitHub owner ID,
which maps to exactly one account and cannot be re-registered. A name can be renamed and the
freed name claimed by someone else; an ID cannot.

It took six failed runs to arrive at, all with the same useless error — *"Not authorized to perform
sts:AssumeRoleWithWebIdentity"* — while every observable input was correct. Two separate causes were
hiding behind it, and neither is guessable, so the debug step in `ci.yml` that prints the token's
claims is the thing that actually solved it and is worth keeping.

**The subject claim is not the documented format.** This account issues *immutable* subjects, with
numeric IDs appended to both the owner and the repository:

```
repo:prabhixtechnologies@320051589/platform@1349569564:ref:refs/heads/main
```

Every published example, and every pattern tried here first, assumes `repo:owner/repo:ref:...`. A
pattern of `repo:prabhixtechnologies/*` cannot match that string, because what follows the owner is
`@320051589`, not `/`. This is why widening the pattern from five enumerated names to an owner
wildcard changed nothing: both were the wrong shape, not merely too narrow.

**`repository_owner` did not equal the owner's name.** Adding
`"repository_owner": "prabhixtechnologies"` alongside a correct subject pattern still failed;
removing it was the change that let the push through. That claim comes back masked as `***` in the
logs — it matches a repository secret, so its real value cannot be read from CI output — and it is
evidently not the lowercase login the GitHub API reports as canonical. It is left out rather than
guessed at.

Two things still constrain the role, and they are the ones that matter: the immutable **owner ID**,
and the **branch**. The branch restriction is the one doing security work, because a pull request
from a fork presents a subject ending `:pull_request` rather than `:ref:refs/heads/main`, so it
cannot assume the role even though it runs in our repository's context.

Two smaller traps, both worth knowing before editing this file. IAM **requires** a trust policy for
this provider to constrain `sub` or `job_workflow_ref`; conditioning on `repository_owner` alone is
rejected outright with `MalformedPolicyDocument`. And IAM rejects unknown fields in a trust policy,
`_comment` included, which is why this explanation is here and not beside the JSON.

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
