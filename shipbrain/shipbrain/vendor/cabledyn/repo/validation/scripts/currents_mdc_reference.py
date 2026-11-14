# SPDX-License-Identifier: Apache-2.0
"""Regenerate the MoorDyn-C current references of tests/data/currents_mdc.

Every case folder holds a MoorDyn-C deck (currents.dat), its fixed-name current file and probe
points (points.txt, rows ``t x y z``). For each case this script writes

* ``ref_python.csv``: the current evaluated here, independently of CableDyn, from the file as
  MoorDyn-C v2.7.1 reads and interpolates it (constructDynamicCurrentGrid and
  construct4DCurrentGrid of source/Waves/WaveGrid.cpp, CurrentGrid::getCurrentKin of
  source/Waves.cpp): the table resampled at the smallest time interval dt from t = 0 to its last
  time, linear in time between samples with the upper sample index taken modulo the sample count
  (so the grid repeats past its last sample), and trilinear in x, y and z, held beyond the end
  coordinates. ``Currents 2`` depths are read in single precision, as MoorDyn-C's ``stof``.
  ``Currents 5`` rows are read from line 6 (a text line 6 is a header) and matched to the grid by
  value. Currents 1 is a steady depth profile, linear in z and held beyond its end rows.
* ``ref_moordyn_c.csv`` (with ``--moordyn-c``): the same points from MoorDyn-C itself, through
  validation/scripts/wavekin_mdc_probe.cpp compiled against a MoorDyn-C build (CD_MDC_SRC,
  CD_MDC_BUILD and CD_GXX as for the bodies scripts).

The tension case folders (tension_c0, tension_c2, tension_c5) hold a MoorDyn-C deck
(tension.dat) and its current file; with ``--moordyn-c`` each gets ``ref_moordyn_c_tension.csv``,
the line node tensions MoorDyn-C reports every 0.1 s over 22 s
(validation/scripts/currents_mdc_tension.cpp), which tests/test_mdc_currents_runs.py compares
with CableDyn's.

Rows are ``t,x,y,z,zeta,ux,uy,uz,ax,ay,az`` (zeta and the accelerations zero: MoorDyn-C gives a
current no acceleration). The currents_mdc CTest compares CableDyn against both.
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
DATA = REPO / "tests" / "data" / "currents_mdc"
FILES = {1: "current_profile.txt", 2: "current_profile_dynamic.txt", 5: "current_profile_4d.txt"}


def tokens(line: str) -> list[str]:
    """Whitespace tokens up to the first one holding '#' (MoorDyn-C's str::split)."""
    out = []
    for tok in line.split():
        if "#" in tok:
            break
        out.append(tok)
    return out


def currents_mode(deck: Path) -> int:
    for line in deck.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].lower() == "currents":
            return int(float(parts[0]))
    raise ValueError(f"{deck}: no Currents option")


class Grid:
    """A current tabulated on x, y, z and the times t, values v[3, nx, ny, nz, nt]."""

    def __init__(self, x, y, z, t_in, v_in):
        self.x, self.y, self.z = (np.asarray(c, dtype=float) for c in (x, y, z))
        t_in = np.asarray(t_in, dtype=float)
        self.dt = float(np.min(np.diff(t_in)))
        self.nt = math.floor(t_in[-1] / self.dt) + 1
        ts = np.arange(self.nt) * self.dt
        # linear in time, held at the end rows
        flat = v_in.reshape(-1, len(t_in))
        self.v = np.array([np.interp(ts, t_in, row) for row in flat]).reshape(v_in.shape[:-1] + (self.nt,))

    @staticmethod
    def weights(c: np.ndarray, x: float) -> tuple[int, int, float]:
        """Bracketing indices and the weight of the upper one, held beyond the ends."""
        if len(c) == 1 or x <= c[0]:
            return 0, 0, 0.0
        if x >= c[-1]:
            return len(c) - 1, len(c) - 1, 0.0
        i = int(np.searchsorted(c, x))
        return i - 1, i, (x - c[i - 1]) / (c[i] - c[i - 1])

    def velocity(self, x: float, y: float, z: float, t: float) -> np.ndarray:
        if self.nt > 1:
            q = t / self.dt
            n = math.floor(q)
            ft = q - n
            hi = (n + 1) % self.nt
            lo = hi - 1 if hi > 0 else 0
        else:
            lo = hi = 0
            ft = 0.0
        out = np.zeros(3)
        for ia, ib, wx in [self.weights(self.x, x)]:
            for ja, jb, wy in [self.weights(self.y, y)]:
                for ka, kb, wz in [self.weights(self.z, z)]:
                    for i, wi in ((ia, 1.0 - wx), (ib, wx)):
                        for j, wj in ((ja, 1.0 - wy), (jb, wy)):
                            for k, wk in ((ka, 1.0 - wz), (kb, wz)):
                                w = wi * wj * wk
                                if w == 0.0:
                                    continue
                                vt = self.v[:, i, j, k, lo] * (1.0 - ft) + self.v[:, i, j, k, hi] * ft
                                out += w * vt
        return out


def read_steady(path: Path) -> Grid:
    rows = [list(map(float, tokens(line))) for line in path.read_text().splitlines()[3:] if tokens(line)]
    z = [r[0] for r in rows]
    v = np.zeros((3, 1, 1, len(z), 2))
    for k, r in enumerate(rows):
        for c in range(3):
            v[c, 0, 0, k, :] = r[c + 1] if len(r) > c + 1 else 0.0
    return Grid([0.0], [0.0], z, [0.0, 1.0], v)


