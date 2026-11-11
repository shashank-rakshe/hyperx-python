# SPDX-License-Identifier: Apache-2.0
"""The reader of ``<root>.modes.out``, on files the native driver really writes.

The driver gates are skipped unless ``CABLEDYN_DRIVER`` or ``CABLEDYN_TEST_DRIVER`` names a
built driver. The malformed files are built from the layout of the tables, row by row.
"""

from __future__ import annotations

import math
import os
import shutil
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    CableDynDriver,
    DriverResult,
    ModeShapes,
    NaturalModes,
    OutputFormatError,
    OutputTable,
    read_output,
)
from cabledyn.formats import read_table

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
_DRIVER = (
    os.environ.get("CABLEDYN_DRIVER") or os.environ.get("CABLEDYN_TEST_DRIVER") or ""
).strip()

needs_driver = pytest.mark.skipif(
    not _DRIVER or not Path(_DRIVER).is_file(),
    reason="set CABLEDYN_DRIVER to a built native driver to run the modal output gates",
)

RHO_W, DIAM = 1025.0, 0.1
# Neutrally buoyant, without added mass: a taut line stays straight.
MASS = RHO_W * math.pi * DIAM**2 / 4.0
# An EI = 0 line must have weight: this one sags by about a centimetre.
EI0_MASS = 1.01 * MASS
EA, TENSION = 1.0e6, 1000.0
BAR = "-" * 21


def taut_deck(
    lines: list[tuple[float, int]],
    *,
    ei: float = 0.0,
    torsion: tuple[str, ...] = (),
    n_modes: int = 6,
) -> str:
    """Taut straight lines of (length, segments), side by side, from Coupled to Fixed points.

    ``ei`` above 0 makes a dynamic finite-EI deck, ``torsion`` names the TorsStiffness of the
    two ends of each line.
    """
    points, line_rows, sections, ends = [], [], [], []
    for index, (length, segments) in enumerate(lines):
        line_id = index + 1
        span = length * (1.0 + TENSION / EA)
        y = 20.0 * index
        points.append(f"{2 * index + 1} Coupled 0.0 {y!r} -100.0")
        points.append(f"{2 * index + 2} Fixed {span!r} {y!r} -100.0")
        line_rows.append(f"{line_id} {2 * index + 1} {2 * index + 2} -")
        sections.append(f"{line_id} cab {length!r} {segments}")
        if torsion:
            for end in "AB":
                ends.append(f"{line_id} {end} Rigid 1 0 0 {torsion[index]} 0 0 1 0")
    if ei > 0.0:
        types = "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n"
        types += f"cab {DIAM!r} {MASS!r} {EA!r} 0.0 {ei!r} 1.0e8 80.0 1.0 0.04 1.2 0.0 0.0 0.0"
        march = "0.01 dtM\n0.01 TMax\n"
    else:
        types = "Name Diam Mass EA BA EI Cdn Cdt Can Cat\n"
        types += f"cab {DIAM!r} {EI0_MASS!r} {EA!r} -1.0 0.0 1.2 0.0 0.0 0.0"
        march = ""
    connections = ""
    if ends:
        connections = (
            f"{BAR} END CONNECTIONS {BAR}\n"
            "LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist\n"
            + "\n".join(ends)
            + "\n"
        )
    return (
        f"{BAR} CableDyn Input File {BAR}\n"
        "taut straight lines\n"
        f"{BAR} LINE TYPES {BAR}\n{types}\n"
        f"{BAR} POINTS {BAR}\nID Type X Y Z\n" + "\n".join(points) + "\n"
        f"{BAR} LINES {BAR}\nID NodeA NodeB Outputs\n" + "\n".join(line_rows) + "\n"
        f"{BAR} SECTIONS {BAR}\nLineID LineType Length NumSegs\n"
        + "\n".join(sections)
        + "\n"
        + connections
        + f"{BAR} OPTIONS {BAR}\n9.80665 g\n{RHO_W!r} rhoW\n500.0 WtrDpth\n"
        + march
        + f"{n_modes} nModes\n{BAR} OUTPUTS {BAR}\nFairTen1\n{BAR} need this line {BAR}\n"
    )


