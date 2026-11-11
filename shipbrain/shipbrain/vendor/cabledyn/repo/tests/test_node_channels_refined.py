#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Node output channels name deck nodes on a finite-EI line whose mesh the static solve refined.

The deck is ``tests/data/lazy_wave_touchdown_planar_coarse.dat`` with its top bare section cut
from 20 to 4 elements: the deck mesh (71 elements, 72 deck nodes) cannot resolve the curvature
of the equilibrium and the static solve refines it. ``Ten<L>N<J>``, ``Curv<L>N<J>``,
``BendMom<L>N<J>`` and ``L<L>N<J>{px,py,pz,vx,..,Dec,Azi}`` must report deck node ``J`` (1 +
the total ``NumSegs`` of the sections, End A first), at its node of the refined mesh. Gates:

* static, cubic-Hermite route: the refined profile ``.static.out`` lists every mesh node and
  its ``DeckNode`` column names the deck nodes in order, each at the deck node's reference arc
  (``.elements.out`` ``ReferenceArcStart``); every node channel equals the profile row of its
  deck node, and that row is not row ``J`` (hang-off + 1, sag bend, mid-arch, touchdown,
  three-quarter, End B);
* dynamic, cubic-Hermite route: at every output time ``L<L>N<J>p{x,y,z}`` equals the
  ``.Line<L>.p.out`` position of the deck node's mesh node, and the end nodes report the
  ``FairTen``/``AnchTen`` end forces;
* mixed ``EI = 0`` + finite-EI route (the OpenFAST aggregate's channel evaluator and static
  profile): the node channels of the cable at ``t = 0`` equal its profile rows of the deck
  nodes, and the ``EI = 0`` line, never refined, numbers its rows as the deck;
* C API: ``CableDyn_EvalChannel`` reads deck nodes and ``CableDyn_GetLineValues`` every mesh
  node of the same state; a node past the deck count is rejected;
* Python: ``StaticProfile.deck_node_arc_lengths``, ``node_range_graph`` and ``profile_at``
  place the deck-node channels at their deck node's arc length.

usage: test_node_channels_refined.py --exe <cabledyn> --deck <coarse deck> --output <dir>
                                     [--library <libcabledyn>]
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from cabledyn import line_positions, node_range_graph, profile_at, read_output  # noqa: E402

FAILURES: list[str] = []
LINE = 4
# (length, NumSegs) of the deck sections after the cut, End A first
SECTIONS = [(80.0, 4), (100.0, 25), (420.0, 42)]
# hang-off + 1, the buoyancy-section start (sag bend), mid-arch, touchdown, three-quarter, End B
NODES = [1, 2, 5, 18, 34, 54, 72]
STATIC_COLUMN = {
    "Ten": "Tension",
    "Curv": "Curvature",
    "BendMom": "BendMoment",
    "px": "X",
    "py": "Y",
    "pz": "Z",
    "Dec": "Declination",
    "Azi": "Azimuth",
}


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def deck_arcs() -> list[float]:
    arcs = [0.0]
    for length, nsegs in SECTIONS:
        for _ in range(nsegs):
            arcs.append(arcs[-1] + length / nsegs)
    return arcs


def channel_names(dynamic: bool) -> list[str]:
    names = [f"FairTen{LINE}", f"AnchTen{LINE}"]
    kinematic = ["px", "py", "pz", "Dec", "Azi"] + (["vx", "vz", "ax", "az"] if dynamic else [])
    for j in NODES:
        names += [f"Ten{LINE}N{j}", f"Curv{LINE}N{j}", f"BendMom{LINE}N{j}"]
        names += [f"L{LINE}N{j}{k}" for k in kinematic]
    return names


