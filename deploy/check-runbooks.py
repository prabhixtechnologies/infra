#!/usr/bin/env python3
"""Check that the runbooks refer to files, JSON and resources that exist.

A runbook is followed once, by hand, usually under time pressure, and a step that names a file which
was renamed six commits ago fails at the worst moment. Nothing else in the repository reads these
documents, so nothing else notices.

Three classes of rot, all of which have a cheap mechanical check:

  1. A referenced path that no longer exists. `file://deploy/aws/x.json` in a command, or a
     `deploy/RUNBOOK-y.md` in prose.
  2. A referenced JSON policy that exists but is not valid JSON — the AWS CLI reports this as a
     parameter validation error that does not name the file.
  3. An account, region, instance or IP repeated across documents that disagree between them. These
     are copied by hand and there are enough of them that one going stale is likely.

Not checked: whether the AWS resources exist, which needs credentials and would make this a test of
the account rather than of the documents.

    python deploy/check-runbooks.py
"""
from __future__ import annotations

import io
import json
import pathlib
import re
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

REPO = pathlib.Path(__file__).resolve().parent.parent
UMBRELLA = REPO.parent

DOCS = [
    "deploy/RUNBOOK.md",
    "deploy/RUNBOOK-rds.md",
    "deploy/RUNBOOK-mail.md",
    "deploy/RUNBOOK-consolidate.md",
    "deploy/aws/README.md",
    "deploy/aws/README-iam.md",
    "deploy/aws/cloudwatch-alarms.md",
    "docs/OPERATIONS.md",
    "docs/MAIL.md",
    "docs/IDENTITY.md",
    "docs/ARCHITECTURE.md",
    "docs/PRODUCTS.md",
    "docs/SURFACES.md",
    "docs/LOCAL-STACK.md",
]

# Paths that are references to somewhere else on purpose: a path on the server, or a placeholder
# the reader substitutes. Sibling repositories are *not* skipped — they are resolved under the
# umbrella checkout (UMBRELLA / oneOps/..., UMBRELLA / MobiStack/...) so a moved compose file or a
# deleted ops-tool is reported rather than silently ignored.
NOT_IN_THIS_REPO = re.compile(
    r"^(/|~|\.\./|<|\$|opt/|home/|etc/|var/|tmp/|public\.ecr\.aws/|[\w.-]+\.amazonaws\.com/)"
)

SIBLING_PREFIXES = (
    "oneOps/",
    "Platform/",
    "MobiStack/",
    "Identity/",
    "Mailroom/",
    "Infra/",
    "Mobile/",
)

# Environment files are named constantly by the runbooks and are absent from the repository on
# purpose — they hold the live secrets and are created on the server from the .example beside them.
# Their absence is the correct state, so checking for them would report a problem forever. The same
# goes for anything created from a `.example` next to it: the runbook that says "copy x.example to
# x" is naming a file that must not be committed.
DELIBERATELY_ABSENT = re.compile(r"(^|/)\.env($|\.)|(^|/)secrets/[\w.-]+$")

# `file://deploy/aws/x.json`, and bare repo-relative paths in prose or commands. `.github/` is in the
# list because the runbooks now send people to a workflow by path, and a workflow that was renamed
# is exactly the kind of reference nothing else would catch.
FILE_URL = re.compile(r"file://([\w./-]+)")
REPO_PATH = re.compile(
    r"`([\w./-]*(?:deploy|docs|docker|backend|web|marketing|mobile|\.github)/[\w./-]+)`"
    r"|`((?:oneOps|Platform|MobiStack|Identity|Mailroom|Infra|Mobile)/[\w./-]+)`"
    r"|`(docker-compose[\w.-]*\.ya?ml)`"
)

# Retired names that must not be offered as a path to follow. Historical mentions without a
# backtick path (SURFACES.md: "This replaces mobile-api-contract.md") are allowed.
GONE_AS_LIVE = (
    (re.compile(r"`[^`]*\bops-tool\b[^`]*`"), "ops-tool was folded into the oneOps ops hub"),
    (re.compile(r"`docs/mobile-api-contract\.md`"), "replaced by docs/SURFACES.md"),
    (
        re.compile(r"`MobiStack/docker-compose[^`]*`"),
        "MobiStack compose lives in Infra/docker-compose.yml behind the mobistack profile",
    ),
)

KEPT_INSTANCE = "i-05496f940af0517ae"

