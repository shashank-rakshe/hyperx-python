"""Quality checks on a built graph, and the QA report Claude uses for its second pass."""

from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Optional

from .isa import SENSING_ROLES, normalize_tag, parse_isa_tag
from .models import KnowledgeGraph

LOW_CONFIDENCE = 0.6
_MONTHS = re.compile(r"^(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*-\d")


def run_qa(kg: KnowledgeGraph, work_dir: Optional[Path] = None) -> list[dict[str, Any]]:
    """Return graph-level issues (build issues are already in ``kg.issues``)."""
    issues: list[dict[str, Any]] = []
    nodes = {n.id: n for n in kg.nodes}
    flow_deg: dict[str, int] = defaultdict(int)
    any_deg: dict[str, int] = defaultdict(int)
    measured: set[str] = set()
    for e in kg.edges:
        any_deg[e.source] += 1
        any_deg[e.target] += 1
        if e.type == "FLOWS_TO":
            flow_deg[e.source] += 1
            flow_deg[e.target] += 1
        elif e.type == "MEASURES":
            measured.add(e.source)

    def add(sev: str, code: str, msg: str, node=None) -> None:
        n = nodes.get(node) if node else None
        bbox = next((p.bbox for p in n.provenance if p.bbox), None) if n else None
        sheet = n.sheets[0] if n and n.sheets else None
        page = n.provenance[0].page if n and n.provenance else None
        issues.append({k: v for k, v in dict(severity=sev, code=code, message=msg, node=node,
                                             sheet=sheet, page=page, bbox=bbox).items() if v is not None})

    for n in kg.nodes:
        if n.type == "Equipment" and flow_deg[n.id] == 0 and not n.attributes.get("part_of"):
            add("warning", "equipment_not_connected",
                f"equipment {n.label} has no process connections", n.id)
        elif n.type == "Component" and flow_deg[n.id] == 0:
            add("warning", "component_not_connected",
                f"component {n.label} is not on any line (add it to a line 'path')", n.id)
        elif n.type == "Instrument":
            role = n.attributes.get("role")
            loc = n.attributes.get("location", "unknown")
            if role in SENSING_ROLES and loc in ("field", "unknown") and n.id not in measured \
                    and not n.attributes.get("inline"):
                add("warning", "instrument_not_located",
                    f"{n.label} ({role}) senses the process but has no 'measures' location", n.id)
            if any_deg[n.id] == 0:
                add("info", "isolated_instrument", f"{n.label} has no connections at all", n.id)
        if n.type not in ("Plant", "Sheet") and n.confidence < LOW_CONFIDENCE:
            add("info", "low_confidence", f"{n.label} was read with confidence {n.confidence:.2f}", n.id)

    # Tags that differ only in zero padding ('660-TK-06' vs '660-TK-006').
    padded: dict[str, list[str]] = defaultdict(list)
    for n in kg.nodes:
        if n.tag and n.type == "Equipment":  # instrument loop numbers legitimately vary
            padded[re.sub(r"(?<![0-9])0+(?=[0-9])", "", n.tag.split("@")[0].split("#")[0])].append(n.id)
    for ids in padded.values():
        tags = sorted({nodes[i].tag for i in ids})
        if len(tags) > 1:
            add("warning", "near_duplicate_tags",
                f"tags {', '.join(tags)} differ only in zero padding; probably one item "
                "drawn with inconsistent tags (check the sheets)", ids[0])

    issues.extend(_revision_overlap(kg))


    inferred = sum(1 for e in kg.edges if e.type == "FLOWS_TO"
                   and e.attributes.get("flow_direction") == "inferred")
    if inferred:
        issues.append({"severity": "info", "code": "inferred_flow_direction",
                       "message": f"{inferred} flow edges have inferred (not drawn) direction"})

    if work_dir:
        issues.extend(_coverage_issues(kg, Path(work_dir)))
        issues.extend(_hint_issues(kg, Path(work_dir)))
    return issues


