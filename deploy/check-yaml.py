#!/usr/bin/env python3
"""Fail on duplicate mapping keys in YAML.

PyYAML, Compose and Spring all accept a mapping that declares the same key twice, and all three
silently keep the last one. In a compose file that means a second `environment:` block deletes the
first; in application.yml a second `server:` deletes the port. Neither shows up as an error, and
both are the kind of thing that is only noticed in production.

Usage: python check-yaml.py FILE [FILE ...]
"""
from __future__ import annotations

import sys

import yaml


class DuplicateKeyError(Exception):
    pass


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping with a repeated key."""


def _no_duplicates(loader: StrictLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    mapping: dict = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise DuplicateKeyError(
                f"line {key_node.start_mark.line + 1}: duplicate key {key!r} "
                f"— the later one silently wins and the earlier block is discarded"
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates
)

# Compose's merge tags are not YAML; they exist only for its own overlay semantics. Treated as
# transparent so this script can read the same files Compose does.
for tag in ("!override", "!reset"):
    StrictLoader.add_constructor(tag, lambda loader, node: None)


def check(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            list(yaml.load_all(handle, Loader=StrictLoader))
    except (DuplicateKeyError, yaml.YAMLError) as exc:
        return str(exc).replace("\n", " ")
    return None


def main(paths: list[str]) -> int:
    failed = False
    for path in paths:
        problem = check(path)
        if problem:
            failed = True
            print(f"FAIL {path}\n     {problem}")
        else:
            print(f"ok   {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1:]))
