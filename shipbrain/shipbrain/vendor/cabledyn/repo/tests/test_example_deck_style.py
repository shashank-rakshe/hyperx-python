#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Enforce the public OpenFAST-style CableDyn example-deck contract."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples"
BANNER = "--------------------- CableDyn Input File ------------------------------------"
SECTION = re.compile(r"^-+\s+([A-Z][A-Z ]*[A-Z]|[A-Z])\s+-+\s*$")

REQUIRED_TEXT = {
    "g": ("Gravitational acceleration", "(m/s^2)"),
    "rhoW": ("Water density", "(kg/m^3)"),
    "WtrDpth": ("Water depth", "(m)"),
    "kBot": ("Seabed penalty stiffness", "(Pa/m)"),
    "cBot": ("Seabed normal damping", "(Pa-s/m)"),
    "dtM": ("CableDyn internal time step", "(s)"),
    "TMax": ("Standalone simulation duration", "(s)"),
    "rhoInf": ("-alpha spectral radius", "{"),
    "modified_newton": ("Tangent-reuse mode", "{False=", "True="),
    "waves": ("Wave model", "(m, s, deg)", "{none; airy; jonswap}"),
    "current": ("Current model", "(m/s)", "{none; uniform; profile}"),
}


def model_decks() -> list[Path]:
    return sorted(
        path
        for path in EXAMPLES.rglob("*.dat")
        if path.read_text(encoding="utf-8").splitlines()[:1] == [BANNER]
    )


def option_rows(path: Path) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    in_options = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = SECTION.match(line)
        if match:
            if in_options:
                break
            in_options = match.group(1).strip() == "OPTIONS"
            continue
        if in_options and line.strip() and not line.lstrip().startswith(("#", "!", "--")):
            rows.append((number, line))
    return rows


def option_key(record: str) -> str:
    tokens = record.split()
    if tokens[0].lower() == "dynamic_solver":
        return "dynamic_solver"
    if tokens[-1] in {"waves", "current"}:
        return tokens[-1]
    return tokens[1] if len(tokens) >= 2 else ""


def output_rows(path: Path) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    in_outputs = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = SECTION.match(line)
        if match:
            if in_outputs:
                break
            in_outputs = match.group(1).strip() == "OUTPUTS"
            continue
        stripped = line.strip()
        if in_outputs and stripped and not line.lstrip().startswith(("#", "!", "--")):
            if stripped.lower() == "end":
                break
            rows.append((number, line))
    return rows


class ExampleDeckStyleTests(unittest.TestCase):
    def test_all_model_decks_use_described_options(self) -> None:
        decks = model_decks()
        self.assertGreater(len(decks), 20)
        for path in decks:
            rows = option_rows(path)
            self.assertTrue(rows, f"{path.relative_to(ROOT)} has no OPTIONS records")
            for number, line in rows:
                where = f"{path.relative_to(ROOT)}:{number}"
                self.assertIn(" - ", line, f"{where}: expected 'value key - Description'")
                record, description = line.split(" - ", 1)
                self.assertTrue(description.strip(), f"{where}: empty description")
                self.assertNotIn("(-)", description, f"{where}: omit empty dimensionless units")
                key = option_key(record)
                self.assertTrue(key, f"{where}: missing option key")
                if key == "modified_newton":
                    self.assertIn(record.split()[0], {"True", "False"}, f"{where}: capitalize boolean")
                for required in REQUIRED_TEXT.get(key, ()):
                    self.assertIn(required, description, f"{where}: missing {required!r}")

    def test_all_model_decks_show_common_defaults(self) -> None:
        required = {
            "g",
            "rhoW",
            "kBot",
            "cBot",
            "rhoInf",
            "modified_newton",
            "adaptive_mesh",
            "dynamic_solver",
            "frictionMu",
            "current",
            "waves",
            "WaterKin",
        }
        for path in model_decks():
            keys = {option_key(line.split(" - ", 1)[0]) for _number, line in option_rows(path)}
            self.assertEqual(
                required - keys,
                set(),
                f"{path.relative_to(ROOT)} does not expose every common/default option",
            )

    def test_no_model_deck_carries_the_retired_icmode_row(self) -> None:
        for path in model_decks():
            keys = {option_key(line.split(" - ", 1)[0]).lower() for _number, line in option_rows(path)}
            self.assertNotIn("icmode", keys, f"{path.relative_to(ROOT)} still carries an ICmode row")

    def test_option_reference_names_every_supported_keyword(self) -> None:
        text = (EXAMPLES / "cabledyn_options_reference.dat").read_text(encoding="utf-8").lower()
        for keyword in (
            "bathymetryfile",
            "motionfile",
            "dtm",
            "tmax",
            "dynamic_solver",
            "adaptive_mesh",
            "waterkin",
            "tscheme",
            "dtic",
            "tmaxic",
            "cdscaleic",
            "threshic",
            "writelog",
            "dtout",
            "currents",
        ):
            # a whole keyword token: "tmax" must not be satisfied by "tmaxic"
            self.assertRegex(text, r"(?<![\w])%s(?![\w])" % re.escape(keyword), keyword)

    def test_output_channels_are_individually_quoted(self) -> None:
        for path in model_decks():
            rows = output_rows(path)
            self.assertTrue(rows, f"{path.relative_to(ROOT)} has no OUTPUTS channels")
            for number, line in rows:
                where = f"{path.relative_to(ROOT)}:{number}"
                self.assertRegex(line.strip(), r'^"[^"\s]+"$', f"{where}: quote one channel per row")

    def test_syrope_settings_use_the_same_comment_layout(self) -> None:
        path = EXAMPLES / "data" / "syrope" / "syrope_settings.dat"
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip() and not line.lstrip().startswith(("#", "!", "--")):
                self.assertIn(" - ", line, f"{path.relative_to(ROOT)}:{number}")
        self.assertIn("{LINEAR; QUADRATIC; EXP}", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
