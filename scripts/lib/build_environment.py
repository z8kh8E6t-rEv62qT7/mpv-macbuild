#!/usr/bin/env python3
"""Read the build environment declaration; never evaluate or emit shell code."""

import json
from pathlib import Path
import re
import sys
from typing import TypedDict


class EnvironmentVariable(TypedDict):
    github_env: bool
    superbuild: str
    required: list[str]
    allow_empty: bool


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate declaration key: {key}")
        result[key] = value
    return result


def read_declarations() -> dict[str, EnvironmentVariable]:
    path = Path(__file__).with_name("build-environment.json")
    declarations = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(declarations, dict) or not declarations:
        raise ValueError("environment declaration must be a nonempty object")
    fields = {"github_env", "superbuild", "required", "allow_empty"}
    stages = {"source", "superbuild", "cmake"}
    for name, entry in declarations.items():
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name):
            raise ValueError(f"invalid environment variable name: {name}")
        if not isinstance(entry, dict) or set(entry) != fields:
            raise ValueError(f"{name}: expected fields {sorted(fields)}")
        if not isinstance(entry["github_env"], bool) or not isinstance(entry["allow_empty"], bool):
            raise ValueError(f"{name}: github_env and allow_empty must be booleans")
        if entry["superbuild"] not in ("none", "environment", "cmake"):
            raise ValueError(f"{name}: invalid superbuild source")
        required = entry["required"]
        if not isinstance(required, list) or any(
            not isinstance(stage, str) or stage not in stages for stage in required
        ):
            raise ValueError(f"{name}: invalid required stages")
        if len(required) != len(set(required)):
            raise ValueError(f"{name}: duplicate required stage")
    return declarations


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("github", "source", "superbuild"):
        print("usage: build_environment.py <github|source|superbuild>", file=sys.stderr)
        return 2
    try:
        declarations = read_declarations()
    except (OSError, ValueError) as exc:
        print(f"error: build environment declaration: {exc}", file=sys.stderr)
        return 1
    stage = sys.argv[1]
    for name, entry in declarations.items():
        if stage == "github":
            if entry["github_env"]:
                print(name)
        elif stage in entry["required"]:
            print(f"{name}\t{int(entry['allow_empty'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
