# File: validation/scripts/bodies_score.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Score CableDyn outputs of the bodies validation suite against the stored references.

Usage:
  python validation/scripts/bodies_score.py OUTDIR [CASE_ID ...] [--json FILE]

OUTDIR holds one CableDyn main output per case, found as ``<ID>.out`` or ``<ID>/*.out``
(static decks: ``<ID>_static.out`` / ``<ID>_static_surge10.out`` or ``<ID>/cabledyn_static*.out``;
MoorDyn-parity decks, for metrics with ``cd_run = "_mdparity"``: ``<ID>_mdparity.out`` or
``<ID>/cabledyn_mdparity.out``).
Each metric of ``validation/bodies/cases.json`` is evaluated with the formulas of
``bodies_metrics.py`` (``bodies_summary.py`` for references kept as summary values only, such as
the OrcaFlex twin of V-D1b) and printed with its gate; the exit status is 1 when any evaluated
metric fails. Metrics whose CableDyn channel or reference is missing are reported, not failed.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

import bodies_metrics as bm
import bodies_summary as bsum
from bodies_common import BODIES, REFS, load_reference, load_summary, read_series

PEND_L = 10.0


def _find_out(outdir: Path, cid: str, kind: str = "") -> Path | None:
    stem = f"{cid}{kind}"
    cands = [outdir / f"{stem}.out"]
    sub = outdir / cid
    if sub.is_dir():
        pat = f"cabledyn{kind}*.out" if kind else "cabledyn.out"
        cands += sorted(p for p in sub.glob(pat) if p.name.count(".") == 1)
        if not kind:
            cands += sorted(p for p in sub.glob("*.out") if p.name.count(".") == 1 and "_" not in p.stem)
    for p in cands:
        if p.exists():
            return p
    return None


def _channels(path: Path) -> dict[str, np.ndarray]:
    cols, data = read_series(path)
    out = {c: data[:, i] for i, c in enumerate(cols)}
    lower = {c.lower(): v for c, v in out.items()}
    out.update({k: v for k, v in lower.items() if k not in out})
    return out


def _get(ch: dict, name: str):
    if name is None:
        return None
    if name.startswith("derived:"):
        return _derived(ch, name.split(":", 1)[1])
    return ch.get(name, ch.get(name.lower()))


def _derived(ch: dict, name: str):
    g = lambda n: ch.get(n, ch.get(n.lower()))  # noqa: E731
    if name == "pend_angle":
        xa, za, xb, zb = g("Rod1Px"), g("Rod1Pz"), g("Rod1N10Px"), g("Rod1N10Pz")
        if any(v is None for v in (xa, za, xb, zb)):
            return None
        return np.degrees(np.arctan2(xb - xa, za - zb))
    if name == "anchor_FH":
        fh = g("Point4FH")
        if fh is not None:
            return fh
        fx, fy = g("Point4Fx"), g("Point4Fy")
        return None if fx is None else np.hypot(fx, fy)
    return None


def _analytic_value(cid: str, key: str):
    f = REFS / cid / "analytic.json"
    if not f.exists():
        return None
    v = json.loads(f.read_text())["values"]
    return v.get(key)


def evaluate(cid: str, spec: dict, outdir: Path) -> list[dict]:
    rows = []
    main = _find_out(outdir, cid)
    ch = _channels(main) if main else {}
    runs = {"": ch}
    for m in spec["metrics"]:
        run = m.get("cd_run", "")
        if run not in runs:
            p = _find_out(outdir, cid, run)
            runs[run] = _channels(p) if p else {}
        r = dict(case=cid, metric=m["id"], kind=m["metric"], gate=m["gate"], value=None, status="MISSING")
        try:
            if m.get("cd_run") and not runs[m["cd_run"]]:
                raise FileNotFoundError(f"{cid}{m['cd_run']}.out")
            r["value"] = _evaluate_one(cid, m, runs[m.get("cd_run", "")], outdir)
        except (KeyError, ValueError, FileNotFoundError, IndexError) as exc:
            r["status"] = f"MISSING ({exc.__class__.__name__}: {exc})"
        if r["value"] is not None and not (isinstance(r["value"], float) and math.isnan(r["value"])):
            r["status"] = "PASS" if abs(r["value"]) <= m["gate"] else "FAIL"
        elif r["status"] == "MISSING" and not main:
            r["status"] = "MISSING (no CableDyn output)"
        rows.append(r)
    return rows


def _on_ref_times(t, y, tr):
    """Sample the CableDyn series at the reference's own times (within the CableDyn span).

    The RMS metrics then compare the two series sample for sample at the reference's rate;
    interpolating a coarse reference onto CableDyn's time steps instead would score the
    reference's interpolation error on sharp events (snap loads) as a CableDyn difference.
    """
    t, y, tr = np.asarray(t, float), np.asarray(y, float), np.asarray(tr, float)
    tol = 1e-9 * max(1.0, float(abs(tr).max()))
    keep = (tr >= t[0] - tol) & (tr <= t[-1] + tol)
    return tr[keep], np.interp(tr[keep], t, y)


def _evaluate_one(cid, m, ch, outdir):
    kind, win = m["metric"], m.get("window")
    if m["cd"].startswith(("static:", "static_surge10:")):
        tag, names = m["cd"].split(":", 1)
        kindtag = "_static" if tag == "static" else "_static_surge10"
        p = _find_out(outdir, cid, kindtag)
        if p is None:
            raise FileNotFoundError(f"{cid}{kindtag}.out")
        sch = _channels(p)
        vals = [float(_get(sch, n)[0]) for n in names.split(",")]
        if kind == "e_eq":
            return abs(vals[0] - _analytic_value(cid, m["ref"]))
        if kind == "e_rel_spread":
            return (max(vals) - min(vals)) / abs(np.mean(vals))
        ref, _ = load_reference(cid, m["ref_code"])
        return abs(vals[0] - float(ref[m["ref"]][0])) / abs(float(ref[m["ref"]][0]))
    if m["ref_code"] == "self":
        ys = [_get(ch, n) for n in m["cd"].split(",")]
        if any(v is None for v in ys):
            raise KeyError(f"CableDyn channel {m['cd']}")
        t = ch.get("Time", ch.get("time"))
        if kind == "e_drift_abs":
            return max(float(np.max(np.abs(v - v[0]))) for v in ys)
        if kind == "decay_ratio":
            return bm.decay_ratio(t, ys[0], win)
        raise ValueError(f"metric {kind} is not a self metric")
    y = _get(ch, m["cd"])
    if y is None:
        raise KeyError(f"CableDyn channel {m['cd']}")
    t = ch.get("Time", ch.get("time"))
    if m["ref_code"] == "analytic":
        if kind == "e_T":
            T = m.get("ref_value") or _analytic_value(cid, m["ref"])
            return bm.e_T(t, y, T, window=win)
        if kind == "e_eq":
            zr = _analytic_value(cid, m["ref"])
            return abs(bm.cycle_mean(t, y, win) - zr)
        ref, _ = load_reference(cid, "analytic")
        tr, yr = ref["Time"], ref[m["ref"]]
        return bm.e_rms(*_on_ref_times(t, y, tr), tr, yr, win)
    summary = load_summary(cid, m["ref_code"])
    if summary is not None:
        return bsum.score(kind, m, summary, t, y)
    ref, _ = load_reference(cid, m["ref_code"])
    yr = _get(ref, m["ref"])
    tr = ref["Time"]
    if kind == "e_rms":
        return bm.e_rms(*_on_ref_times(t, y, tr), tr, yr, win)
    if kind == "e_rms_star":
        return bm.e_rms_star(*_on_ref_times(t, y, tr), tr, yr, win)
    if kind == "e_T":
        return bm.e_T(t, y, tr, yr, win)
    if kind == "e_pk":
        return bm.e_pk(t, y, tr, yr, win)
    if kind == "e_t0":
        return abs(float(y[0]) - float(yr[0])) / abs(float(yr[0]))
    raise ValueError(f"metric {kind} is not scored from outputs")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("outdir", type=Path)
    ap.add_argument("cases", nargs="*")
    ap.add_argument("--json", type=Path)
    a = ap.parse_args(argv)
    manifest = json.loads((BODIES / "cases.json").read_text())
    rows = []
    for cid, spec in manifest.items():
        if a.cases and cid not in a.cases:
            continue
        rows += evaluate(cid, spec, a.outdir)
    w = max(len(f"{r['case']}:{r['metric']}") for r in rows) + 2
    print(f"{'case:metric'.ljust(w)}{'kind'.ljust(13)}{'value':>12}{'gate':>11}  status")
    for r in rows:
        v = "" if r["value"] is None else f"{r['value']:.3e}"
        print(f"{(r['case'] + ':' + r['metric']).ljust(w)}{r['kind'].ljust(13)}{v:>12}{r['gate']:>11.1e}  {r['status']}")
    n_fail = sum(r["status"] == "FAIL" for r in rows)
    n_pass = sum(r["status"] == "PASS" for r in rows)
    print(f"\n{n_pass} pass, {n_fail} fail, {len(rows) - n_pass - n_fail} not evaluated")
    if a.json:
        a.json.write_text(json.dumps(rows, indent=1) + "\n")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
