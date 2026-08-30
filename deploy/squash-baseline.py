#!/usr/bin/env python3
"""Collapse a service's Flyway history into one V1__baseline.sql, and prove the result is identical.

Why generate it rather than write it: between them the three services use partitioned tables,
generated columns, citext, trigram indexes, functions, triggers, and twenty-five migrations whose
only purpose is to seed rows -- email templates, permission names, plan definitions. Every one of
those is easy to leave out of a hand-written baseline, and leaving one out produces a schema that
starts fine and misbehaves later.

So the baseline is a dump of what the migrations actually produce:

  1. run every existing migration against an empty Postgres
  2. dump it -- schema and seeded rows together, in pg_dump's own order
  3. run the generated baseline against a second empty database
  4. dump that too, and require the two to match

Step 4 is the point. Without it this is a plausible-looking file nobody has checked. It has already
earned its keep twice: pg_dump 16.15 emits \\restrict meta-commands that only psql understands, and
a schema-only dump followed by a data-only dump installs foreign keys before the rows they check.
Both produced a baseline that looked entirely reasonable and would not run.

Safe to run: it only writes the baseline. Deleting the old migrations is a separate, deliberate step
worth taking only after this reports OK -- see deploy/RUNBOOK-rds.md.

    python deploy/squash-baseline.py --service platform
    python deploy/squash-baseline.py --service all
"""
from __future__ import annotations

import argparse
import difflib
import pathlib
import re
import subprocess
import sys
import time
import uuid

UMBRELLA = pathlib.Path(__file__).resolve().parents[2]

POSTGRES_IMAGE = "postgres:16-alpine"
FLYWAY_IMAGE = "flyway/flyway:11-alpine"

SERVICES = {
    "platform": {
        "migrations": UMBRELLA / "Platform/backend/src/main/resources/db/migration",
        # Platform seeds Thymeleaf templates whose bodies contain ${...}, which Flyway would
        # otherwise try to resolve as its own placeholders and fail on. Mirrors
        # spring.flyway.placeholder-replacement: false in its application.yml.
        "placeholders": False,
    },
    "identity": {
        "migrations": UMBRELLA / "Identity/src/main/resources/db/migration",
        "placeholders": True,
    },
    "mobistack": {
        "migrations": UMBRELLA / "MobiStack/backend/src/main/resources/db/migration",
        "placeholders": True,
    },
}

PASSWORD = "squash"


def run(args: list[str]) -> subprocess.CompletedProcess:
    # encoding is explicit because text=True alone decodes with the locale codec, which on Windows is
    # cp1252 and cannot represent the dump: the seeded email templates contain em dashes and other
    # non-Latin-1 characters, and the decode fails part-way through a 370 kB dump.
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="strict")


def must(args: list[str], what: str) -> str:
    result = run(args)
    if result.returncode != 0:
        print(f"FAILED: {what}\n$ {' '.join(args)}\n{result.stdout}\n{result.stderr}")
        sys.exit(1)
    return result.stdout


