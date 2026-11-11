# SPDX-License-Identifier: Apache-2.0
"""Shared fixtures: a real stand-in executable for the native driver.

The stand-in is a small Python program behind a platform launcher (a ``.cmd``
file on Windows, an executable shell script elsewhere), so the wrapper is
exercised through a genuine child process: argument passing, working
directory, exit codes, captured streams, timeouts, and files on disk. Its
behaviour is selected with the ``FAKE_CABLEDYN_MODE`` environment variable.
"""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

import pytest

_PROGRAM = r"""
import math
import os
import sys
import time

mode = os.environ.get("FAKE_CABLEDYN_MODE", "ok")
if sys.argv[1:] == ["--version"]:
    if mode == "bad-version":
        sys.stderr.write("broken\n")
        sys.exit(4)
    sys.stderr.write("CableDyn_driver fake 0.0.0\n")
    sys.exit(0)
deck, root = sys.argv[1], sys.argv[2]
with open(os.path.join(os.path.dirname(os.path.abspath(root)) or ".", "argv.log"), "a") as log:
    log.write(f"{os.getcwd()}|{deck}|{root}\n")
if mode == "sleep":
    time.sleep(30)
if mode in {"fail", "partial-fail"}:
    if mode == "partial-fail":
        with open(root + ".out", "w") as stream:
            stream.write("Time(s) FairTen1\n0.0 1.0\n")
    sys.stderr.write("CableDyn_driver: deck line 3: synthetic failure\n")
    sys.stderr.write("CableDyn_driver: ended with exit code 3\n")
    sys.exit(3)
if mode == "no-output":
    sys.exit(0)
if mode == "bad-output":
    with open(root + ".out", "w") as stream:
        stream.write("Time(s) FairTen1\n0.0 nan\n")
    sys.exit(0)
with open(root + ".out", "w") as stream:
    stream.write("CableDyn fake output\nTime(s) FairTen1 AnchTen1\n")
    for step in range(201):
        t = 0.05 * step
        stream.write(f"{t:.6E} {1.0e6 + 1.0e5 * math.sin(2.0 * math.pi * 0.5 * t):.8E} "
                     f"{8.0e5 + 5.0e4 * math.cos(2.0 * math.pi * 0.25 * t):.8E}\n")
with open(root + ".static.out", "w") as stream:
    stream.write("CableDyn static\nLineID Node ArcLength X Y Z Tension\n"
                 "(-) (-) (m) (m) (m) (m) (N)\n")
    for node in range(5):
        stream.write(f"1 {node + 1} {25.0 * node} {25.0 * node} 0.0 {-100.0 + 20.0 * node} "
                     f"{1.0e6 + node}\n")
if mode == "lines":
    with open(root + ".Line1.p.out", "w") as stream:
        stream.write("Time(s) Node1X(m) Node1Y(m) Node1Z(m) Node2X(m) Node2Y(m) Node2Z(m)\n")
        stream.write("0.0 0.0 0.0 -100.0 10.0 0.0 -90.0\n1.0 0.0 0.0 -100.0 11.0 0.0 -90.0\n")
    with open(root + ".Line1.t.out", "w") as stream:
        stream.write("Time(s) Segment1Tension(N)\n0.0 5.0\n1.0 6.0\n")
sys.stdout.write("fake run complete\n")
"""


def make_fake_driver(directory: Path) -> Path:
    """Write the stand-in driver into ``directory`` and return its launcher."""
    directory.mkdir(parents=True, exist_ok=True)
    program = directory / "fake_driver.py"
    program.write_text(_PROGRAM, encoding="utf-8")
    if os.name == "nt":
        launcher = directory / "fake_driver.cmd"
        launcher.write_text(f'@"{sys.executable}" "{program}" %*\r\n', encoding="utf-8")
    else:
        launcher = directory / "fake_driver"
        launcher.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{program}" "$@"\n', encoding="utf-8"
        )
        launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return launcher


@pytest.fixture
def plt():
    """``matplotlib.pyplot`` on the non-interactive Agg backend; closes every figure after."""
    matplotlib = pytest.importorskip("matplotlib")
    matplotlib.use("Agg")
    import matplotlib.pyplot as pyplot

    yield pyplot
    pyplot.close("all")


@pytest.fixture
def fake_driver(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Path of a stand-in native driver executable."""
    return make_fake_driver(tmp_path_factory.mktemp("fake-driver"))


@pytest.fixture
def deck(tmp_path: Path) -> Path:
    """A placeholder deck file (the stand-in driver does not parse it)."""
    path = tmp_path / "model.dat"
    path.write_text("placeholder deck\n", encoding="utf-8")
    return path
