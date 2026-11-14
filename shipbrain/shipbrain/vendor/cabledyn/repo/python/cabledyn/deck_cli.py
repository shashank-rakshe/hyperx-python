# SPDX-License-Identifier: Apache-2.0
"""Command-line validation, editing, and case generation for CableDyn decks.

``cabledyn-deck set DECK OUTPUT SELECTOR VALUE`` parses ``VALUE`` as a JSON
scalar (number, string, Boolean) or JSON list, and otherwise as a plain
string; JSON ``null`` and objects are rejected. Negative numbers such as
``-1e-3`` are taken as values, not options. Case specs for ``generate`` are
JSON objects whose keys must be unique.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import sys
from pathlib import Path

from cabledyn.deck_file import DeckFile, generate_deck_cases
from cabledyn.errors import DeckFormatError

# argparse treats any argument that starts with "-" as an option unless it
# matches this pattern; accept every JSON/Fortran-style negative number.
_NEGATIVE_NUMBER = re.compile(
    r"^-(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eEdD][+-]?[0-9]+)?$|^-(?:inf|infinity|nan)$",
    re.IGNORECASE,
)


def _value(text: str) -> object:
    """Interpret a command-line value as JSON when possible, else as a string."""
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return text
    if value is None or isinstance(value, dict):
        raise ValueError(f"value {text!r} must be a JSON scalar or list, not null or an object")
    return value


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """``json`` object hook that rejects duplicate keys instead of keeping the last."""
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key {key!r} in case spec")
        result[key] = value
    return result


def _refuse_source_target(source: Path, target: str | os.PathLike[str]) -> None:
    """Refuse an output path that names the source deck itself."""
    candidate = Path(target).expanduser()
    same = candidate.resolve() == source.resolve()
    if not same and candidate.exists():
        with contextlib.suppress(OSError):
            same = os.path.samefile(candidate, source)
    if same:
        raise ValueError(f"output must not replace the source deck: {source}")


def _message(exc: BaseException) -> str:
    if isinstance(exc, KeyError) and exc.args:
        return str(exc.args[0])
    return str(exc)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cabledyn-deck",
        description="Validate, inspect, edit, or generate CableDyn input decks.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate", help="validate structure and cross-references")
    validate.add_argument("deck")

    show = subparsers.add_parser("show", help="print a compact deck inventory")
    show.add_argument("deck")

    edit = subparsers.add_parser("set", help="change one selector and write a new deck")
    edit.add_argument("deck")
    edit.add_argument("output")
    edit.add_argument("selector")
    edit.add_argument(
        "value",
        help="JSON scalar/list or plain string; negative numbers are accepted as-is",
    )
    edit.add_argument("--overwrite", action="store_true")
    edit._negative_number_matcher = _NEGATIVE_NUMBER

    generate = subparsers.add_parser("generate", help="generate cases from a JSON mapping")
    generate.add_argument("deck")
    generate.add_argument("spec", help="JSON object: case name -> selector/value object")
    generate.add_argument("output_directory")
    generate.add_argument("--overwrite", action="store_true")

    for command in (validate, show, edit, generate):
        command.add_argument(
            "--caller-driven",
            action="store_true",
            help="validate using the OpenFAST/host-owned marching-clock contract",
        )

    args = parser.parse_args(argv)
    try:
        deck = DeckFile.read(args.deck, caller_driven=args.caller_driven)
        if args.command == "validate":
            print(f"valid: {deck.path}")
        elif args.command == "show":
            print(f"deck: {deck.path}")
            print(f"line_types: {len(deck.line_types)}")
            print(f"points: {len(deck.points)}")
            print(f"lines: {len(deck.lines)}")
            print(f"sections: {len(deck.sections)}")
            print(f"end_connections: {len(deck.end_connections)}")
            print(f"options: {len(deck.options)}")
            print(f"outputs: {len(deck.outputs)}")
        elif args.command == "set":
            _refuse_source_target(deck.path, args.output)
            deck.apply(args.selector, _value(args.value))
            print(deck.write(args.output, overwrite=args.overwrite))
        else:
            with open(args.spec, encoding="utf-8") as stream:
                cases = json.load(stream, object_pairs_hook=_unique_object)
            if not isinstance(cases, dict) or any(
                not isinstance(value, dict) for value in cases.values()
            ):
                raise ValueError("case spec must map each case name to a selector/value object")
            generated = generate_deck_cases(
                deck.path,
                args.output_directory,
                cases,
                overwrite=args.overwrite,
                caller_driven=args.caller_driven,
            )
            for case in generated:
                print(case.deck)
    except (DeckFormatError, OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"cabledyn-deck: {_message(exc)}\n")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