def _revision_overlap(kg: KnowledgeGraph) -> list[dict[str, Any]]:
    """Two sheets sharing most of their tags are probably two revisions of one drawing."""
    tags: dict[str, set[str]] = defaultdict(set)
    for n in kg.nodes:
        if n.tag and n.type in ("Equipment", "Instrument", "Component"):
            for s in {p.sheet for p in n.provenance}:
                tags[s].add(n.tag)
    out = []
    sheets = sorted(t for t in tags if len(tags[t]) >= 5)
    for i, a in enumerate(sheets):
        for b in sheets[i + 1:]:
            shared = tags[a] & tags[b]
            frac = len(shared) / min(len(tags[a]), len(tags[b]))
            if frac >= 0.5:
                out.append({"severity": "warning", "code": "possible_duplicate_revision", "sheet": b,
                            "message": f"{a} and {b} share {len(shared)} tags ({frac:.0%} of the smaller sheet); "
                                       "if they are two revisions of the same drawing, keep only the current one "
                                       "in this graph and ask the user what to do with the other"})
    return out


def _coverage_issues(kg: KnowledgeGraph, work: Path) -> list[dict[str, Any]]:
    out = []
    for n in kg.nodes:
        if n.type != "Sheet":
            continue
        page = n.attributes.get("page")
        tiles_file = work / "pages" / f"page_{page:02d}" / "tiles.json"
        if not tiles_file.exists():
            continue
        tiles = json.loads(tiles_file.read_text(encoding="utf-8"))
        expected = {t["name"] for t in tiles["tiles"] if not t.get("blank")}
        reviewed = set(n.attributes.get("tiles_reviewed", []))
        missing = sorted(expected - reviewed)
        if missing:
            out.append({"severity": "warning", "code": "tiles_not_reviewed", "sheet": n.id,
                        "page": page, "message": f"{len(missing)} non-blank tiles not listed in "
                        f"tiles_reviewed: {', '.join(missing)}"})
    return out


def _hint_issues(kg: KnowledgeGraph, work: Path) -> list[dict[str, Any]]:
    """Compare tags found by OCR / the text layer with tags in the graph."""
    out = []
    known = {n.tag for n in kg.nodes if n.tag} | {n.id for n in kg.nodes}
    known_core = {_core(t) for t in known if t}
    # Drawing numbers (title blocks, off-page flags) look like tags but are not items.
    drawings = {_core(normalize_tag(v)) for n in kg.nodes for v in
                (n.attributes.get("drawing_number"), n.attributes.get("other_drawing")) if v}
    # Text already captured in names/attributes (off-page 'other_item', tie-in labels...).
    blob = _core(normalize_tag(" ".join(
        f"{n.name or ''} {n.label} {json.dumps(n.attributes)}" for n in kg.nodes)) or "")
    by_number: dict[str, set[str]] = defaultdict(set)
    for t in known:
        p = parse_isa_tag(t) if t else None
        if p:
            by_number[p.number].add(p.letters)
    for n in kg.nodes:
        if n.type != "Sheet":
            continue
        page = n.attributes.get("page")
        hint_file = work / "hints" / f"page_{page:02d}.json"
        if not hint_file.exists():
            continue
        hints = json.loads(hint_file.read_text(encoding="utf-8"))
        missed = []
        for cand in hints.get("tag_candidates", []):
            t = normalize_tag(cand["text"])
            if not t or t in known:
                continue
            core = _core(t)
            if core in known_core or core in drawings or _MONTHS.match(t):
                continue
            # OCR fragments cut at a tile edge ('0-BX-002', '660-TK-00').
            if any(core in k or k in core for k in known_core if len(k) >= 4) or core in blob:
                continue
            isa = parse_isa_tag(t)
            if not isa and not cand.get("equipment_like"):
                continue
            # Likely OCR misread of a known tag: same number, letters one edit apart.
            if isa and any(_close(isa.letters, l) for l in by_number.get(isa.number, ())):
                continue
            missed.append(cand)
        if missed:
            listed = ", ".join(f"{c['text']}" for c in missed[:40])
            out.append({"severity": "warning", "code": "possible_missed_tags", "sheet": n.id,
                        "page": page, "count": len(missed),
                        "message": f"{len(missed)} tags found by {hints.get('source', 'hints')} are not "
                                   f"in the graph: {listed}",
                        "candidates": missed})
    return out


