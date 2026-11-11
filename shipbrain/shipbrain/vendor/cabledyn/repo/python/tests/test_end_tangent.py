# SPDX-License-Identifier: Apache-2.0
"""The tangent of a finite-EI line in process: at an end clamped by END CONNECTIONS Rigid the
declination and azimuth the C API returns are the clamp's, and the line values match the
channels (aggregate route)."""

from __future__ import annotations

import math
from pathlib import Path

import pytest

try:
    import cabledyn._lib  # noqa: F401  (loads the shared library)
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

from cabledyn.model import CableDyn

_BAR = "-" * 21


def _deck(path: Path, declination: float, azimuth: float) -> Path:
    d, a = math.radians(declination), math.radians(azimuth)
    ez = (math.sin(d) * math.cos(a), math.sin(d) * math.sin(a), math.cos(d))
    path.write_text(
        f"""{_BAR} CableDyn Input File {_BAR}
a cable clamped at End A
{_BAR} LINE TYPES {_BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
cable 0.2 60.0 1.0e8 -1.0 1.0e4 1.2 0.008 1.0 0.0
{_BAR} POINTS {_BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Coupled 0.0 0.0 -10.0 0 0 0 0
2 Fixed 80.0 0.0 -80.0 0 0 0 0
{_BAR} LINES {_BAR}
ID NodeA NodeB Outputs
1 1 2 -
{_BAR} SECTIONS {_BAR}
LineID LineType Length NumSegs
1 cable 125.0 100
{_BAR} END CONNECTIONS {_BAR}
LineID End Stiffness EzX EzY EzZ
1 A Rigid {ez[0]:.17g} {ez[1]:.17g} {ez[2]:.17g}
{_BAR} OPTIONS {_BAR}
9.80665 g
1025.0 rhoW
0.05 dtM
1.0 TMax
{_BAR} OUTPUTS {_BAR}
FairDecl1
{_BAR} need this line {_BAR}
""",
        encoding="utf-8",
    )
    return path


@pytest.mark.parametrize(("declination", "azimuth"), [(165.0, 0.0), (135.0, 20.0)])
def test_the_clamped_end_reads_the_clamp(tmp_path, declination, azimuth):
    with CableDyn(_deck(tmp_path / "clamp.dat", declination, azimuth)) as model:
        line = model.line(1)
        dec, azi = line.declination(), line.azimuth()
        assert dec[0] == pytest.approx(declination, abs=1.0e-9)
        assert azi[0] == pytest.approx(azimuth, abs=1.0e-9)
        assert model.channel("FairDecl1") == pytest.approx(declination, abs=1.0e-9)
        # the ends of the line's mesh (refined at the clamp) are its deck end nodes
        assert dec[0] == model.channel("L1N1Dec") and azi[0] == model.channel("L1N1Azi")
        assert dec[-1] == model.channel("AnchDecl1")
