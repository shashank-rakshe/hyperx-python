"""GraphML → CIR converter + PID2Graph driver (per ADR-0012 / docs/GRAPH_MAPPING.md).

PID2Graph is the richest public connectivity ground truth (real OPEN100 P&IDs + synthetic),
and P&ID connectivity is the adjacent-domain supervision for our wedge differentiator until
a real *electrical* connectivity set exists. Each ``N.graphml`` pairs with ``N.png``; nodes
carry a label + a pixel bbox (in key-set ``d1..d4`` *or* ``d5..d8``), edges carry a style
label, and the graph is **undirected** — so this maps straight onto the CIR graph model:

* symbol nodes (``valve``/``instrumentation``/``general``) → :class:`~cir.Entity` ``SYMBOL``;
* topological nodes (``connector``/``crossing``/``arrow``) → ``GRAPH_NODE`` +
  ``attributes["node_role"]``; ``background`` is dropped;
* edges → :class:`~cir.Connection` with ``directed=False`` (ADR-0012) and
  ``connection_type`` = the edge's style label.

Pixel bboxes are normalized by the paired image's size to the CIR ``[0,1]`` frame. Each CIR
doc records its slice (``complete``/``patched`` × ``dataset-pid``/``open100``/``synthetic``)
and a ``real`` flag in ``metadata``, so the OPEN100-real slice can serve as the P&ID
connectivity eval (SOTA 75.5 edge mAP) while the rest is training fuel. License is
CC-BY-SA 4.0 → research lane.
"""

from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cir
from cir import (
    Connection,
    DataLane,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    SourceFile,
    View,
    ViewType,
)

logger = logging.getLogger(__name__)

_NS = {"g": "http://graphml.graphdrawing.org/xmlns"}
_IMAGE_EXTS = (".png", ".jpg", ".jpeg")
_SKIP_LABELS = {"background"}
#: Non-symbol topological nodes → GRAPH_NODE + node_role (the metric doesn't branch on role).
_TOPOLOGICAL = {"connector", "crossing", "arrow"}


@dataclass(frozen=True)
class _Subset:
    """One PID2Graph slice: relative dir, slice tag, and whether it is real data."""

    rel_dir: str
    slice_name: str
    real: bool


#: The slices worth converting for A7 (Complete = full plans; Patched/OPEN100 = real patches).
#: The large synthetic Patched slices are left for a later, capped bulk pass.
PID2GRAPH_SUBSETS: list[_Subset] = [
    _Subset("Complete/PID2Graph OPEN100", "complete/open100", True),
    _Subset("Complete/Dataset PID", "complete/dataset-pid", False),
    _Subset("Complete/PID2Graph Synthetic", "complete/synthetic", False),
    _Subset("Patched/PID2Graph OPEN100", "patched/open100", True),
]


def _paired_image(graphml_path: Path) -> Path | None:
    for ext in _IMAGE_EXTS:
        candidate = graphml_path.with_suffix(ext)
        if candidate.is_file():
            return candidate
    return None


def _node_bbox(node: ET.Element) -> tuple[float, float, float, float] | None:
    """Pixel bbox from the node's key-set. Two encodings exist with DIFFERENT orders
    (confirmed from the graphml ``<key attr.name=...>`` definitions):
    ``d1..d4`` (double) = ``[xmin, xmax, ymin, ymax]``; ``d5..d8`` (long) = ``[xmin, ymin,
    xmax, ymax]``. Mixing them up mangles the box (double-keyed nodes blow up to giant boxes)."""
    data = {d.get("key"): d.text for d in node.findall("g:data", _NS)}

    def f(key: str) -> float | None:
        raw = data.get(key)
        return float(raw) if raw is not None else None

    if data.get("d1") is not None:  # double set: xmin, xmax, ymin, ymax
        xmin, xmax, ymin, ymax = f("d1"), f("d2"), f("d3"), f("d4")
    else:  # long set: xmin, ymin, xmax, ymax
        xmin, ymin, xmax, ymax = f("d5"), f("d6"), f("d7"), f("d8")
    if None in (xmin, ymin, xmax, ymax):
        return None
    return xmin, ymin, xmax, ymax  # type: ignore[return-value]