def write_deck(source: Path, path: Path, *, outputs: str, tmax: float, mixed: bool = False) -> None:
    text = source.read_text()
    replaced = {
        f"{LINE} bare 80.0 20": f"{LINE} bare 80.0 4",
        f"{LINE} 7 8 -": f"{LINE} 7 8 {outputs}",
        "0.0 TMax": f"{tmax} TMax",
        f"FairTen{LINE}\n": "\n".join(channel_names(tmax > 0.0)) + "\n",
    }
    for old, new in replaced.items():
        if text.count(old) != 1:
            raise SystemExit(f"{source.name}: expected one {old!r}")
        text = text.replace(old, new)
    if mixed:
        # an EI = 0 chain from a second coupled point: the mixed EI = 0 + finite-EI route
        extra = {
            "buoy 0.29 59.53": "chain 0.10 150.0 8.0e8 0.0 0.0 0 0 0 0 1.2 0.4 1.0 0.5\nbuoy 0.29 59.53",
            "8 Fixed 500.0 0.0 -200.0": "8 Fixed 500.0 0.0 -200.0\n9 Coupled -30.0 0.0 -20.0\n"
            "10 Fixed -480.0 0.0 -200.0",
            f"{LINE} 7 8 {outputs}": f"{LINE} 7 8 {outputs}\n5 9 10 -",
            f"{LINE} bare 420.0 42": f"{LINE} bare 420.0 42\n5 chain 520.0 26",
            f"FairTen{LINE}\n": f"FairTen{LINE}\nFairTen5\nTen5N2\nL5N14pz\n",
        }
        for old, new in extra.items():
            line = text.split(old, 1)
            if len(line) != 2:
                raise SystemExit(f"{source.name}: expected {old!r}")
            text = new.join(line)
    path.write_text(text)


def run(exe: Path, deck: Path, root: Path) -> None:
    proc = subprocess.run(
        [str(exe), deck.name, root.name],
        cwd=deck.parent,
        capture_output=True,
        text=True,
        timeout=600,
        env={**os.environ, "OMP_NUM_THREADS": "1"},
    )
    if proc.returncode != 0:
        print(proc.stdout[-4000:])
        print(proc.stderr[-4000:])
        raise SystemExit(f"{deck.name}: driver exit {proc.returncode}")


def mesh_rows(profile, line_id: int) -> dict[int, int]:
    """Deck node -> 0-based row of the line in the static profile (its DeckNode column)."""
    line = profile.line(line_id)
    deck = line.column("DeckNode")
    return {int(j): int(i) for i, j in enumerate(deck) if j > 0}


def reference_arcs(elements: Path, line_id: int) -> np.ndarray:
    table = read_output(elements)
    mask = table.column("LineID") == line_id
    start = table.column("ReferenceArcStart")[mask]
    end = table.column("ReferenceArcEnd")[mask]
    return np.concatenate((start, end[-1:]))


def node_channel(name: str) -> tuple[int, str] | None:
    match = re.fullmatch(rf"(Ten|Curv|BendMom){LINE}N(\d+)", name)
    if match:
        return int(match.group(2)), match.group(1)
    match = re.fullmatch(rf"L{LINE}N(\d+)(\w+)", name)
    if match:
        return int(match.group(1)), match.group(2)
    return None