def run_modes(tmp_path: Path, deck_text: str, name: str = "modes"):
    deck = tmp_path / f"{name}.dat"
    deck.write_text(deck_text, encoding="utf-8")
    return CableDynDriver(_DRIVER).run(deck, tmp_path / name, timeout=300)


@needs_driver
def test_ei0_lines_read_both_tables(tmp_path):
    lengths = [(10.0, 20), (20.0, 10)]
    result = run_modes(tmp_path, taut_deck(lengths))
    assert result.modes_output == tmp_path / "modes.modes.out"
    modes = read_output(result.modes_output)
    assert isinstance(modes, NaturalModes) and isinstance(modes, OutputTable)
    assert isinstance(modes.shapes, ModeShapes)
    assert modes.channels == ("LineID", "Mode", "Frequency", "Period", "Omega")
    assert modes.unit("Frequency") == "Hz" and modes.unit("Period") == "s"
    assert modes.unit("Omega") == "rad/s"
    assert modes.shapes.unit("X") == "m" and not modes.has_twist
    assert modes.title.startswith("# CableDyn modal analysis")
    assert modes.shapes.title.startswith("# Mode shapes")
    assert modes.line_ids == (1, 2) and modes.shapes.line_ids == (1, 2)
    assert read_table(result.modes_output).line_ids == (1, 2)
    assert result.read_modes().line_ids == (1, 2)

    for line_id, (length, segments) in enumerate(lengths, start=1):
        assert modes.mode_numbers(line_id) == (1, 2, 3, 4, 5, 6)
        assert modes.shapes.node_ids(line_id) == tuple(range(1, segments + 2))
        frequency = modes.frequencies(line_id)
        assert np.all(np.diff(frequency) >= 0.0) and frequency[0] > 0.0
        assert modes.periods(line_id) == pytest.approx(1.0 / frequency, rel=1e-7)
        omega = modes.angular_frequencies(line_id)
        assert omega == pytest.approx(2.0 * math.pi * frequency, rel=1e-7)
        # The two transverse planes of a taut string share each frequency, sqrt(T/m)/(2 L).
        string = math.sqrt(TENSION / EI0_MASS) / (2.0 * length * (1.0 + TENSION / EA))
        assert frequency[0] == pytest.approx(string, rel=2e-2)
        assert not np.any(modes.polar_shares(line_id)) and modes.torsional_modes(line_id) == ()

        xyz = modes.shapes.positions(line_id)
        assert xyz.shape == (segments + 1, 3)
        assert xyz[0] == pytest.approx([0.0, 20.0 * (line_id - 1), -100.0], abs=1e-6)
        for mode in modes.mode_numbers(line_id):
            shape = modes.shapes.displacements(line_id, mode)
            assert shape.shape == (segments + 1, 3)
            assert np.max(np.linalg.norm(shape, axis=1)) == pytest.approx(1.0, rel=1e-7)
            assert not np.any(shape[0]) and not np.any(shape[-1])  # held ends
            assert not np.any(modes.shapes.twist(line_id, mode))
        # The first mode of a string is a half sine.
        arc = np.linspace(0.0, 1.0, segments + 1)
        first = np.linalg.norm(modes.shapes.displacements(line_id, 1), axis=1)
        assert first == pytest.approx(np.sin(math.pi * arc), abs=2e-2)

    line_2 = modes.line(2)
    assert isinstance(line_2, NaturalModes) and line_2.line_ids == (2,)
    assert line_2.shapes.line_ids == (2,)
    assert line_2.frequencies(2) == pytest.approx(modes.frequencies(2))
    with pytest.raises(KeyError, match="LineID 3"):
        modes.line(3)
    with pytest.raises(KeyError, match="no mode 7"):
        modes.shapes.displacements(1, 7)


