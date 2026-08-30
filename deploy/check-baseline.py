#!/usr/bin/env python3
"""Apply each baseline to an empty Postgres and print the numbers the CI floors are set from.

The CI jobs assert a floor on tables, seeded rows and triggers, so that a baseline someone truncated
or hand-edited fails the build rather than producing a database that starts and then behaves oddly.
Floors picked from memory are either too low to catch anything or too high to survive the next table
being added, so they come from here.

Run it after regenerating a baseline, and move any floor that has drifted.

    python deploy/check-baseline.py
"""
from __future__ import annotations

import importlib
import io
import pathlib
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
squash = importlib.import_module("squash-baseline")

BASE_TABLES = (
    "SELECT count(*) FROM information_schema.tables "
    "WHERE table_schema='public' AND table_type='BASE TABLE'"
)
USER_TRIGGERS = "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal"
EMAIL_TYPE = (
    "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a "
    "JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname='users' AND a.attname='email'"
)

QUERIES = {
    "platform": {
        "tables": BASE_TABLES,
        "partitions": "SELECT count(*) FROM pg_class WHERE relispartition",
        "permissions": "SELECT count(*) FROM permissions",
        "role_permissions": "SELECT count(*) FROM role_permissions",
        "mail_templates": "SELECT count(*) FROM mail_templates",
        "billing_plans": "SELECT count(*) FROM billing_plans",
        "triggers": USER_TRIGGERS,
    },
    "identity": {
        "tables": BASE_TABLES,
        "users.email type": EMAIL_TYPE,
        "triggers": USER_TRIGGERS,
    },
    "mobistack": {
        "tables": BASE_TABLES,
        "permissions": "SELECT count(*) FROM permissions",
        "role_permissions": "SELECT count(*) FROM role_permissions",
        "billing_plans": "SELECT count(*) FROM billing_plans",
        "triggers": USER_TRIGGERS,
    },
}


def main() -> int:
    for service, queries in QUERIES.items():
        migrations = squash.SERVICES[service]["migrations"]
        baseline = migrations / "V1__baseline.sql"
        if not baseline.exists():
            print(f"[{service}] no V1__baseline.sql -- run squash-baseline.py first")
            return 1

        print(f"--- {service} ---")
        with squash.Postgres() as pg:
            pg.create_database("check")
            pg.migrate("check", migrations, squash.SERVICES[service]["placeholders"])
            for label, sql in queries.items():
                value = squash.must(
                    ["docker", "exec", "-e", f"PGPASSWORD={squash.PASSWORD}", pg.name,
                     "psql", "-U", "postgres", "-d", "check", "-tAc", sql],
                    f"{service}: {label}",
                ).strip()
                print(f"   {label:20} {value}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
