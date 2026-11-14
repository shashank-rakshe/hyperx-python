# SPDX-License-Identifier: Apache-2.0
"""Author the end-to-end active-tension A/B model files for CableDyn (=5) vs MoorDyn (=3).

Given a base UMaine coupled-model directory that already resolves the settle A/B
(``Main_settle_cd5.fst`` / ``Main_settle_md3.fst`` and their referenced inputs), this
script writes the files that add ServoDyn cable control on top of that quiescent,
still-water isolation model:

* ``CableDyn_UMaine_ctrl.dat`` / ``MoorDyn_UMaine_ctrl.dat`` -- the two mooring decks
  with an added CONTROL section assigning channel 1 to line 1.
* ``ServoDyn_at.dat`` -- a ServoDyn input with every control group off except cable
  control (CCmode = 5), pointing at the deterministic ``libcabctrl.dll`` controller.
* ``cabctrl.IN`` -- a placeholder DLL input file (the controller ignores it).
* ``Main_at_cd5.fst`` / ``Main_at_md3.fst`` -- the two run decks (CompServo = 1,
  TMax long enough for the pay-out/haul-in schedule to play out).

The controller DLL (``validation/scripts/cable_control_dll/cabctrl_discon.f90``) drives an identical
DeltaL(t) schedule in both runs, so any difference in the controlled line's tension is
attributable to the mooring solver alone.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

TMAX = "260.0"


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def _write(p: Path, text: str) -> None:
    p.write_text(text, encoding="utf-8")
    print(f"  wrote {p.name}")


def author_cabledyn_ctrl_deck(base: Path, out: Path) -> None:
    """Add a CONTROL section (channel 1 -> line 1) and an OUTPUTS section.

    CONTROL is inserted before the OPTIONS header; OUTPUTS (fairlead + anchor tension
    for all three lines, so the module emits them into the coupled ``.out``) is inserted
    before the trailing sentinel line when the base deck has no OUTPUTS section.
    """
    lines = _read(base).splitlines()
    control = [
        "--------------------------- CONTROL -------------------------------------------",
        "ChannelID  Lines",
        "(-)        (-)",
        "1          1,2,3",
    ]
    outputs = [
        "--------------------------- OUTPUTS -------------------------------------------",
        "FairTen1",
        "FairTen2",
        "FairTen3",
        "AnchTen1",
        "AnchTen2",
        "AnchTen3",
        "END",
    ]
    result: list[str] = []
    ctrl_done = False
    # A deck that already requests channels keeps its own OUTPUTS section.
    out_done = any(
        ln.lstrip().startswith("---") and "OUTPUTS" in ln.upper() for ln in lines
    )
    for line in lines:
        stripped = line.lstrip()
        if not ctrl_done and stripped.startswith("---") and "OPTIONS" in line.upper():
            result.extend(control)
            ctrl_done = True
        if (
            not out_done
            and stripped.startswith("---")
            and "need this line" in line.lower()
        ):
            result.extend(outputs)
            out_done = True
        result.append(line)
    if not ctrl_done:
        raise SystemExit("CableDyn deck: OPTIONS header not found")
    if not out_done:
        result.extend(outputs)
    _write(out, "\n".join(result) + "\n")


def author_moordyn_ctrl_deck(base: Path, out: Path) -> None:
    """Insert a CONTROL section (channel 1 -> line 1) before SOLVER OPTIONS."""
    lines = _read(base).splitlines()
    control = [
        "---------------------- CONTROL ----------------------------------------------",
        "ChannelID  Lines",
        "(-)        (-)",
        "1          1,2,3",
    ]
    result: list[str] = []
    inserted = False
    for line in lines:
        if (
            not inserted
            and line.lstrip().startswith("---")
            and "OPTION" in line.upper()
        ):
            result.extend(control)
            inserted = True
        result.append(line)
    if not inserted:
        raise SystemExit("MoorDyn deck: OPTIONS header not found")
    _write(out, "\n".join(result) + "\n")


def author_servodyn(base: Path, out: Path) -> None:
    """Disable every control group except cable control (CCmode = 5, cabctrl DLL).

    No EXavrSWAP flag is written: the extended Bladed avrSWAP (which carries the cable-control
    records 2601/2602 the DLL drives) is hard-coded on in OpenFAST v5 -- ServoDyn's parser sets
    ``EXavrSWAP = .TRUE.`` unconditionally and the field is commented out of the input file
    (ServoDyn_IO.f90), avrSWAP is always allocated to the extended size (BladedInterface.f90), and
    the cable retrieve is gated only on ``NumCableControl > 0``. Writing an EXavrSWAP line would
    desync the positional parse, so the correct action is to write none.
    """
    text = _read(base)

    def set_token(text: str, name: str, value: str) -> str:
        pat = re.compile(rf"^(\s*)\S+(\s+{re.escape(name)}\s+-.*)$", re.MULTILINE)
        if not pat.search(text):
            raise SystemExit(f"ServoDyn: field {name} not found")
        return pat.sub(rf"\g<1>{value}\g<2>", text, count=1)

    text = set_token(text, "PCMode", "0")
    text = set_token(text, "VSContrl", "0")
    text = set_token(text, "YCMode", "0")
    text = set_token(text, "HSSBrMode", "0")
    # Never engage the generator: with CompAero = 0 the rotor sees no aerodynamic torque,
    # and a locked-drivetrain generator reaction would otherwise disturb the platform. The
    # active-tension command is then the only driver, so the platform stays quiescent.
    text = set_token(text, "TimGenOn", "99999.0")
    text = set_token(text, "CCmode", "5")
    text = set_token(text, "DLL_FileName", '"libcabctrl.dll"')
    text = set_token(text, "DLL_InFile", '"cabctrl.IN"')
    text = set_token(text, "DLL_ProcName", '"DISCON"')
    text = set_token(text, "DLL_DT", '"default"')
    _write(out, text)


# The UMaine deck's PtfmInit (yaw 180) is inconsistent with the mooring frame, so a free
# platform snaps violently to its true equilibrium (yaw ~0, surge -1.1, heave -1.05) at ~2.3 MN.
# Holding the platform at that free-settled equilibrium pose gives a transient-free, physical
# baseline so the active-tension response is the only signal. Re-derive this pose from a free
# run's late-window mean (validation/scripts/openfast_activetension_ab.py prints PtfmSurge/Heave/Yaw) if the deck geometry changes.
HELD_POSE = {
    "PtfmSurge": "-1.1",
    "PtfmSway": "0.0",
    "PtfmHeave": "-1.05",
    "PtfmRoll": "0.0",
    "PtfmPitch": "0.0",
    "PtfmYaw": "0.0",
}


def author_held_elastodyn(base: Path, out: Path) -> None:
    """Hold all 6 platform DOFs and pin them at the free-settled equilibrium pose."""
    import re

    text = _read(base)
    text = re.sub(
        r"^True( +Ptfm(Sg|Sw|Hv|R|P|Y)DOF)", r"False\1", text, flags=re.MULTILINE
    )
    for name, value in HELD_POSE.items():
        text, n = re.subn(
            rf"(?m)^\s*\S+(\s+{name}\s+-\s.*)$", value.rjust(11) + r"\1", text
        )
        if n != 1:
            raise SystemExit(
                f"ElastoDyn: PtfmInit field {name} not found (matched {n})"
            )
    _write(out, text)


def author_fst(base: Path, out: Path, mooring_file: str, ed_file: str) -> None:
    text = _read(base)

    def set_token(text: str, name: str, value: str) -> str:
        pat = re.compile(rf"^(\s*)\S+(\s+{re.escape(name)}\s+-.*)$", re.MULTILINE)
        if not pat.search(text):
            raise SystemExit(f"fst: field {name} not found")
        return pat.sub(rf"\g<1>{value}\g<2>", text, count=1)

    def set_quoted(text: str, name: str, value: str) -> str:
        pat = re.compile(rf'^(\s*)"[^"]*"(\s+{re.escape(name)}\s+-.*)$', re.MULTILINE)
        if not pat.search(text):
            raise SystemExit(f"fst: quoted field {name} not found")
        return pat.sub(rf'\g<1>"{value}"\g<2>', text, count=1)

    text = set_token(text, "TMax", TMAX)
    text = set_token(text, "CompServo", "1")
    text = set_quoted(text, "ServoFile", "ServoDyn_at.dat")
    text = set_quoted(text, "MooringFile", mooring_file)
    text = set_quoted(text, "EDFile", ed_file)
    _write(out, text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "model_dir",
        type=Path,
        help="UMaine coupled-model dir with the settle A/B files",
    )
    ap.add_argument(
        "--servodyn-template",
        type=Path,
        required=True,
        help="a valid ServoDyn .dat to base the cable-only ServoDyn on",
    )
    args = ap.parse_args()

    d = args.model_dir
    ed_base = "IEA-15-240-RWT-UMaineSemi_ElastoDynT1.dat"
    ed_held = "IEA-15-240-RWT-UMaineSemi_ElastoDynT1_at.dat"
    print(f"Authoring active-tension A/B model in {d}")
    author_cabledyn_ctrl_deck(d / "CableDyn_UMaine.dat", d / "CableDyn_UMaine_ctrl.dat")
    author_moordyn_ctrl_deck(d / "MoorDyn_UMaine.dat", d / "MoorDyn_UMaine_ctrl.dat")
    author_servodyn(args.servodyn_template, d / "ServoDyn_at.dat")
    author_held_elastodyn(d / ed_base, d / ed_held)
    _write(
        d / "cabctrl.IN", "! placeholder DLL input; the cabctrl controller ignores it\n"
    )
    author_fst(
        d / "Main_settle_cd5.fst",
        d / "Main_at_cd5.fst",
        "CableDyn_UMaine_ctrl.dat",
        ed_held,
    )
    author_fst(
        d / "Main_settle_md3.fst",
        d / "Main_at_md3.fst",
        "MoorDyn_UMaine_ctrl.dat",
        ed_held,
    )
    print("Done.")


if __name__ == "__main__":
    main()
