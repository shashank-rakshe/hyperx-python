#!/usr/bin/env python3
"""Build the knowledge graph for one plant from its page extractions.

Reads <work>/extract/page_*.json (validated against the extraction schema),
merges items across sheets by tag, expands pipe runs into segments, links
off-page connectors, infers control loops and equipment-level flow, runs QA,
and writes to <work>/kg/:

    graph.json     canonical knowledge graph (node-link JSON)
    graph.duckdb   the same graph as DuckDB tables, views and traversal macros
    summary.md     compact LLM-ready summary of flow, instruments and loops
    qa_report.md   issues to fix or re-check, with the tiles to look at

Usage:
    python build_kg.py work/my-plant
    python build_kg.py --write-schemas      # regenerate references/schema/*.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg.build import BuildError, build_graph, load_extractions  # noqa: E402
from pidkg.models import KnowledgeGraph, PageExtraction  # noqa: E402
from pidkg.qa import run_qa, write_report  # noqa: E402
from pidkg.store import write_duckdb  # noqa: E402
from pidkg.summary import write_summary  # noqa: E402

SCHEMA_DIR = Path(__file__).resolve().parent.parent / "references" / "schema"


def write_schemas() -> None:
    SCHEMA_DIR.mkdir(parents=True, exist_ok=True)
    for name, model in (("extraction.schema.json", PageExtraction), ("graph.schema.json", KnowledgeGraph)):
        schema = model.model_json_schema(by_alias=True)
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        (SCHEMA_DIR / name).write_text(json.dumps(schema, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {SCHEMA_DIR / name}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work", type=Path, nargs="?")
    ap.add_argument("--out", type=Path, help="output directory (default: <work>/kg)")
    ap.add_argument("--plant-name")
    ap.add_argument("--plant-id")
    ap.add_argument("--pages", help="only build from these pages, e.g. '1-2' (default: all extracted)")
    ap.add_argument("--write-schemas", action="store_true")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    if args.write_schemas:
        write_schemas()
        return 0
    if not args.work:
        ap.error("work directory is required")

    manifest = {}
    mpath = args.work / "manifest.json"
    if mpath.exists():
        manifest = json.loads(mpath.read_text(encoding="utf-8"))
    plant_name = args.plant_name or manifest.get("plant_name") or args.work.name
    plant_id = args.plant_id or manifest.get("plant_id") or args.work.name
    source = Path(manifest["source_pdf"]).name if manifest.get("source_pdf") else None

    try:
        pages = load_extractions(args.work / "extract")
    except BuildError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if args.pages:
        from render_pages import parse_pages

        keep = set(parse_pages(args.pages, max(p.page for p in pages)))
        pages = [p for p in pages if p.page in keep]
        if not pages:
            print(f"error: no extracted pages in {args.pages}", file=sys.stderr)
            return 1

    kg = build_graph(pages, plant_id, plant_name, source)
    kg.issues.extend(run_qa(kg, args.work))
    sev: dict[str, int] = {}
    for i in kg.issues:
        sev[i["severity"]] = sev.get(i["severity"], 0) + 1
    kg.stats["issues_by_severity"] = sev

    out = args.out or (args.work / "kg")
    out.mkdir(parents=True, exist_ok=True)
    (out / "graph.json").write_text(kg.model_dump_json(indent=1, exclude_none=True), encoding="utf-8")
    write_duckdb(kg, out / "graph.duckdb")
    (out / "summary.md").write_text(write_summary(kg), encoding="utf-8")
    write_report(kg, kg.issues, out / "qa_report.md", args.work)

    s = kg.stats
    print(f"{plant_name}: {s['nodes']} nodes, {s['edges']} edges -> {out}")
    print("  nodes: " + ", ".join(f"{k} {v}" for k, v in s["nodes_by_type"].items()))
    print("  edges: " + ", ".join(f"{k} {v}" for k, v in s["edges_by_type"].items()))
    if s.get("loops_by_type"):
        print("  loops: " + ", ".join(f"{k} {v}" for k, v in s["loops_by_type"].items()))
    print(f"  issues: {sev.get('error', 0)} errors, {sev.get('warning', 0)} warnings, "
          f"{sev.get('info', 0)} info (see qa_report.md)")
    return 1 if sev.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