def graphml_to_cir(
    graphml_path: Path,
    image_path: Path,
    *,
    slug: str,
    slice_name: str,
    real: bool,
    license_provenance: LicenseProvenance = LicenseProvenance.CC_BY_SA,
    data_lane: DataLane = DataLane.RESEARCH,
) -> DrawingSet:
    """Convert one GraphML (+ its paired image, for scale) into a CIR DrawingSet."""
    from PIL import Image

    width, height = Image.open(image_path).size
    graph = ET.parse(graphml_path).getroot().find("g:graph", _NS)
    if graph is None:
        raise ValueError(f"no <graph> in {graphml_path}")
    prov: dict[str, Any] = {"license_provenance": license_provenance, "data_lane": data_lane}

    entities: list[Entity] = []
    kept_ids: set[str] = set()
    for node in graph.findall("g:node", _NS):
        nid = node.get("id")
        label_el = node.find("g:data[@key='d0']", _NS)
        label = label_el.text if label_el is not None and label_el.text else "node"
        if nid is None or label in _SKIP_LABELS:
            continue
        bbox = _node_bbox(node)
        if bbox is None:
            continue
        xmin, ymin, xmax, ymax = bbox
        geom = Geometry.box(xmin / width, ymin / height, xmax / width, ymax / height)
        is_topological = label in _TOPOLOGICAL
        entities.append(
            Entity(
                id=nid,
                entity_type=EntityType.GRAPH_NODE if is_topological else EntityType.SYMBOL,
                label=label,
                geometry=geom,
                attributes={"node_role": label} if is_topological else {},
                confidence=1.0,
                **prov,
            )
        )
        kept_ids.add(nid)

    connections: list[Connection] = []
    for edge in graph.findall("g:edge", _NS):
        src, tgt = edge.get("source"), edge.get("target")
        if src not in kept_ids or tgt not in kept_ids:
            continue  # endpoint was a dropped (e.g. background) node
        style_el = edge.find("g:data[@key='d9']", _NS)
        connections.append(
            Connection(
                source_id=src,
                target_id=tgt,
                connection_type=style_el.text if style_el is not None else None,
                directed=False,  # PID2Graph graphs are edgedefault="undirected" (ADR-0012)
                confidence=1.0,
            )
        )

    view = View(view_type=ViewType.DIAGRAM, entities=entities, connections=connections)
    sheet = Sheet(
        sheet_number=(graphml_path.stem[:32] or "D-1"),
        discipline=Discipline.PROCESS,
        views=[view],
    )
    return DrawingSet(
        name=f"{slug}/{slice_name}/{graphml_path.stem}",
        source=SourceFile(
            filename=image_path.name, file_type="image", ingest_tool="pid2graph-graphml"
        ),
        sheets=[sheet],
        metadata={"slug": slug, "slice": slice_name, "real": real, "src_image": str(image_path)},
        **prov,
    )


def convert_pid2graph(
    raw_root: Path,
    out_dir: Path,
    *,
    slug: str = "pid2graph",
    cap_per_subset: int | None = None,
) -> dict[str, int]:
    """Convert the PID2Graph slices in :data:`PID2GRAPH_SUBSETS` → CIR docs in ``out_dir``."""
    base = raw_root / "PID2Graph"
    out_dir.mkdir(parents=True, exist_ok=True)
    counts: dict[str, int] = {}
    for subset in PID2GRAPH_SUBSETS:
        subdir = base / subset.rel_dir
        # rglob: Complete/* keeps graphml at the top level, Patched/* nests them per plan.
        graphmls = sorted(subdir.rglob("*.graphml"))
        if cap_per_subset is not None:
            graphmls = graphmls[:cap_per_subset]
        tag = subset.slice_name.replace("/", "__")
        n = 0
        for graphml in graphmls:
            image = _paired_image(graphml)
            if image is None:
                continue
            ds = graphml_to_cir(
                graphml, image, slug=slug, slice_name=subset.slice_name, real=subset.real
            )
            # Patched stems repeat across per-plan subdirs → key the filename by the path.
            uid = str(graphml.relative_to(subdir).with_suffix("")).replace("/", "_")
            cir.save(ds, str(out_dir / f"{slug}__{tag}__{uid}.cir"))
            n += 1
        counts[subset.slice_name] = n
        logger.info("pid2graph %s: %d docs", subset.slice_name, n)
    return counts


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - thin CLI
    import argparse

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(prog="python -m datasets.preparers.graphml_cir")
    parser.add_argument("--raw", default="data/pid/pid2graph/raw")
    parser.add_argument("--out", default="datasets/processed/pid2graph/cir")
    parser.add_argument("--cap", type=int, default=None, help="max docs per slice (default: all)")
    ns = parser.parse_args(argv)
    counts = convert_pid2graph(Path(ns.raw), Path(ns.out), cap_per_subset=ns.cap)
    print("converted:", counts, "total:", sum(counts.values()))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