def _edit1(a: str, b: str) -> bool:
    """True if a and b differ by at most one substitution, insertion or deletion."""
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) <= 1
    if len(a) > len(b):
        a, b = b, a
    return any(a == b[:i] + b[i + 1:] for i in range(len(b)))


def _core(tag: str) -> str:
    """Tag without separators, so 'FIT-0502' and 'FIT0502' match."""
    return tag.replace("-", "")


def tiles_for_bbox(work: Path, page: int, bbox: Optional[list[float]]) -> list[str]:
    if not bbox:
        return []
    f = work / "pages" / f"page_{page:02d}" / "tiles.json"
    if not f.exists():
        return []
    tiles = json.loads(f.read_text(encoding="utf-8"))["tiles"]
    x0, y0, x1, y1 = bbox
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hits = [t["name"] for t in tiles
            if t["norm"][0] <= cx <= t["norm"][2] and t["norm"][1] <= cy <= t["norm"][3]]
    return hits[:2]


def write_report(kg: KnowledgeGraph, issues: list[dict[str, Any]], path: Path,
                 work_dir: Optional[Path] = None) -> None:
    sev_order = {"error": 0, "warning": 1, "info": 2}
    nodes = {n.id: n for n in kg.nodes}
    for i in issues:  # fill page/bbox from the node's provenance when missing
        n = nodes.get(i.get("node", ""))
        if n and n.provenance:
            i.setdefault("page", n.provenance[0].page)
            if not i.get("bbox"):
                bb = next((p.bbox for p in n.provenance if p.bbox), None)
                if bb:
                    i["bbox"] = bb
    issues = sorted(issues, key=lambda i: (sev_order.get(i["severity"], 3), i.get("page") or 0,
                                           i["code"]))
    counts: dict[str, int] = defaultdict(int)
    by_code: dict[tuple[str, str], int] = defaultdict(int)
    for i in issues:
        counts[i["severity"]] += 1
        by_code[(i["severity"], i["code"])] += 1

    lines = [f"# QA report: {kg.plant.name}", "",
             f"Generated {kg.generated_at} by {kg.generator}.", "",
             f"**{counts.get('error', 0)} errors, {counts.get('warning', 0)} warnings, "
             f"{counts.get('info', 0)} info.**", "",
             "Errors must be fixed in the page extraction files before the graph is trusted. "
             "Warnings are things to re-check on the drawing (the *Re-check* column names the tiles). "
             "Info items are for the record.", "",
             "| Severity | Code | Count |", "|---|---|---|"]
    for (sev, code), c in sorted(by_code.items(), key=lambda kv: (sev_order.get(kv[0][0], 3), kv[0][1])):
        lines.append(f"| {sev} | `{code}` | {c} |")
    lines += ["", "## Details", "", "| Severity | Page | Code | Item | Message | Re-check |",
              "|---|---|---|---|---|---|"]
    for i in issues:
        tiles = tiles_for_bbox(work_dir, i["page"], i.get("bbox")) if work_dir and i.get("page") else []
        msg = i["message"].replace("|", "\\|")
        lines.append(f"| {i['severity']} | {i.get('page', '')} | `{i['code']}` | {i.get('node', '')} | "
                     f"{msg} | {', '.join(tiles)} |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _close(a: str, b: str) -> bool:
    """Letter codes close enough to be an OCR misread (same first letter, <=2 slips)."""
    if _edit1(a, b):
        return True
    return len(a) == len(b) and a[:1] == b[:1] and sum(x != y for x, y in zip(a, b)) <= 2
