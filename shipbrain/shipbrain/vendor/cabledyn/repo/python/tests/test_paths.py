# SPDX-License-Identifier: Apache-2.0
"""Gates for the reserved Windows device-name rule shared by the readers."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from cabledyn._paths import windows_device_component


@pytest.mark.parametrize(
    ("path", "component"),
    [
        ("CON", "CON"),
        ("con.txt", "con.txt"),
        ("data/nul.dat", "nul.dat"),
        ("data\\Aux", "Aux"),
        ("prn .out", "prn .out"),
        ("COM1", "COM1"),
        ("lpt9.log", "lpt9.log"),
        ("COM¹", "COM¹"),
        ("CON:", "CON:"),
        ("conin$", "conin$"),
        ("CONOUT$.txt", "CONOUT$.txt"),
        (Path("run") / "com3", "com3"),
    ],
)
def test_reserved_device_components_are_found_on_windows(path, component):
    assert windows_device_component(path, windows=True) == component


@pytest.mark.parametrize("path", ["\\\\.\\PhysicalDrive0", "//./pipe/x"])
def test_device_namespace_paths_are_refused(path):
    assert windows_device_component(path, windows=True) == path


@pytest.mark.parametrize(
    "path",
    [
        "deck.dat",
        "console.dat",
        "com10",
        "com0",
        "lpt",
        "nulls/run.out",
        "auxiliary.txt",
        "",
    ],
)
def test_ordinary_names_are_not_devices(path):
    assert windows_device_component(path, windows=True) is None


def test_other_systems_have_no_reserved_names():
    assert windows_device_component("CON", windows=False) is None
    expected = "CON" if os.name == "nt" else None
    assert windows_device_component("CON") == expected