class Postgres:
    """A throwaway Postgres on its own network, so Flyway can reach it by container name."""

    def __init__(self) -> None:
        suffix = uuid.uuid4().hex[:8]
        self.name = f"squash-pg-{suffix}"
        self.network = f"squash-net-{suffix}"

    def __enter__(self) -> "Postgres":
        must(["docker", "network", "create", self.network], "create network")
        must(
            [
                "docker", "run", "-d", "--name", self.name,
                "--network", self.network,
                "-e", f"POSTGRES_PASSWORD={PASSWORD}",
                # Explicit so the dump is decodable as UTF-8 whatever the host locale hands initdb.
                "-e", "POSTGRES_INITDB_ARGS=--encoding=UTF8",
                POSTGRES_IMAGE,
            ],
            "start postgres",
        )
        for _ in range(90):
            if run(["docker", "exec", self.name, "pg_isready", "-U", "postgres"]).returncode == 0:
                return self
            time.sleep(1)
        print("Postgres did not become ready")
        self.__exit__()
        sys.exit(1)

    def __exit__(self, *_) -> None:
        run(["docker", "rm", "-f", self.name])
        run(["docker", "network", "rm", self.network])

    def create_database(self, database: str) -> None:
        must(
            ["docker", "exec", "-e", f"PGPASSWORD={PASSWORD}", self.name,
             "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
             "-c", f'CREATE DATABASE "{database}"'],
            f"create database {database}",
        )

    def dump(self, database: str) -> str:
        """One dump containing both schema and rows.

        Deliberately not --schema-only plus --data-only. A plain pg_dump emits table definitions,
        then the rows, then indexes and constraints; taking the two halves separately puts every
        foreign key in place before any row exists, and the seed data then fails to load in whatever
        order pg_dump happened to choose.

        --column-inserts rather than COPY because Flyway sends each statement over JDBC, and
        `COPY ... FROM stdin` is a psql feature -- the protocol-level COPY it stands for is not
        something a JDBC statement can carry. Naming the columns also makes the file survive a
        column being added in the middle of a table later on.
        """
        return must(
            [
                "docker", "exec", "-e", f"PGPASSWORD={PASSWORD}", self.name,
                "pg_dump", "-U", "postgres", "-d", database,
                "--no-owner", "--no-privileges", "--no-comments", "--column-inserts",
                # Flyway recreates its own table. Dumping it would make the baseline assert that the
                # migrations had already run, so a fresh database would skip its own baseline.
                "--exclude-table=flyway_schema_history",
            ],
            f"pg_dump {database}",
        )

    def migrate(self, database: str, migrations: pathlib.Path, placeholders: bool) -> None:
        args = [
            "docker", "run", "--rm", "--network", self.network,
            "-v", f"{migrations}:/flyway/sql:ro",
            FLYWAY_IMAGE,
            f"-url=jdbc:postgresql://{self.name}:5432/{database}",
            "-user=postgres",
            f"-password={PASSWORD}",
            "-locations=filesystem:/flyway/sql",
            "-connectRetries=10",
        ]
        if not placeholders:
            args.append("-placeholderReplacement=false")
        args.append("migrate")
        must(args, f"flyway migrate into {database}")


# pg_dump opens with SET statements and a search_path reset: harmless to psql, noise in a migration,
# and `SET search_path = ''` would quietly break any unqualified name a later hand edit introduces.
NOISE = re.compile(r"^(SET |SELECT pg_catalog\.set_config|--|\s*$)")

# Since the August 2025 security releases pg_dump wraps its output in \restrict and \unrestrict,
# which stop psql expanding meta-commands hidden in dumped object names. They are psql directives,
# so Postgres rejects them outright when Flyway sends the file statement by statement.
PSQL_META = re.compile(r"^\\")


def clean(dump: str) -> str:
    """Strip the psql-only parts, and the preamble, leaving something Flyway can execute."""
    body: list[str] = []
    for line in dump.splitlines():
        if PSQL_META.match(line):
            continue
        if not body and NOISE.match(line):
            continue
        body.append(line)
    return "\n".join(body).strip() + "\n"


def canonical_in_lists(line: str) -> str:
    """Render `x = ANY (...)` as just its literals, so the two spellings of one CHECK compare equal.

    A migration writing `CHECK (status IN ('ACTIVE', 'LOCKED'))` is stored by Postgres as

        status::text = ANY ((ARRAY['ACTIVE'::character varying, 'LOCKED'::character varying])::text[])

    pg_dump prints that back faithfully, but on re-parsing Postgres distributes the cast over the
    elements instead of applying it to the array:

        status::text = ANY (ARRAY[('ACTIVE'::character varying)::text, ('LOCKED'::character varying)::text])

    Same constraint, same allowed values, different text -- and it is the round trip itself that
    changes it, so it appears for every enum-ish CHECK in all three services. The allowed literals
    are the content; where the cast sits is not. Collapsing to the literals keeps a changed, added or
    dropped value visible while ignoring the spelling.
    """
    marker = "= ANY ("
    out = line
    search_from = 0
    while True:
        start = out.find(marker, search_from)
        if start == -1:
            return out
        open_paren = start + len(marker) - 1
        depth = 0
        end = -1
        for i in range(open_paren, len(out)):
            if out[i] == "(":
                depth += 1
            elif out[i] == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end == -1:
            return out
        span = out[open_paren : end + 1]
        literals = re.findall(r"'((?:[^']|'')*)'", span)
        replacement = "= ANY (" + ", ".join(f"'{value}'" for value in literals) + ")"
        out = out[:start] + replacement + out[end + 1 :]
        search_from = start + len(replacement)