# Identifiers copied between documents by hand.
FACTS = {
    "account": re.compile(r"\b(029096972251)\b"),
    "region": re.compile(r"\b(ap-south-1)\b"),
    "kept instance": re.compile(rf"\b({KEPT_INSTANCE})\b"),
    "mobistack instance": re.compile(r"\b(i-069a080a3068da761)\b"),
    "instance role": re.compile(r"\brole/(\w+)\b"),
    "env parameter": re.compile(r"(/prabhix/prod/env)\b"),
}

# The workflow and the IAM policy each name the production instance, and the runbooks name it in
# prose. All three have to agree, or a deploy goes to an instance that no longer exists — or worse,
# to one that does and is not production.
INSTANCE_BEARERS = [
    ".github/workflows/deploy.yml",
    "deploy/aws/ssm-deploy-policy.json",
]


def main() -> int:
    problems: list[str] = []
    checked_paths = 0
    checked_json = 0

    for doc in DOCS:
        path = REPO / doc
        if not path.exists():
            problems.append(f"{doc}: listed here but missing from the repository")
            continue

        text = path.read_text(encoding="utf-8")

        for pattern, reason in GONE_AS_LIVE:
            if pattern.search(text):
                problems.append(f"{doc}: still names a retired path ({reason})")

        referenced = set()
        for match in FILE_URL.finditer(text):
            # AWS CLI reads JSON from stdin as file://- ; that is not a path in the repo.
            if match.group(1) in ("-",):
                continue
            referenced.add(match.group(1))
        for match in REPO_PATH.finditer(text):
            referenced.add(next(g for g in match.groups() if g))

        for reference in sorted(referenced):
            if DELIBERATELY_ABSENT.search(reference):
                continue
            sibling = any(reference.startswith(prefix) for prefix in SIBLING_PREFIXES)
            if not sibling and NOT_IN_THIS_REPO.match(reference):
                continue
            # The .example is the committed half of the pair, so it is checked even though the
            # file the runbook tells you to create from it is not.
            if reference.endswith(".example") and not (REPO / reference).exists() and not (
                    UMBRELLA / reference).exists():
                problems.append(f"{doc}: refers to {reference}, which does not exist")
                continue
            # file:// paths in the aws README are relative to the repository root in some commands
            # and to deploy/aws in others, because that is where the reader is standing. Accept both
            # rather than pretending only one is correct. Sibling paths resolve at the umbrella.
            if sibling:
                candidates = [UMBRELLA / reference]
            else:
                candidates = [REPO / reference, REPO / "deploy" / "aws" / reference,
                              UMBRELLA / reference]
            checked_paths += 1
            if not any(candidate.exists() for candidate in candidates):
                problems.append(f"{doc}: refers to {reference}, which does not exist")
                continue

            found = next(c for c in candidates if c.exists())
            if found.suffix == ".json":
                checked_json += 1
                try:
                    json.loads(found.read_text(encoding="utf-8"))
                except json.JSONDecodeError as error:
                    problems.append(f"{doc}: {reference} is not valid JSON — {error}")

    # Cross-document agreement. Only worth reporting when a fact appears in more than one document,
    # since a single mention cannot disagree with anything.
    print("Identifiers, and where they appear:")
    for label, pattern in FACTS.items():
        seen: dict[str, list[str]] = {}
        for doc in DOCS:
            path = REPO / doc
            if not path.exists():
                continue
            for value in set(pattern.findall(path.read_text(encoding="utf-8"))):
                seen.setdefault(value, []).append(doc.split("/")[-1])
        if not seen:
            print(f"  {label:20} not mentioned")
            continue
        for value, docs in sorted(seen.items()):
            print(f"  {label:20} {value:24} {', '.join(sorted(docs))}")
        if label != "instance role" and len(seen) > 1:
            problems.append(
                f"{label} has {len(seen)} different values across the runbooks: "
                + ", ".join(sorted(seen))
            )

    for bearer in INSTANCE_BEARERS:
        path = REPO / bearer
        if not path.exists():
            problems.append(f"{bearer}: names the production instance but is missing")
            continue
        if KEPT_INSTANCE not in path.read_text(encoding="utf-8"):
            problems.append(
                f"{bearer}: does not name the kept instance the runbooks do ({KEPT_INSTANCE})"
            )

    print(f"\nChecked {checked_paths} referenced paths and parsed {checked_json} JSON policies.")

    if problems:
        print("\nProblems:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print("Every path the runbooks name exists, and the identifiers agree.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