def read_dynamic(path: Path) -> Grid:
    lines = path.read_text().splitlines()
    z = [float(np.float32(tok)) for tok in tokens(lines[4])]
    nz = len(z)
    t, cols = [], []
    for line in lines[6:]:
        tok = tokens(line)
        if not tok:
            continue
        t.append(float(tok[0]))
        vals = [float(s) for s in tok[1:]]
        cols.append(vals + [0.0] * (3 * nz - len(vals)))
    v = np.zeros((3, 1, 1, nz, len(t)))
    for n, vals in enumerate(cols):
        for c in range(3):
            v[c, 0, 0, :, n] = vals[c * nz:(c + 1) * nz]
    return Grid([0.0], [0.0], z, t, v)


def read_4d(path: Path) -> Grid:
    lines = path.read_text().splitlines()
    dims = [int(s) for s in tokens(lines[0])]
    axes = [[float(s) for s in tokens(lines[k + 1])] for k in range(4)]
    v = np.zeros((3, *dims))
    seen = np.zeros(dims, dtype=bool)
    for k, line in enumerate(lines[5:]):
        tok = tokens(line)
        if not tok:
            continue
        try:
            row = [float(s) for s in tok]
        except ValueError:
            if k == 0:
                continue  # a text header on line 6
            raise
        idx = tuple(axes[a].index(row[a]) for a in range(4))
        assert not seen[idx], f"{path}: grid point repeated"
        seen[idx] = True
        v[(slice(None),) + idx] = row[4:7]
    assert seen.all(), f"{path}: grid point missing"
    return Grid(axes[0], axes[1], axes[2], axes[3], v)


def write_csv(path: Path, rows) -> None:
    with open(path, "w", newline="\n") as fh:
        fh.write("t,x,y,z,zeta,ux,uy,uz,ax,ay,az\n")
        for t, x, y, z, u in rows:
            fh.write(",".join(f"{v:.17g}" for v in (t, x, y, z, 0.0, *u, 0.0, 0.0, 0.0)) + "\n")


def python_reference(case: Path) -> None:
    mode = currents_mode(case / "currents.dat")
    grid = {1: read_steady, 2: read_dynamic, 5: read_4d}[mode](case / FILES[mode])
    points = np.loadtxt(case / "points.txt", ndmin=2)
    write_csv(case / "ref_python.csv", [(t, x, y, z, grid.velocity(x, y, z, t)) for t, x, y, z in points])
    print(f"wrote {case / 'ref_python.csv'}")


def moordyn_c_reference(cases: list[Path], tension_cases: list[Path]) -> None:
    """Run MoorDyn-C on the probe cases (wavekin_mdc_probe.cpp) and on the tension cases
    (currents_mdc_tension.cpp: line node tensions every 0.1 s over TMax = 22 s)."""
    src = Path(os.environ.get("CD_MDC_SRC", "MoorDyn"))
    build = Path(os.environ.get("CD_MDC_BUILD", "MoorDyn-build"))
    gxx = os.environ.get("CD_GXX", "g++")
    dll = build / "source" / "libmoordyn.dll"
    if not dll.exists():
        raise FileNotFoundError(f"MoorDyn-C library not found: {dll} (set CD_MDC_BUILD)")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        env = dict(os.environ)
        env["PATH"] = str(Path(gxx).parent) + os.pathsep + str(work) + os.pathsep + env.get("PATH", "")
        exes = {}
        for name in ("wavekin_mdc_probe", "currents_mdc_tension"):
            exes[name] = work / f"{name}.exe"
            subprocess.run([gxx, "-O2", "-std=c++17", f"-I{src / 'source'}", f"-I{build / 'source'}",
                            str(REPO / "validation" / "scripts" / f"{name}.cpp"), str(dll), "-o", str(exes[name])],
                           check=True, env=env)
        shutil.copy2(dll, work / "libmoordyn.dll")
        for case in cases + tension_cases:
            run = work / case.name
            run.mkdir()
            for f in case.iterdir():
                if not f.name.startswith("ref_"):
                    shutil.copy2(f, run / f.name)
            if case in cases:
                args, out = [str(exes["wavekin_mdc_probe"]), "currents.dat", "points.txt", "out.csv"], "ref_moordyn_c.csv"
            else:
                args, out = [str(exes["currents_mdc_tension"]), "tension.dat", "0.1", "22.0", "out.csv"], \
                    "ref_moordyn_c_tension.csv"
            subprocess.run(args, cwd=run, check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # the repository keeps LF line endings (the probes write CRLF on Windows)
            (case / out).write_bytes((run / "out.csv").read_bytes().replace(b"\r\n", b"\n"))
            print(f"wrote {case / out}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--moordyn-c", action="store_true", help="also run MoorDyn-C on every case")
    args = parser.parse_args()
    cases = sorted(p for p in DATA.iterdir() if (p / "currents.dat").exists())
    tension_cases = sorted(p for p in DATA.iterdir() if (p / "tension.dat").exists())
    for case in cases:
        python_reference(case)
    if args.moordyn_c:
        moordyn_c_reference(cases, tension_cases)


if __name__ == "__main__":
    main()