def normalise(dump: str) -> str:
    """Drop what differs between two dumps for reasons that are not the schema or the rows."""
    out = []
    for line in dump.splitlines():
        if NOISE.match(line) or PSQL_META.match(line):
            continue
        # Sequence positions depend on how the rows arrived -- a serial advanced once per INSERT
        # here, but was set explicitly by the migration that seeded it there. The rows themselves
        # are compared, which is what actually matters.
        if line.startswith("SELECT pg_catalog.setval"):
            continue
        out.append(canonical_in_lists(line.rstrip()))
    return "\n".join(out)


HEADER = """-- Baseline schema for {service}.
--
-- Generated by deploy/squash-baseline.py from the {count} migrations it replaces, by running them
-- against an empty Postgres 16 and dumping the result, then replaying this file into a second empty
-- database and requiring the two dumps to match. Do not hand-edit: regenerate, or add a V2.
--
-- Extensions are created with IF NOT EXISTS, which works whoever runs this. citext, pgcrypto,
-- pg_trgm and unaccent are all trusted extensions, so the owner of the database can install them
-- without being a superuser; and where an administrator has created them already, these statements
-- skip with a notice rather than checking a privilege. See deploy/RUNBOOK-rds.md.
--
-- A database that already ran the old V1 will fail validation against this file, because the
-- checksum for version 1 has changed. That is intended: these databases are being recreated, and a
-- developer's local copy wants dropping rather than migrating.
"""

def summarise(baseline: str) -> str:
    tables = len(re.findall(r"^CREATE TABLE ", baseline, re.M))
    indexes = len(re.findall(r"^CREATE (UNIQUE )?INDEX ", baseline, re.M))
    rows = len(re.findall(r"^INSERT INTO ", baseline, re.M))
    return f"{tables} tables, {indexes} indexes, {rows} seeded rows"


def squash(service: str) -> bool:
    config = SERVICES[service]
    migrations: pathlib.Path = config["migrations"]
    existing = sorted(migrations.glob("*.sql"))
    baseline_path = migrations / "V1__baseline.sql"

    if baseline_path.exists():
        print(f"[{service}] V1__baseline.sql already present -- remove it to regenerate")
        return True

    print(f"[{service}] squashing {len(existing)} migrations")

    with Postgres() as pg:
        pg.create_database("from_history")
        pg.migrate("from_history", migrations, config["placeholders"])
        from_history = pg.dump("from_history")

        baseline = HEADER.format(service=service, count=len(existing))
        baseline += "\n" + clean(from_history)
        baseline_path.write_text(baseline, encoding="utf-8", newline="\n")
        print(f"[{service}] wrote V1__baseline.sql: {summarise(baseline)}, {len(baseline):,} bytes")

        # The verification. A baseline nobody replayed is a guess. Staged outside the migration
        # directory so Flyway sees only the baseline, not the history it is meant to replace.
        pg.create_database("from_baseline")
        staging = migrations.parent / f"_squash_check_{service}"
        staging.mkdir(exist_ok=True)
        try:
            (staging / "V1__baseline.sql").write_text(baseline, encoding="utf-8", newline="\n")
            pg.migrate("from_baseline", staging, config["placeholders"])
            from_baseline = pg.dump("from_baseline")
        finally:
            for child in staging.iterdir():
                child.unlink()
            staging.rmdir()

    if normalise(from_history) == normalise(from_baseline):
        print(f"[{service}] verified: replaying the baseline reproduces the history exactly")
        return True

    diff = list(
        difflib.unified_diff(
            normalise(from_history).splitlines(),
            normalise(from_baseline).splitlines(),
            "from_history",
            "from_baseline",
            lineterm="",
        )
    )
    print(f"[{service}] MISMATCH ({len(diff)} diff lines, first 60 shown):")
    print("\n".join(diff[:60]))
    baseline_path.unlink()
    print(f"[{service}] baseline removed -- the migration history is still the source of truth")
    return False