def static_gates(exe: Path, source: Path, out: Path) -> dict[int, int]:
    deck = out / "static.dat"
    write_deck(source, deck, outputs="pt", tmax=0.0)
    run(exe, deck, out / "static")
    profile = read_output(out / "static.static.out")
    line = profile.line(LINE)
    nrows = line.values.shape[0]
    check("DeckNode" in profile.channels, "a refined line's static profile carries the DeckNode column")
    check(nrows > 72, f"the deck mesh is refined ({nrows - 1} elements from 71)")
    rows = mesh_rows(profile, LINE)
    check(sorted(rows) == list(range(1, 73)), "DeckNode names deck nodes 1 .. 72, End A first")
    arcs = deck_arcs()
    sref = reference_arcs(out / "static.elements.out", LINE)
    check(sref.size == nrows, "the element table and the profile list the same mesh")
    offset = max(abs(sref[rows[j]] - arcs[j - 1]) for j in rows)
    check(offset < 1.0e-6, f"each DeckNode row lies at its deck node's reference arc (max {offset:.1e} m)")
    check(all(rows[j] != j - 1 for j in NODES if j > 1), "the deck nodes are not the profile rows J")
    check(rows[72] == nrows - 1, "End B is the last mesh node")
    history = read_output(out / "static.out")
    worst = 0.0
    for name in history.channels[1:]:
        parsed = node_channel(name)
        if parsed is None:
            continue
        j, kind = parsed
        value = float(history.column(name)[0])
        expected = float(line.column(STATIC_COLUMN[kind])[rows[j]])
        worst = max(worst, abs(value - expected) / max(1.0, abs(expected)))
    check(worst == 0.0, f"every static node channel is its deck node's profile row (max rel {worst:.1e})")
    touchdown = float(history.column(f"Ten{LINE}N34")[0])
    print(f"  Ten{LINE}N34 = {touchdown:.1f} N at mesh node {rows[34] + 1} (s = {arcs[33]:.0f} m)")
    check(
        float(history.column(f"Ten{LINE}N1")[0]) == float(history.column(f"FairTen{LINE}")[0])
        and float(history.column(f"Ten{LINE}N72")[0]) == float(history.column(f"AnchTen{LINE}")[0]),
        "the end deck nodes report the FairTen/AnchTen end forces",
    )
    # Python: deck-node channels placed at their deck node's static arc length
    lookup = profile.deck_node_arc_lengths(LINE)
    arc_column = line.column("ArcLength")
    check(
        all(lookup[j] == float(arc_column[rows[j]]) for j in rows) and len(lookup) == 72,
        "StaticProfile.deck_node_arc_lengths gives each deck node's row",
    )
    graph = node_range_graph(history, LINE, "tension", arc_length=profile)
    expected = np.asarray([arc_column[rows[j]] for j in NODES])
    check(np.array_equal(graph.location, expected), "node_range_graph places deck nodes at their arc")
    return rows


def dynamic_gates(exe: Path, source: Path, out: Path, rows: dict[int, int]) -> None:
    deck = out / "dynamic.dat"
    write_deck(source, deck, outputs="p", tmax=0.1)
    run(exe, deck, out / "dynamic")
    history = read_output(out / "dynamic.out")
    positions = read_output(out / f"dynamic.Line{LINE}.p.out")
    check(history.time.size == 5 and positions.time.size == 5, "the march writes t = 0 .. 0.1 s")
    worst = 0.0
    for j in NODES:
        for axis in "xyz":
            value = history.column(f"L{LINE}N{j}p{axis}")
            mesh = positions.column(f"Node{rows[j] + 1}{axis.upper()}(m)")
            worst = max(worst, float(np.max(np.abs(value - mesh))))
    check(worst == 0.0, f"L<L>N<J>p equals the .p.out position of the deck node's mesh node ({worst:.1e} m)")
    check(
        np.array_equal(history.column(f"Ten{LINE}N1"), history.column(f"FairTen{LINE}"))
        and np.array_equal(history.column(f"Ten{LINE}N72"), history.column(f"AnchTen{LINE}")),
        "the end deck nodes report the end forces at every output time",
    )
    static = read_output(out / "dynamic.static.out").line(LINE)
    first = max(
        abs(float(history.column(f"Ten{LINE}N{j}")[0]) - float(static.column("Tension")[rows[j]]))
        for j in NODES
    )
    check(first == 0.0, "the t = 0 node tensions are the static profile rows of the deck nodes")
    # Python: a per-line position file places deck-node channels through the profile beside it
    placed = profile_at(history, "tension", 0.1, line_id=LINE, positions=positions)
    xyz = np.stack([positions.column(f"Node{k}{a}(m)")[-1] for k in range(1, rows[72] + 2) for a in "XYZ"])
    xyz = xyz.reshape(-1, 3)
    chord = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(xyz, axis=0), axis=1))))
    expected = np.asarray([chord[rows[j]] for j in NODES])
    check(
        np.allclose(placed.location, expected, rtol=0.0, atol=1.0e-9),
        "profile_at places deck-node channels with a per-line position file at their mesh nodes",
    )
    # the per-line file names its deck nodes itself, so it places them without the profile
    deck = positions.deck_nodes
    check(
        deck is not None
        and deck.size == rows[72] + 1
        and all(int(deck[rows[j]]) == j for j in rows)
        and int(np.count_nonzero(deck)) == 72,
        "the .p.out DeckNode line names the deck node of every mesh node",
    )
    alone = out / "alone"
    alone.mkdir()
    shutil.copy(out / f"dynamic.Line{LINE}.p.out", alone / f"dynamic.Line{LINE}.p.out")
    lone = read_output(alone / f"dynamic.Line{LINE}.p.out")
    by_file = profile_at(history, "tension", 0.1, line_id=LINE, positions=lone)
    by_positions = profile_at(history, "tension", 0.1, line_id=LINE, positions=line_positions(lone))
    check(
        np.allclose(by_file.location, expected, rtol=0.0, atol=1.0e-9)
        and np.allclose(by_positions.location, expected, rtol=0.0, atol=1.0e-9),
        "a per-line position file (or LinePositions read from it) places deck nodes on its own",
    )


