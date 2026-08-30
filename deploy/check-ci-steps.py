#!/usr/bin/env python3
"""Run the `migrations` job's shell steps out of the workflow files, against a real Postgres.

The seed scripts are covered by check-seed.py in each repository. This covers the other half, which
is easy to forget: the assertions in CI are a few hundred lines of bash and SQL that nothing runs
until a push, and a typo in them fails the build for a reason that has nothing to do with the change
that triggered it. Worse, a typo in the wrong place — an `expect` that compares two things that are
both empty — passes, and the check silently protects nothing from then on.

So the steps are read out of the YAML and executed verbatim, in order, in a container where
localhost:5432 is the database, which is the shape they assume on a runner. Nothing is transcribed,
because a copy of the assertions here would be the thing that rots.

Covers all three repositories, since the assertions are the same shape in each and one of them — the
owner id the platform and identity seeds must agree on — only means anything when both are read
together. That makes this an umbrella tool: it needs Identity and MobiStack checked out beside this
repository, and says so rather than failing on a missing path.

Needs Docker and PyYAML.

    python deploy/check-ci-steps.py
"""
from __future__ import annotations

import io
import pathlib
import subprocess
import sys
import time
import uuid

import yaml

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

UMBRELLA = pathlib.Path(__file__).resolve().parent.parent.parent
CLIENT_IMAGE = "postgres:16"

# Each repository, its workflow, and the directory the job runs from. The `migrations` job declares
# no working-directory, so that is the repository root in every case.
REPOS = [
    ("Platform", "Platform/.github/workflows/ci.yml"),
    ("Identity", "Identity/.github/workflows/ci.yml"),
    ("MobiStack", "MobiStack/.github/workflows/build.yml"),
]


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", **kwargs)


class Postgres:
    """A throwaway server, plus a client container sharing its network namespace.

    The steps say `-h localhost` because that is what a service container looks like from a runner.
    Rather than rewrite them, the client joins the server's namespace with --network container:, so
    localhost means the same thing here as it does there.
    """

    def __init__(self):
        self.name = f"ci-steps-{uuid.uuid4().hex[:8]}"

    def __enter__(self):
        run(["docker", "run", "-d", "--rm", "--name", self.name,
             "-e", "POSTGRES_PASSWORD=ci",
             "-e", "POSTGRES_DB=schemacheck",
             "-e", "POSTGRES_INITDB_ARGS=--encoding=UTF8",
             "postgres:16-alpine"])
        # A real query rather than pg_isready, which answers for the temporary server the official
        # image runs during initdb and so reports ready seconds before the real one is listening.
        for _ in range(60):
            probe = run(["docker", "exec", "-e", "PGPASSWORD=ci", self.name,
                         "psql", "-U", "postgres", "-d", "schemacheck", "-tAc", "SELECT 1"])
            if probe.returncode == 0 and probe.stdout.strip() == "1":
                return self
            time.sleep(1)
        raise RuntimeError("postgres did not become ready")

    def __exit__(self, *exc):
        run(["docker", "stop", self.name])

    def reset(self):
        for sql in ('DROP DATABASE IF EXISTS schemacheck', 'CREATE DATABASE schemacheck'):
            result = run(["docker", "exec", "-e", "PGPASSWORD=ci", self.name,
                          "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
                          "-c", sql])
            if result.returncode != 0:
                raise RuntimeError(f"{sql}: {result.stderr}")

    def bash(self, script: str, repo_root: pathlib.Path, env: dict[str, str]):
        # Mounted at a fixed Linux path rather than the host path: a Windows path is not a valid
        # working directory inside a container, and the steps only ever use paths relative to the
        # repository root anyway.
        args = ["docker", "run", "--rm",
                # Shares the server's namespace, so `-h localhost` in the step resolves to it.
                "--network", f"container:{self.name}",
                "-v", f"{repo_root}:/repo:ro".replace("\\", "/"),
                "-w", "/repo",
                "--entrypoint", "bash"]
        for key, value in env.items():
            args += ["-e", f"{key}={value}"]
        args += [CLIENT_IMAGE, "-c", script]
        return run(args)


def steps_of(workflow: pathlib.Path):
    job = yaml.safe_load(workflow.read_text(encoding="utf-8"))["jobs"]["migrations"]
    for step in job["steps"]:
        if "run" in step:
            yield step.get("name", "(unnamed)"), step["run"], step.get("env", {})


def main() -> int:
    missing = [repo for repo, workflow in REPOS if not (UMBRELLA / workflow).exists()]
    if missing:
        print(f"Not checked out beside this repository: {', '.join(missing)}")
        print(f"Expected them under {UMBRELLA}. Clone them there, or run each repository's own CI.")
        return 1

    failures = []

    with Postgres() as pg:
        for repo, workflow in REPOS:
            root = UMBRELLA / repo
            print(f"\n{'=' * 78}\n{repo}\n{'=' * 78}")
            pg.reset()

            for name, script, env in steps_of(UMBRELLA / workflow):
                if "docker run" in script:
                    # The flyway step shells out to `docker run -v "$PWD/..."`, and $PWD inside this
                    # container is a path the host daemon cannot see. Run it from the host instead,
                    # which is the same command with the same mount.
                    print(f"  {name}: running flyway from the host")
                    migrations = root / ("src" if repo == "Identity" else "backend/src")
                    migrations = migrations / "main/resources/db/migration"
                    result = run(["docker", "run", "--rm", "--network", f"container:{pg.name}",
                                  "-v", f"{migrations}:/flyway/sql:ro",
                                  "flyway/flyway:11-alpine",
                                  "-url=jdbc:postgresql://localhost:5432/schemacheck",
                                  "-user=postgres", "-password=ci",
                                  "-locations=filesystem:/flyway/sql",
                                  *(["-placeholderReplacement=false"] if repo == "Platform" else []),
                                  "-connectRetries=10", "migrate"])
                else:
                    result = pg.bash(script, root, env)

                if result.returncode == 0:
                    print(f"  PASS  {name}")
                    for line in result.stdout.strip().splitlines():
                        if line.strip():
                            print(f"          {line}")
                else:
                    print(f"  FAIL  {name}")
                    print((result.stdout + result.stderr).strip()[-2500:])
                    failures.append(f"{repo}: {name}")
                    break

    print("\n" + "=" * 78)
    if failures:
        print("Failed steps:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("Every migrations-job step passes as written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