@needs_driver
def test_finite_ei_lines_read_both_tables(tmp_path):
    lengths = [(10.0, 20), (15.0, 30)]
    modes = run_modes(tmp_path, taut_deck(lengths, ei=100.0)).read_modes()
    assert modes.line_ids == (1, 2) and not modes.has_twist
    for line_id, (_, segments) in enumerate(lengths, start=1):
        assert len(modes.mode_numbers(line_id)) == 6
        assert np.all(modes.frequencies(line_id) > 0.0)
        assert modes.shapes.node_ids(line_id) == tuple(range(1, segments + 2))
        shape = modes.shapes.displacements(line_id, 1)
        assert np.max(np.linalg.norm(shape, axis=1)) == pytest.approx(1.0, rel=1e-7)


@needs_driver
def test_torsional_modes_on_one_of_several_lines(tmp_path):
    deck = taut_deck([(10.0, 40), (10.0, 20)], ei=100.0, torsion=("Rigid", "Free"), n_modes=24)
    modes = run_modes(tmp_path, deck).read_modes()
    assert modes.has_twist and modes.line_ids == (1, 2)
    assert modes.channels[-1] == "PolarShare" and modes.shapes.channels[-1] == "dTwist"
    torsional = modes.torsional_modes(1)
    assert torsional
    assert modes.polar_shares(1)[torsional[0] - 1] > 0.5
    twist = modes.shapes.twist(1, torsional[0])
    assert np.max(np.abs(twist)) == pytest.approx(1.0, rel=1e-7)
    assert abs(twist) == pytest.approx(np.sin(math.pi * np.linspace(0.0, 1.0, 41)), abs=1e-3)
    # The line without torsion has the columns, at zero.
    assert modes.torsional_modes(2) == () and not np.any(modes.polar_shares(2))
    assert not np.any(modes.shapes.twist(2, 1))


@needs_driver
def test_a_line_without_free_nodes_has_no_rows(tmp_path):
    result = run_modes(tmp_path, taut_deck([(10.0, 1), (10.0, 8)]))
    modes = result.read_modes()
    assert modes.line_ids == (2,) and modes.shapes.line_ids == (2,)
    with pytest.raises(KeyError, match="LineID 1"):
        modes.frequencies(1)

    alone = run_modes(tmp_path, taut_deck([(10.0, 1)]), "alone").read_modes()
    assert alone.line_ids == () and alone.values.shape == (0, 5)
    assert alone.shapes.values.shape == (0, 9)


@needs_driver
def test_a_shipped_modal_example_on_a_seabed(tmp_path):
    deck = tmp_path / "chain_modes.dat"
    shutil.copyfile(EXAMPLES / deck.name, deck)
    modes = CableDynDriver(_DRIVER).run(deck, tmp_path / "chain", timeout=300).read_modes()
    assert modes.line_ids == (1,) and len(modes.mode_numbers(1)) == 12
    # doc/tutorial_catenary.rst states the first period.
    assert modes.periods(1)[0] == pytest.approx(47.1, abs=0.05)
    assert modes.shapes.node_ids(1) == tuple(range(1, 57))
    # Nodes run from End A, the fairlead of this deck.
    assert modes.shapes.positions(1)[0] == pytest.approx([0.0, 0.0, 0.0], abs=1e-6)


@needs_driver
def test_a_run_without_modes_has_no_modal_output(tmp_path):
    deck = taut_deck([(10.0, 8)]).replace("6 nModes\n", "")
    result = run_modes(tmp_path, deck)
    assert result.modes_output is None
    with pytest.raises(FileNotFoundError, match=r"\.modes\.out"):
        result.read_modes()


HEADER = (
    "# CableDyn modal analysis about the static equilibrium\n"
    "# Natural frequencies\n"
    "LineID\tMode\tFrequency\tPeriod\tOmega\n"
    "(-)\t(-)\t(Hz)\t(s)\t(rad/s)\n"
)
SHAPE_HEADER = (
    "# Mode shapes (nodal translations, unit largest nodal displacement)\n"
    "LineID\tMode\tNode\tX\tY\tZ\tdX\tdY\tdZ\n"
    "(-)\t(-)\t(-)\t(m)\t(m)\t(m)\t(-)\t(-)\t(-)\n"
)
FREQUENCY_ROWS = "1\t1\t2.0E-1\t5.0E+0\t1.25E+0\n1\t2\t4.0E-1\t2.5E+0\t2.5E+0\n"
SHAPE_ROWS = (
    "1\t1\t1\t0.0\t0.0\t-1.0\t0.0\t0.0\t0.0\n"
    "1\t1\t2\t1.0\t0.0\t-1.0\t0.0\t0.0\t1.0\n"
    "1\t2\t1\t0.0\t0.0\t-1.0\t0.0\t0.0\t0.0\n"
    "1\t2\t2\t1.0\t0.0\t-1.0\t0.0\t1.0\t0.0\n"
)


