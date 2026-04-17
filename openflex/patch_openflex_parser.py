#!/usr/bin/env python3
"""Patch the installed openflex parser to accept fractional utilization values.

Vivado can emit fractional resource counts such as BRAM tile usage (for example
12.5). openflex 0.1.4 currently parses every utilization field as an integer,
which causes timing runs to fail after routing with:

    ValueError: invalid literal for int() with base 10: '12.5'

Run this script inside the same Python environment that provides the `openflex`
command. By default it locates the installed `openflex.config` module and edits
that file in place after saving a `.bak` backup beside it.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import shutil
import sys


OLD_SNIPPET = """            int_value1 = int(parts[1])
            int_value2 = int(parts[2])"""

NEW_SNIPPET = """            raw_value1 = float(parts[1])
            raw_value2 = float(parts[2])
            int_value1 = int(raw_value1) if raw_value1.is_integer() else raw_value1
            int_value2 = int(raw_value2) if raw_value2.is_integer() else raw_value2"""

PATCH_MARKER = "raw_value1 = float(parts[1])"


def resolve_target(explicit_path: str | None) -> pathlib.Path:
    if explicit_path:
        return pathlib.Path(explicit_path).expanduser().resolve()

    spec = importlib.util.find_spec("openflex.config")
    if spec is None or spec.origin is None:
        raise FileNotFoundError(
            "Could not locate installed module openflex.config. "
            "Activate the target environment first, or pass --file."
        )

    return pathlib.Path(spec.origin).resolve()


def patch_file(target: pathlib.Path) -> str:
    if not target.exists():
        raise FileNotFoundError(f"Target file does not exist: {target}")

    original = target.read_text(encoding="utf-8")

    if PATCH_MARKER in original:
        return f"Already patched: {target}"

    if OLD_SNIPPET not in original:
        raise RuntimeError(
            "Expected parser snippet was not found. "
            f"Refusing to patch unexpected file contents: {target}"
        )

    backup = target.with_suffix(target.suffix + ".bak")
    if not backup.exists():
        shutil.copy2(target, backup)

    patched = original.replace(OLD_SNIPPET, NEW_SNIPPET, 1)
    target.write_text(patched, encoding="utf-8")
    return f"Patched {target}\nBackup saved to {backup}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--file",
        help="Optional explicit path to openflex/config.py. "
        "If omitted, uses the active Python environment.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Only report the target path and whether it is already patched.",
    )
    args = parser.parse_args()

    try:
        target = resolve_target(args.file)
        text = target.read_text(encoding="utf-8")

        if args.check:
            status = "patched" if PATCH_MARKER in text else "unpatched"
            print(f"{target}: {status}")
            return 0

        print(patch_file(target))
        return 0
    except Exception as exc:  # pragma: no cover - script-style error path
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
