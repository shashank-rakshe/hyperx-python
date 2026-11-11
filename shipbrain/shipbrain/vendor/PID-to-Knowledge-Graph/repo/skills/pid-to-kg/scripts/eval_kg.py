#!/usr/bin/env python3
"""Score a built graph against a hand-checked gold annotation.

Gold file (JSON), usually covering one or a few sheets:

    {
      "sheets": ["660-PI-203"],                      # drawing numbers the gold covers
      "tags": ["660-TK-004", "FIT-0502", ...],       # every tagged item on those sheets
      "feeds": [["660-EQ-002", "660-PP-011"], ...],  # equipment-level flow (upstream, downstream)
      "instrument_at": {"FIT-0502": "660-PP-011"},   # nearest equipment to where it senses
      "loops": {"F-0502": ["FE-0502", "FIT-0502"]},  # loop key -> member tags
      "feeds_scope": "within_sheets"                 # optional: "all" (default), "within_sheets"
                                                     # (both ends on gold sheets), "equipment" (both ends equipment)
    }

Reports precision/recall/F1 for tags and flow, instrument placement accuracy,
and loop recall with member overlap. Only graph items on the gold sheets are
scored, so a partial gold set gives a fair spot check.

Usage:
    python eval_kg.py work/my-plant/kg gold.json [--json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg.isa import normalize_tag  # noqa: E402
from pidkg.store import Graph  # noqa: E402


def prf(pred: set, gold: set) -> dict:
    tp = len(pred & gold)
    p = tp / len(pred) if pred else 0.0
    r = tp / len(gold) if gold else 0.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    return {"precision": round(p, 3), "recall": round(r, 3), "f1": round(f, 3), "tp": tp,
            "false_positives": sorted(map(str, pred - gold)), "missed": sorted(map(str, gold - pred))}


def near_equipment(g: Graph, nid: str, hops: int = 60) -> set[str]:
    """Equipment directly measured, or nearest up/downstream of a measured pipe or item."""
    n = g.nodes[nid]
    if n.type == "Equipment":
        return {n.tag or n.label}
    found: set[str] = set()
    for direction in ("up", "down"):
        best = None
        for other, d in g.walk(nid, direction, max_depth=hops):
            if g.nodes[other].type == "Equipment":
                best = (d, g.nodes[other].tag or g.nodes[other].label)
                break
        if best:
            found.add(best[1])
    return found


def evaluate(g: Graph, gold: dict) -> dict:
    sheets = {f"SHEET:{normalize_tag(s)}" for s in gold.get("sheets", [])}
    on_sheet = {n.id for n in g.kg.nodes if not sheets or set(n.sheets) & sheets}

    def find(tag: str):
        """Prefer the node with this tag that is drawn on the gold sheets."""
        t = normalize_tag(tag)
        hits = [n.id for n in g.kg.nodes if n.tag == t and n.id in on_sheet]
        return hits[0] if hits else g.find(tag)

    pred_tags = {n.tag for n in g.kg.nodes if n.tag and n.id in on_sheet
                 and n.type in ("Equipment", "Instrument", "Component")}
    gold_tags = {normalize_tag(t) for t in gold.get("tags", [])}
    res: dict = {"tags": prf(pred_tags, gold_tags)}

    scope = gold.get("feeds_scope", "all")
    feeds = [e for es in g.out.values() for e in es if e.type == "FEEDS"]  # honours the PFD/P&ID view
    if scope == "within_sheets":
        feeds = [e for e in feeds if e.source in on_sheet and e.target in on_sheet]
    else:
        feeds = [e for e in feeds if e.source in on_sheet or e.target in on_sheet]
    if scope in ("equipment", "within_sheets"):
        feeds = [e for e in feeds if g.nodes[e.source].type == "Equipment" and g.nodes[e.target].type == "Equipment"]
    pred_feeds = {(g.nodes[e.source].tag or g.nodes[e.source].label, g.nodes[e.target].tag or g.nodes[e.target].label)
                  for e in feeds}
    gold_feeds = {(normalize_tag(a) or a, normalize_tag(b) or b) for a, b in gold.get("feeds", [])}
    norm_pred = {(normalize_tag(a) or a, normalize_tag(b) or b) for a, b in pred_feeds}
    res["flow"] = prf(norm_pred, gold_feeds)

    placed, wrong = 0, []
    for tag, eq in gold.get("instrument_at", {}).items():
        nid = find(tag)
        if nid is None:
            wrong.append({"tag": tag, "expected": eq, "got": "missing"})
            continue
        targets = [e.target for e in g.out[nid] if e.type == "MEASURES"]
        if g.nodes[nid].attributes.get("inline"):
            targets.append(nid)
        got = set().union(*(near_equipment(g, t) for t in targets)) if targets else set()
        if normalize_tag(eq) in {normalize_tag(x.split("@")[0]) for x in got}:
            placed += 1
        else:
            wrong.append({"tag": tag, "expected": eq, "got": sorted(got) or "unlocated"})
    n_inst = len(gold.get("instrument_at", {}))
    res["instrument_placement"] = {"accuracy": round(placed / n_inst, 3) if n_inst else None,
                                   "correct": placed, "total": n_inst, "errors": wrong}

    loops_found, overlaps, loop_detail = 0, [], []
    for key, members in gold.get("loops", {}).items():
        lid = next((n.id for n in g.kg.nodes if n.type == "ControlLoop" and n.id in on_sheet | {n.id}
                    and n.label.split("@")[0] == key and set(n.sheets) & (sheets or set(n.sheets))), None)
        gm = {normalize_tag(m) for m in members}
        if lid is None:
            loop_detail.append({"loop": key, "found": False})
            continue
        loops_found += 1
        pm = {g.nodes[e.source].tag or g.nodes[e.source].label for e in g.inn[lid] if e.type == "MEMBER_OF"}
        jac = len(pm & gm) / len(pm | gm) if pm | gm else 1.0
        overlaps.append(jac)
        loop_detail.append({"loop": key, "found": True, "member_jaccard": round(jac, 3),
                            "missing_members": sorted(gm - pm), "extra_members": sorted(pm - gm)})
    n_loops = len(gold.get("loops", {}))
    res["loops"] = {"recall": round(loops_found / n_loops, 3) if n_loops else None,
                    "mean_member_jaccard": round(sum(overlaps) / len(overlaps), 3) if overlaps else None,
                    "detail": loop_detail}
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kg", type=Path)
    ap.add_argument("gold", type=Path)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    g = Graph.load(a.kg / "graph.json" if a.kg.is_dir() else a.kg)
    res = evaluate(g, json.loads(a.gold.read_text(encoding="utf-8")))
    if a.json:
        print(json.dumps(res, indent=1))
        return 0
    t, f, ip, lp = res["tags"], res["flow"], res["instrument_placement"], res["loops"]
    print(f"Tags:   P {t['precision']:.2f}  R {t['recall']:.2f}  F1 {t['f1']:.2f}"
          f"   missed: {', '.join(t['missed']) or '-'}   extra: {', '.join(t['false_positives']) or '-'}")
    print(f"Flow:   P {f['precision']:.2f}  R {f['recall']:.2f}  F1 {f['f1']:.2f}"
          f"   missed: {f['missed'] or '-'}   extra: {f['false_positives'] or '-'}")
    if ip["total"]:
        print(f"Instrument placement: {ip['correct']}/{ip['total']}"
              + "".join(f"\n   {w['tag']}: expected {w['expected']}, got {w['got']}" for w in ip["errors"]))
    if lp["recall"] is not None:
        print(f"Loops:  recall {lp['recall']:.2f}, mean member overlap {lp['mean_member_jaccard']}")
        for d in lp["detail"]:
            if not d["found"] or d.get("missing_members") or d.get("extra_members"):
                print(f"   {d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