def write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "table.modes.out"
    path.write_text(text, encoding="utf-8")
    return path


def test_a_negative_eigenvalue_reads_as_written(tmp_path):
    rows = "1\t1\t-2.0E-1\t0.0E+0\t-1.25E+0\n1\t2\t4.0E-1\t2.5E+0\t2.5E+0\n"
    modes = read_output(write(tmp_path, HEADER + rows + SHAPE_HEADER + SHAPE_ROWS))
    assert modes.frequencies(1)[0] == -0.2 and modes.periods(1)[0] == 0.0
    assert modes.angular_frequencies(1)[0] == -1.25


def test_the_accessors_of_a_file_with_twist_columns(tmp_path):
    header = HEADER.replace("\tOmega", "\tOmega\tPolarShare").replace("(rad/s)", "(rad/s)\t(-)")
    frequency = "1\t1\t2.0E-1\t5.0E+0\t1.25E+0\t0.0E+0\n1\t2\t4.0E-1\t2.5E+0\t2.5E+0\t9.0E-1\n"
    shape_header = SHAPE_HEADER.replace("\tdZ", "\tdZ\tdTwist").replace(
        "(-)\t(-)\t(-)\n", "(-)\t(-)\t(-)\t(-)\n"
    )
    shapes = SHAPE_ROWS.replace("0.0\n", "0.0\t0.0\n").replace("1.0\n", "1.0\t1.0\n")
    modes = read_output(write(tmp_path, header + frequency + shape_header + shapes))
    assert modes.has_twist and modes.torsional_modes(1) == (2,)
    assert modes.mode_numbers(1) == (1, 2)
    assert list(modes.polar_shares(1)) == [0.0, 0.9]
    assert list(modes.periods(1)) == [5.0, 2.5]
    assert list(modes.frequencies(1)) == [0.2, 0.4]
    assert list(modes.angular_frequencies(1)) == [1.25, 2.5]
    assert list(modes.shapes.twist(1, 1)) == [0.0, 1.0]
    assert modes.shapes.node_ids(1) == (1, 2)
    assert modes.shapes.positions(1).tolist() == [[0.0, 0.0, -1.0], [1.0, 0.0, -1.0]]
    assert modes.shapes.displacements(1, 2).tolist() == [[0.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    assert modes.line(1).shapes.values.shape == modes.shapes.values.shape
    assert modes.values.flags.writeable is False


def test_the_accessors_of_a_file_without_twist_columns(tmp_path):
    modes = read_output(write(tmp_path, HEADER + FREQUENCY_ROWS + SHAPE_HEADER + SHAPE_ROWS))
    assert not modes.has_twist and modes.torsional_modes(1) == ()
    assert list(modes.polar_shares(1)) == [0.0, 0.0]
    assert list(modes.shapes.twist(1, 1)) == [0.0, 0.0]
    with pytest.raises(KeyError, match="LineID 2"):
        modes.frequencies(2)
    with pytest.raises(KeyError, match="LineID 2"):
        modes.shapes.positions(2)


def test_read_modes_refuses_a_file_of_another_kind(tmp_path):
    other = tmp_path / "other.out"
    other.write_text("Time(s) FairTen1\n0.0 1.0\n", encoding="utf-8")
    result = DriverResult(
        executable=tmp_path / "driver",
        deck=tmp_path / "deck.dat",
        output_root=tmp_path / "run",
        main_output=tmp_path / "run.out",
        static_output=None,
        elements_output=None,
        line_outputs=(),
        rod_outputs=(),
        stdout="",
        stderr="",
        returncode=0,
        modes_output=other,
    )
    with pytest.raises(OutputFormatError, match="no modal tables"):
        result.read_modes()


def test_a_table_built_without_the_frequency_columns_is_refused(tmp_path):
    shapes = read_output(
        write(tmp_path, HEADER + FREQUENCY_ROWS + SHAPE_HEADER + SHAPE_ROWS)
    ).shapes
    with pytest.raises(OutputFormatError, match="frequency table missing Omega"):
        NaturalModes(
            tmp_path / "table.modes.out",
            "",
            ("LineID", "Mode", "Frequency", "Period"),
            None,
            np.array([[1.0, 1.0, 0.2, 5.0], [1.0, 2.0, 0.4, 2.5]]),
            shapes,
        )


def test_the_tables_are_found_by_layout_not_by_file_name(tmp_path):
    path = tmp_path / "renamed.txt"
    path.write_text(HEADER + FREQUENCY_ROWS + SHAPE_HEADER + SHAPE_ROWS, encoding="utf-8")
    assert isinstance(read_output(path), NaturalModes)


@pytest.mark.parametrize(
    ("text", "match"),
    [
        (HEADER + FREQUENCY_ROWS, "no mode-shape table"),
        (HEADER + FREQUENCY_ROWS + SHAPE_HEADER.splitlines()[0], "no mode-shape table"),
        (HEADER + FREQUENCY_ROWS + SHAPE_HEADER, "same lines"),
        (
            HEADER + FREQUENCY_ROWS + SHAPE_HEADER.replace("\tdY", "\tdX") + SHAPE_ROWS,
            "duplicate channel name",
        ),
        # Cut after a whole mode, inside a mode, and inside a row.
        (
            HEADER + FREQUENCY_ROWS + SHAPE_HEADER + "".join(SHAPE_ROWS.splitlines(True)[:2]),
            "2 frequency rows but 1 mode shapes",
        ),
        (
            HEADER + FREQUENCY_ROWS + SHAPE_HEADER + "".join(SHAPE_ROWS.splitlines(True)[:3]),
            "not the nodes",
        ),
        (HEADER + FREQUENCY_ROWS + SHAPE_HEADER + SHAPE_ROWS[:-6], "expected 9 fields"),
        (
            HEADER + FREQUENCY_ROWS.splitlines(True)[1] + SHAPE_HEADER + SHAPE_ROWS,
            "modes are not numbered",
        ),
        (
            HEADER + "1\t1\tNaN\t5.0\t1.25\n" + SHAPE_HEADER + SHAPE_ROWS,
            "nonnumeric",
        ),
        (
            HEADER
            + FREQUENCY_ROWS
            + SHAPE_HEADER
            + SHAPE_ROWS.replace("1\t2\t2\t1.0", "1\t2\t2\t2.0"),
            "static positions differ",
        ),
        (
            HEADER + FREQUENCY_ROWS + SHAPE_HEADER.replace("\tdZ", "\tdQ") + SHAPE_ROWS,
            "missing dZ",
        ),
        (
            HEADER.replace("\tOmega", "\tOmega\tPolarShare").replace("(rad/s)", "(rad/s)\t(-)")
            + FREQUENCY_ROWS.replace("\n", "\t0.0\n")
            + SHAPE_HEADER
            + SHAPE_ROWS,
            "must appear together",
        ),
    ],
)
def test_malformed_modal_files_are_refused(tmp_path, text, match):
    with pytest.raises(OutputFormatError, match=match):
        read_output(write(tmp_path, text))


def test_a_line_split_between_rows_is_refused(tmp_path):
    frequency = "1\t1\t0.2\t5.0\t1.25\n2\t1\t0.2\t5.0\t1.25\n1\t2\t0.4\t2.5\t2.5\n"
    with pytest.raises(OutputFormatError, match="not contiguous"):
        read_output(write(tmp_path, HEADER + frequency + SHAPE_HEADER + SHAPE_ROWS))
