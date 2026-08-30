#!/usr/bin/env python3
"""Check what surefire is actually configured with, in both profiles, in all three backends.

Two settings here fail silently when they are wrong, which is why this exists rather than a comment
claiming they are right:

  * `argLine` carries the Mockito agent. Lose it and the tests still pass — Mockito falls back to
    attaching itself to the running JVM, prints a warning nobody reads, and keeps working right up
    until the JDK release that refuses it.
  * `excludedGroups` decides whether the Testcontainers tests run. Lose the override and the
    integration profile excludes the very tests it exists to include, which is indistinguishable
    from those tests passing: same exit code, same green tick, no output saying they were skipped.

Both are decided by Maven's POM merge rules, which are not obvious for an empty element or a profile
that redeclares a plugin, and which no amount of reading the pom will confirm. So the effective pom
is generated and read instead.

    python deploy/check-surefire.py
"""
from __future__ import annotations

import io
import pathlib
import re
import subprocess
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

UMBRELLA = pathlib.Path(__file__).resolve().parent.parent.parent

BACKENDS = [
    ("Platform", UMBRELLA / "Platform" / "backend"),
    ("Identity", UMBRELLA / "Identity"),
    ("MobiStack", UMBRELLA / "MobiStack" / "backend"),
]

# What each profile must look like. The agent is required in both — integration tests use Mockito
# too — and excludedGroups is the difference between them.
EXPECTED = {
    "default": {"agent": True, "excluded": "integration"},
    "integration": {"agent": True, "excluded": None},
}

SUREFIRE = re.compile(
    r"<artifactId>maven-surefire-plugin</artifactId>(.*?)(?=<artifactId>|</plugins>)", re.S
)


def surefire_config(project: pathlib.Path, profile: str) -> tuple[str | None, str | None]:
    output = project / "target" / f"effective-{profile}.xml"
    output.parent.mkdir(parents=True, exist_ok=True)

    command = ["mvn", "-q", "help:effective-pom", f"-Doutput={output}"]
    if profile != "default":
        command.append(f"-P{profile}")

    result = subprocess.run(command, cwd=project, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", shell=True)
    if not output.exists():
        raise RuntimeError(f"help:effective-pom produced nothing\n{result.stdout}{result.stderr}")

    text = output.read_text(encoding="utf-8")
    agent = excluded = None
    for block in SUREFIRE.findall(text):
        found_agent = re.search(r"<argLine>(.*?)</argLine>", block)
        if found_agent:
            agent = found_agent.group(1)
        # An empty <excludedGroups/> and a missing one mean the same thing to surefire, and both
        # read as "nothing excluded" here.
        found_excluded = re.search(r"<excludedGroups>([^<]+)</excludedGroups>", block)
        if found_excluded:
            excluded = found_excluded.group(1)
    return agent, excluded


def main() -> int:
    problems = []

    for name, project in BACKENDS:
        print(f"\n{name}")
        for profile, expected in EXPECTED.items():
            agent, excluded = surefire_config(project, profile)

            wants_agent = expected["agent"]
            has_agent = agent is not None and "mockito-core" in agent
            print(f"  {profile:12} agent={'yes' if has_agent else 'NO':3}  "
                  f"excludedGroups={excluded!r}")

            if wants_agent and not has_agent:
                problems.append(
                    f"{name}/{profile}: no Mockito agent on the command line (argLine={agent!r}). "
                    f"Mockito will self-attach, which a future JDK refuses."
                )
            if excluded != expected["excluded"]:
                problems.append(
                    f"{name}/{profile}: excludedGroups is {excluded!r}, expected "
                    f"{expected['excluded']!r}. "
                    + ("Integration tests are excluded from the profile that runs them, which looks "
                       "exactly like them passing." if profile == "integration"
                       else "Integration tests will run without Docker configured.")
                )

    print()
    if problems:
        print("Problems:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print("All three backends load the agent up front, in both profiles, and select the right tests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