def mixed_gates(exe: Path, source: Path, out: Path, rows: dict[int, int]) -> None:
    deck = out / "mixed.dat"
    write_deck(source, deck, outputs="-", tmax=0.05, mixed=True)
    run(exe, deck, out / "mixed")
    history = read_output(out / "mixed.out")
    check(history.title.startswith("# CableDyn driver output (mixed aggregate"), "the deck runs on the mixed route")
    profile = read_output(out / "mixed.static.out")
    check("DeckNode" in profile.channels, "the mixed static profile carries the DeckNode column")
    mixed_rows = mesh_rows(profile, LINE)
    check(mixed_rows == rows, "the mixed route refines the cable to the same mesh")
    chain = profile.line(5)
    check(
        np.array_equal(chain.column("DeckNode"), chain.column("Node")) and chain.values.shape[0] == 27,
        "the EI = 0 line is not refined and numbers its rows as the deck",
    )
    line = profile.line(LINE)
    worst = 0.0
    for name in history.channels[1:]:
        parsed = node_channel(name)
        if parsed is None or parsed[1] not in STATIC_COLUMN:
            continue
        j, kind = parsed
        expected = float(line.column(STATIC_COLUMN[kind])[rows[j]])
        worst = max(worst, abs(float(history.column(name)[0]) - expected) / max(1.0, abs(expected)))
    check(worst == 0.0, f"mixed-route node channels at t = 0 are the deck nodes' profile rows ({worst:.1e})")
    check(
        float(history.column("Ten5N2")[0]) == float(chain.column("Tension")[1])
        and float(history.column("L5N14pz")[0]) == float(chain.column("Z")[13]),
        "the EI = 0 line's node channels read its deck nodes",
    )


def capi_gates(library: Path, source: Path, out: Path, rows: dict[int, int]) -> None:
    os.environ["CABLEDYN_LIBRARY"] = str(library)
    from cabledyn import CableDyn, CableDynError

    deck = out / "capi.dat"
    write_deck(source, deck, outputs="-", tmax=0.0)
    with CableDyn(deck) as model:
        line = model.line(LINE)
        check(line.n_nodes == rows[72] + 1, "GetObjectInfo reports the refined mesh's node count")
        tension = line.values("tension")
        position = line.values("position")
        same = all(
            model.channel(f"Ten{LINE}N{j}") == float(tension[rows[j]])
            and model.channel(f"L{LINE}N{j}pz") == float(position[rows[j], 2])
            for j in NODES
        )
        check(same, "EvalChannel reads the deck node, GetLineValues the mesh nodes of the same state")
        try:
            model.channel(f"Ten{LINE}N73")
            rejected = False
        except CableDynError:
            rejected = True
        check(rejected, "a node past the deck node count is rejected")
        deck = line.deck_nodes
        check(
            deck.size == line.n_nodes
            and all(int(deck[rows[j]]) == j for j in rows)
            and int(np.count_nonzero(deck)) == 72,
            "Line.deck_nodes (CD_C_LINE_DECK_NODE) locates the deck nodes among the mesh nodes",
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--deck", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--library", type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    exe = args.exe.resolve()
    source = args.deck.resolve()
    rows = static_gates(exe, source, out)
    dynamic_gates(exe, source, out, rows)
    mixed_gates(exe, source, out, rows)
    if args.library is None:
        print("SKIP: C API gates (no --library)")
    elif args.library.is_file():
        capi_gates(args.library.resolve(), source, out, rows)
    else:
        check(False, f"--library {args.library} is not a file")
    if FAILURES:
        print(f"{len(FAILURES)} gate(s) failed")
        return 1
    print("all gates passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
