# SPDX-License-Identifier: Apache-2.0
"""Regenerate the MoorDyn-C water-kinematics references of tests/data/wavekin_mdc and wavekin_mdc_mean.

Compiles wavekin_mdc_probe.cpp against a MoorDyn-C build (CD_MDC_SRC, CD_MDC_BUILD, CD_GXX as
for the bodies scripts), runs it on the shared decks (WaveKin 3, WaveKin 7, Currents 1) and their
probe points, and writes mdc_wavekin3.csv, mdc_wavekin7.csv and mdc_currents1.csv next to them.
wavekin_mdc_mean holds the same WaveKin 3 and 7 decks with a 0.8 m mean level; its references
come from MoorDyn-C v2.7.2. The wavekin_modes CTest compares CableDyn against these rows.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from bodies_common import GXX, MDC_BUILD, MDC_SRC, REPO, SCRIPTS

FOLDERS = {
    REPO / "tests" / "data" / "wavekin_mdc": (("wavekin3.dat", "points3.txt", "mdc_wavekin3.csv"),
                                              ("wavekin7.dat", "points7.txt", "mdc_wavekin7.csv"),
                                              ("currents1.dat", "pointsc.txt", "mdc_currents1.csv")),
    REPO / "tests" / "data" / "wavekin_mdc_mean": (("wavekin3.dat", "points3.txt", "mdc_wavekin3.csv"),
                                                   ("wavekin7.dat", "points7.txt", "mdc_wavekin7.csv")),
}


def main() -> None:
    dll = MDC_BUILD / "source" / "libmoordyn.dll"
    if not dll.exists():
        raise FileNotFoundError(f"MoorDyn-C library not found: {dll} (set CD_MDC_BUILD)")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        exe = work / "wavekin_mdc_probe.exe"
        inc = [MDC_SRC / "source", MDC_BUILD / "source"]
        env = dict(os.environ)
        env["PATH"] = str(Path(GXX).parent) + os.pathsep + str(work) + os.pathsep + env.get("PATH", "")
        subprocess.run([GXX, "-O2", "-std=c++17", *[f"-I{p}" for p in inc],
                        str(SCRIPTS / "wavekin_mdc_probe.cpp"), str(dll), "-o", str(exe)], check=True, env=env)
        shutil.copy2(dll, work / "libmoordyn.dll")
        for data, cases in FOLDERS.items():
            case_dir = work / data.name
            case_dir.mkdir()
            for f in data.iterdir():
                if not f.name.startswith("mdc_"):
                    shutil.copy2(f, case_dir / f.name)
            for deck, points, out in cases:
                subprocess.run([str(exe), deck, points, out], cwd=case_dir, check=True, env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                shutil.copy2(case_dir / out, data / out)
                print(f"wrote {data / out}")


if __name__ == "__main__":
    main()