def self_test() -> int:
    """Check the one piece of judgement in this tool: what the comparison agrees to ignore.

    canonical_in_lists is the only place the verification is deliberately made less strict, so it is
    the only place a real schema difference could slip through unnoticed. Everything else is a
    byte-for-byte comparison of two dumps.
    """
    varchar = "::character varying"
    array_cast = (
        "    CONSTRAINT ck_users_status CHECK (((status)::text = ANY ((ARRAY["
        f"'ACTIVE'{varchar}, 'INVITED'{varchar}, 'LOCKED'{varchar}])::text[])))"
    )
    element_cast = (
        "    CONSTRAINT ck_users_status CHECK (((status)::text = ANY (ARRAY[("
        f"'ACTIVE'{varchar})::text, ('INVITED'{varchar})::text, ('LOCKED'{varchar})::text])))"
    )
    plain = "    email public.citext NOT NULL,"
    two_clauses = (
        f"CHECK (a::text = ANY ((ARRAY['X'{varchar}])::text[]) AND "
        f"b::text = ANY ((ARRAY['Y'{varchar}])::text[]))"
    )
    apostrophe = f"CHECK (x::text = ANY ((ARRAY['it''s'{varchar}, 'ok'{varchar}])::text[]))"

    cases = [
        ("the two spellings of one CHECK collapse together",
         canonical_in_lists(array_cast) == canonical_in_lists(element_cast)),
        ("a changed allowed value still differs",
         canonical_in_lists(array_cast)
         != canonical_in_lists(element_cast.replace("'LOCKED'", "'BANNED'"))),
        ("a dropped allowed value still differs",
         canonical_in_lists(array_cast)
         != canonical_in_lists(element_cast.replace(f"('LOCKED'{varchar})::text", ""))),
        ("an added allowed value still differs",
         canonical_in_lists(array_cast)
         != canonical_in_lists(element_cast.replace("'LOCKED'", "'LOCKED', 'EXTRA'"))),
        ("a line with no ANY clause is untouched", canonical_in_lists(plain) == plain),
        ("both clauses on one line are collapsed",
         canonical_in_lists(two_clauses) == "CHECK (a::text = ANY ('X') AND b::text = ANY ('Y'))"),
        ("an escaped quote inside a literal survives",
         canonical_in_lists(apostrophe) == "CHECK (x::text = ANY ('it''s', 'ok'))"),
        ("psql meta-commands are dropped",
         normalise("\\restrict abc\nCREATE TABLE x ();") == "CREATE TABLE x ();"),
        ("a real table difference survives normalise",
         normalise("CREATE TABLE a ();") != normalise("CREATE TABLE b ();")),
    ]

    failed = 0
    for description, passed in cases:
        print(f"  {'ok  ' if passed else 'FAIL'}  {description}")
        failed += 0 if passed else 1
    print("self-test passed" if not failed else f"{failed} self-test case(s) failed")
    return 0 if not failed else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", choices=[*SERVICES, "all"])
    parser.add_argument("--self-test", action="store_true", help="check the dump comparison only")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.service:
        parser.error("--service is required unless --self-test is given")

    services = list(SERVICES) if args.service == "all" else [args.service]
    ok = True
    for service in services:
        if not squash(service):
            ok = False
        print()
    if ok:
        print("Baselines verified. The old migrations can now go -- see deploy/RUNBOOK-rds.md.")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
