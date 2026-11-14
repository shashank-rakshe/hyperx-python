# File: validation/scripts/bodies_decks.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Deck writers for the bodies validation suite: one model, three dialects.

A model is a plain dict (see ``bodies_cases.py``) with LINE TYPES, ROD TYPES, BODIES, RODS,
POINTS and LINES rows in MoorDyn v2 column order. ``md_deck`` writes the MoorDyn-C deck,
``mdf_deck`` the MoorDyn-F deck (with an OUTPUTS list) and ``cd_deck`` the CableDyn deck in
its own dialect (MoorDyn v2 rows, 7-column ROD TYPES with CdEnd/CaEnd, 14-column
BODY rows, R<N>A/B line ends, TURBINES, CableDyn OPTIONS).
"""

from __future__ import annotations

G = 9.80665
RHO = 1025.0


def _fmt(v) -> str:
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        return str(v)
    if v == 0:
        return "0"
    a = abs(v)
    if 1e-3 <= a < 1e6:
        s = f"{v:.10g}"
    else:
        s = f"{v:.8e}"
    return s


def _row(vals, widths=None) -> str:
    toks = [_fmt(v) for v in vals]
    return "  ".join(toks)


def _line_types(model, dialect):
    out = []
    lts = model.get("line_types", [])
    if not lts:
        return out
    out.append("---------------------- LINE TYPES ------------------------------------")
    if dialect == "cd":
        out.append("TypeName  Diam  MassDenInAir  EA  BA/-zeta  EI  Cd_n  Cd_t  Ca_n  Ca_t")
        out.append("(-)  (m)  (kg/m)  (N)  (N-s/-)  (N-m^2)  (-)  (-)  (-)  (-)")
        for lt in lts:
            out.append(_row([lt["name"], lt["d"], lt["m"], lt["EA"], lt["BA"], lt.get("EI", 0.0),
                             lt["Cd"], lt["CdAx"], lt["Ca"], lt["CaAx"]]))
    else:
        out.append("TypeName  Diam  Mass/m  EA  BA/-zeta  EI  Cd  Ca  CdAx  CaAx")
        out.append("(name)  (m)  (kg/m)  (N)  (N-s)  (N-m^2)  (-)  (-)  (-)  (-)")
        for lt in lts:
            out.append(_row([lt["name"], lt["d"], lt["m"], lt["EA"], lt["BA"], lt.get("EI", 0.0),
                             lt["Cd"], lt["Ca"], lt["CdAx"], lt["CaAx"]]))
    return out


def _rod_types(model, dialect):
    out = []
    rts = model.get("rod_types", [])
    if not rts:
        return out
    out.append("---------------------- ROD TYPES -------------------------------------")
    ext = dialect == "cd" and any(("CdAx" in r or "CaAx" in r) for r in rts)
    if ext:
        out.append("TypeName  Diam  Mass/m  Cd  Ca  CdEnd  CaEnd  CdAx  CaAx")
        out.append("(name)  (m)  (kg/m)  (-)  (-)  (-)  (-)  (-)  (-)")
    else:
        out.append("TypeName  Diam  Mass/m  Cd  Ca  CdEnd  CaEnd")
        out.append("(name)  (m)  (kg/m)  (-)  (-)  (-)  (-)")
    for r in rts:
        vals = [r["name"], r["d"], r["m"], r["Cd"], r["Ca"], r["CdEnd"], r["CaEnd"]]
        if ext:
            vals += [r.get("CdAx", 0.0), r.get("CaAx", 0.0)]
        out.append(_row(vals))
    return out


def _bodies(model):
    out = []
    bs = model.get("bodies", [])
    if not bs:
        return out
    out.append("---------------------- BODIES ----------------------------------------")
    out.append("ID  Attachment  X0  Y0  Z0  r0  p0  y0  Mass  CG*  I*  Volume  CdA*  Ca*")
    out.append("(#)  (-)  (m)  (m)  (m)  (deg)  (deg)  (deg)  (kg)  (m)  (kg-m^2)  (m^3)  (m^2)  (-)")
    for b in bs:
        out.append(_row([b["id"], b["att"], *b["xyz"], *b["rpy"], b["mass"], b["cg"], b["I"],
                         b["vol"], b["cda"], b["ca"]]))
    return out


def _rods(model):
    out = []
    rs = model.get("rods", [])
    if not rs:
        return out
    out.append("---------------------- RODS ------------------------------------------")
    out.append("ID  RodType  Attachment  Xa  Ya  Za  Xb  Yb  Zb  NumSegs  RodOutputs")
    out.append("(#)  (name)  (#/key)  (m)  (m)  (m)  (m)  (m)  (m)  (-)  (-)")
    for r in rs:
        out.append(_row([r["id"], r["type"], r["att"], *r["a"], *r["b"], r["nseg"], r.get("out", "-")]))
    return out


def _points(model, dialect):
    out = []
    ps = model.get("points", [])
    if not ps:
        return out
    out.append("---------------------- POINTS ----------------------------------------")
    out.append("ID  Attachment  X  Y  Z  Mass  Volume  CdA  Ca")
    out.append("(#)  (-)  (m)  (m)  (m)  (kg)  (m^3)  (m^2)  (-)")
    for p in ps:
        att = p["att"]
        xyz = p["xyz"]
        if dialect == "mdc" and "mdc_att" in p:
            att = p["mdc_att"]
            xyz = p.get("mdc_xyz", xyz)
        if dialect == "mdf" and "mdf_att" in p:
            att = p["mdf_att"]
            xyz = p.get("mdf_xyz", xyz)
        out.append(_row([p["id"], att, *xyz, p.get("m", 0.0), p.get("v", 0.0), p.get("cda", 0.0),
                         p.get("ca", 0.0)]))
    return out


def _lines(model):
    out = []
    ls = model.get("lines", [])
    if not ls:
        return out
    out.append("---------------------- LINES -----------------------------------------")
    out.append("ID  LineType  AttachA  AttachB  UnstrLen  NumSegs  LineOutputs")
    out.append("(#)  (name)  (#)  (#)  (m)  (-)  (-)")
    for ln in ls:
        out.append(_row([ln["id"], ln["type"], ln["a"], ln["b"], ln["L"], ln["nseg"], ln.get("out", "-")]))
    return out


def _header(title, notes):
    out = ["--------------------- MoorDyn Input File ------------------------------", title]
    out += [f"-- {n}" for n in notes]
    return out


def md_options(o: dict, dialect: str) -> list[str]:
    """MoorDyn options block. ``o`` keys: dtM, depth, kbot, cbot, dtIC, TmaxIC, CdScaleIC,
    threshIC, WaveKin, extra (list of raw rows)."""
    out = ["---------------------- OPTIONS -----------------------------------------"]
    rows = [
        (o.get("dtM", 1e-3), "dtM"),
        (o.get("g", G), "g"),
        (o.get("rho", RHO), "WtrDnsty"),
        (o.get("depth", 100.0), "WtrDpth"),
        (o.get("kbot", 1.0e5), "kbot"),
        (o.get("cbot", 1.0e4), "cbot"),
        (o.get("dtIC", 1.0), "dtIC"),
        (o.get("TmaxIC", 0.0), "TmaxIC"),
        (o.get("CdScaleIC", 4.0), "CdScaleIC"),
        (o.get("threshIC", 1.0e-5), "threshIC"),
    ]
    if "WaveKin" in o:
        rows.append((o["WaveKin"], "WaveKin"))
    for v, k in rows:
        out.append(f"{_fmt(v)}  {k}")
    if dialect == "mdc":
        out += ["0  writeLog", "1  disableOutput", "1  disableOutTime"]
    for raw in o.get("extra", []):
        out.append(raw)
    return out


def md_deck(model: dict, opts: dict, dialect: str = "mdc", outputs: list[str] | None = None) -> str:
    """MoorDyn-C (``mdc``) or MoorDyn-F (``mdf``) deck text."""
    out = _header(model["title"], model.get("notes", []) + model.get("md_notes", []))
    out += _line_types(model, "md")
    out += _rod_types(model, "md")
    out += _bodies(model)
    out += _rods(model)
    out += _points(model, dialect)
    out += _lines(model)
    out += md_options(opts, dialect)
    if dialect == "mdf":
        out.append(f"{_fmt(opts.get('dtOut', 0.05))}  dtOut")
        if outputs:
            out.append("---------------------- OUTPUTS -----------------------------------------")
            out += outputs
            out.append("END")
    out.append("------------------------- need this line --------------------------------")
    return "\n".join(out) + "\n"


def cd_deck(model: dict, opts: dict, outputs: list[str]) -> str:
    """CableDyn deck in the MoorDyn v2 row dialect.

    ``opts`` rows are written ``value keyword``; ``opts['sections']`` may add raw extra
    sections (TURBINES, EXTERNAL LOADS, BODY HYDRO, SYROPE IC, ...).
    """
    out = ["--------------------- CableDyn Input File ------------------------------------",
           model["title"]]
    out += [f"-- {n}" for n in model.get("notes", []) + model.get("cd_notes", [])]
    out += _line_types(model, "cd")
    out += _rod_types(model, "cd")
    out += _bodies(model)
    out += _rods(model)
    for name, rows in opts.get("sections", []):
        out.append(f"--------------------- {name} " + "-" * max(4, 50 - len(name)))
        out += rows
    out += _points(model, "cd")
    out += _lines(model)
    out.append("--------------------- OPTIONS ------------------------------------------")
    base = [
        (opts.get("g", G), "g"),
        (opts.get("rho", RHO), "rhoW"),
    ]
    if opts.get("depth") is not None:
        base.append((opts["depth"], "WtrDpth"))
    base += [
        (opts.get("kbot", 1.0e5), "kBot"),
        (opts.get("cbot", 1.0e4), "cBot"),
    ]
    for v, k in base:
        out.append(f"{_fmt(v)}  {k}")
    for v, k in opts.get("rows", []):
        out.append(f"{_fmt(v)}  {k}")
    out.append("--------------------- OUTPUTS ------------------------------------------")
    out += [f'"{c}"' for c in outputs]
    out.append("--------------------- need this line -----------------------------------")
    return "\n".join(out) + "\n"


def mdf_driver_inp(deck_name: str, root: str, tmax: float, dtc: float, depth: float,
                   inputs_mode: int = 0, inputs_file: str = "") -> str:
    """MoorDyn-F standalone driver input (uncoupled or with a time-series input file)."""
    return f"""MoorDyn driver input file
bodies validation suite
---------------------- ENVIRONMENTAL CONDITIONS -------------------------------
{_fmt(G)} Gravity
{_fmt(RHO)} rhoW
{_fmt(depth)} WtrDpth
---------------------- MOORDYN ------------------------------------------------
"{deck_name}" MDInputFile
"{root}" OutRootName
{_fmt(tmax)} TMax
{_fmt(dtc)} dtC
{inputs_mode} InputsMode
"{inputs_file}" InputsFile
0 NumTurbines
---------------------- Initial Positions --------------------------------------
ref_X ref_Y surge_init sway_init heave_init roll_init pitch_init yaw_init
(m) (m) (m) (m) (m) (rad) (rad) (rad)
0 0 0 0 0 0 0 0
END of driver input file
"""
