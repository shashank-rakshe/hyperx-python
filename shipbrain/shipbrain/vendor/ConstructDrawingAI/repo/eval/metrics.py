"""Metric implementations for the matrix evaluation harness.

Every metric takes two aligned sequences of CIR :class:`~cir.DrawingSet` documents —
``preds`` and ``gts`` (prediction *i* corresponds to ground truth *i*) — and returns
a single ``float``. That uniform signature is what lets the harness run any metric
over any task and any adapter identically.

Families (all operate on the CIR):

* **Perception:** ``detection_map`` (per-symbol-family mAP), ``counting_exact_match``,
  ``counting_mape`` (the headline frontier-failure number), ``ocr_exact_match``,
  ``dimension_accuracy``.
* **Topological / structural:** ``external_wall_iou``, ``chamfer_distance``,
  ``loop_closure_validity``, ``panoptic_quality``, ``graph_node_ap``, ``graph_edge_ap``.
* **Reasoning (L4):** ``qa_accuracy`` and an AEC-Bench-style ``rfi_reward``.

:data:`METRICS` maps a name to its function; :data:`HIGHER_IS_BETTER` records the
direction (used by the leaderboard to compute gaps).
"""

from __future__ import annotations

import math
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Sequence

import numpy as np

from cir import BBox, DrawingSet, Entity, GeometryType

MetricFn = Callable[[Sequence[DrawingSet], Sequence[DrawingSet]], float]


# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------
def _label(entity: Entity) -> str:
    """The class label used for matching (label > ifc_class > entity_type)."""
    return entity.label or entity.ifc_class or entity.entity_type.value


def _bbox(entity: Entity) -> BBox | None:
    """Normalized bounding box of an entity, if it has geometry."""
    return entity.geometry.bounds() if entity.geometry is not None else None


def _detections(doc: DrawingSet) -> list[tuple[str, BBox, float]]:
    """(label, bbox, confidence) for every entity with a non-degenerate box.

    Zero-area boxes (e.g. a dimension leader, a zero-height polyline) are excluded:
    they are not detection targets and IoU is undefined for them.
    """
    out: list[tuple[str, BBox, float]] = []
    for entity in doc.iter_entities():
        box = _bbox(entity)
        if box is not None and box.area > 0.0:
            out.append((_label(entity), box, entity.confidence))
    return out


def _class_counts(doc: DrawingSet) -> Counter[str]:
    """Count of entities per class. Uses an explicit ``quantity`` attribute if set
    (e.g. detection-summary entities), else one per entity."""
    counts: Counter[str] = Counter()
    for entity in doc.iter_entities():
        qty = entity.attributes.get("quantity")
        counts[_label(entity)] += int(qty) if isinstance(qty, int) else 1
    return counts


def _norm_text(text: str) -> str:
    return " ".join(text.strip().lower().split())


# ---------------------------------------------------------------------------
# Perception metrics
# ---------------------------------------------------------------------------
def _voc_average_precision(scored: list[tuple[float, bool]], n_gt: int) -> float:
    """VOC all-point average precision from confidence-scored (conf, is_tp) pairs."""
    if n_gt == 0:
        return 0.0
    if not scored:
        return 0.0
    scored = sorted(scored, key=lambda t: t[0], reverse=True)
    tp = np.array([1.0 if is_tp else 0.0 for _, is_tp in scored])
    fp = 1.0 - tp
    tp_cum = np.cumsum(tp)
    fp_cum = np.cumsum(fp)
    recall = tp_cum / n_gt
    precision = tp_cum / np.maximum(tp_cum + fp_cum, 1e-12)
    mrec = np.concatenate(([0.0], recall, [recall[-1]]))
    mpre = np.concatenate(([0.0], precision, [0.0]))
    for i in range(mpre.size - 1, 0, -1):
        mpre[i - 1] = max(mpre[i - 1], mpre[i])
    idx = np.where(mrec[1:] != mrec[:-1])[0]
    return float(np.sum((mrec[idx + 1] - mrec[idx]) * mpre[idx + 1]))


def detection_map(
    preds: Sequence[DrawingSet], gts: Sequence[DrawingSet], *, iou_threshold: float = 0.5
) -> float:
    """Mean Average Precision over symbol families (greedy IoU matching per class)."""
    scored_by_class: dict[str, list[tuple[float, bool]]] = defaultdict(list)
    n_gt_by_class: dict[str, int] = defaultdict(int)

    for pred, gt in zip(preds, gts, strict=False):
        gt_by_class: dict[str, list[BBox]] = defaultdict(list)
        for label, box, _ in _detections(gt):
            gt_by_class[label].append(box)
        pred_by_class: dict[str, list[tuple[float, BBox]]] = defaultdict(list)
        for label, box, conf in _detections(pred):
            pred_by_class[label].append((conf, box))

        for label in set(gt_by_class) | set(pred_by_class):
            gt_boxes = gt_by_class[label]
            n_gt_by_class[label] += len(gt_boxes)
            matched = [False] * len(gt_boxes)
            for conf, box in sorted(pred_by_class[label], key=lambda t: t[0], reverse=True):
                best_iou, best_j = 0.0, -1
                for j, gt_box in enumerate(gt_boxes):
                    if matched[j]:
                        continue
                    iou = box.iou(gt_box)
                    if iou > best_iou:
                        best_iou, best_j = iou, j
                if best_j >= 0 and best_iou >= iou_threshold:
                    matched[best_j] = True
                    scored_by_class[label].append((conf, True))
                else:
                    scored_by_class[label].append((conf, False))

    aps = [
        _voc_average_precision(scored_by_class[c], n_gt_by_class[c])
        for c in n_gt_by_class
        if n_gt_by_class[c] > 0
    ]
    return float(np.mean(aps)) if aps else 0.0


def counting_mape(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Mean Absolute Percentage Error of per-class counts (%). Lower is better.

    The headline metric where frontier VLMs fail (16-25% MAPE vs the 1-3% estimators
    need). Averaged over every (sheet, class) with a non-zero ground-truth count.
    """
    errors: list[float] = []
    for pred, gt in zip(preds, gts, strict=False):
        gt_counts = _class_counts(gt)
        pred_counts = _class_counts(pred)
        for cls, gt_n in gt_counts.items():
            if gt_n > 0:
                errors.append(abs(pred_counts.get(cls, 0) - gt_n) / gt_n)
    return 100.0 * float(np.mean(errors)) if errors else 0.0


def counting_exact_match(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Fraction of (sheet, class) pairs whose predicted count exactly equals GT."""
    hits = total = 0
    for pred, gt in zip(preds, gts, strict=False):
        gt_counts = _class_counts(gt)
        pred_counts = _class_counts(pred)
        for cls, gt_n in gt_counts.items():
            total += 1
            if pred_counts.get(cls, 0) == gt_n:
                hits += 1
    return hits / total if total else 0.0


def ocr_exact_match(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Recall-style exact match of recognized text spans (normalized)."""
    hits = total = 0
    for pred, gt in zip(preds, gts, strict=False):
        pred_texts = Counter(
            _norm_text(span.text) for e in pred.iter_entities() for span in e.text_spans
        )
        gt_texts = [_norm_text(span.text) for e in gt.iter_entities() for span in e.text_spans]
        for text in gt_texts:
            total += 1
            if pred_texts.get(text, 0) > 0:
                pred_texts[text] -= 1
                hits += 1
    return hits / total if total else 0.0


def dimension_accuracy(
    preds: Sequence[DrawingSet], gts: Sequence[DrawingSet], *, tol_mm: float = 1.0
) -> float:
    """Fraction of GT dimensions matched (in mm, within ``tol_mm``) by a prediction."""
    hits = total = 0
    for pred, gt in zip(preds, gts, strict=False):
        pred_values = [
            d.value_mm for e in pred.iter_entities() for d in e.dimensions if d.value_mm is not None
        ]
        for e in gt.iter_entities():
            for dim in e.dimensions:
                if dim.value_mm is None:
                    continue
                total += 1
                for i, pv in enumerate(pred_values):
                    if abs(pv - dim.value_mm) <= tol_mm:
                        pred_values.pop(i)
                        hits += 1
                        break
    return hits / total if total else 0.0


# ---------------------------------------------------------------------------
# Topological / structural metrics
# ---------------------------------------------------------------------------
def panoptic_quality(
    preds: Sequence[DrawingSet], gts: Sequence[DrawingSet], *, iou_threshold: float = 0.5
) -> float:
    """Panoptic Quality: sum(IoU of TP) / (TP + 0.5*FP + 0.5*FN), label-aware."""
    iou_sum = 0.0
    tp = fp = fn = 0
    for pred, gt in zip(preds, gts, strict=False):
        gt_dets = _detections(gt)
        pred_dets = _detections(pred)
        used = [False] * len(gt_dets)
        for plabel, pbox, _ in pred_dets:
            best_iou, best_j = 0.0, -1
            for j, (glabel, gbox, _) in enumerate(gt_dets):
                if used[j] or glabel != plabel:
                    continue
                iou = pbox.iou(gbox)
                if iou > best_iou:
                    best_iou, best_j = iou, j
            if best_j >= 0 and best_iou >= iou_threshold:
                used[best_j] = True
                tp += 1
                iou_sum += best_iou
            else:
                fp += 1
        fn += used.count(False)
    denom = tp + 0.5 * fp + 0.5 * fn
    return iou_sum / denom if denom > 0 else 0.0


def _wall_polygons(doc: DrawingSet) -> list[list[tuple[float, float]]]:
    polys: list[list[tuple[float, float]]] = []
    for entity in doc.iter_entities():
        geom = entity.geometry
        if geom is None or geom.type != GeometryType.POLYGON:
            continue
        label = _label(entity).lower()
        if entity.entity_type.value == "wall" or "wall" in label or "room" in label:
            polys.append([(p.x, p.y) for p in geom.points])
    return polys


def _rasterize(polys: Iterable[list[tuple[float, float]]], size: int = 256) -> np.ndarray:
    """Fill normalized polygons into a boolean mask via scanline."""
    mask = np.zeros((size, size), dtype=bool)
    for poly in polys:
        pts = [(x * size, y * size) for x, y in poly]
        n = len(pts)
        if n < 3:
            continue
        ys = [p[1] for p in pts]
        y0 = max(0, math.floor(min(ys)))
        y1 = min(size - 1, math.ceil(max(ys)))
        for y in range(y0, y1 + 1):
            yc = y + 0.5
            xs: list[float] = []
            for i in range(n):
                (x1, yy1), (x2, yy2) = pts[i], pts[(i + 1) % n]
                if (yy1 <= yc < yy2) or (yy2 <= yc < yy1):
                    xs.append(x1 + (yc - yy1) * (x2 - x1) / (yy2 - yy1))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                xa = max(0, math.ceil(xs[k] - 0.5))
                xb = min(size - 1, math.floor(xs[k + 1] - 0.5))
                if xb >= xa:
                    mask[y, xa : xb + 1] = True
    return mask


def external_wall_iou(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Mask IoU of wall/room polygons (FloorplanVLM's headline metric), per-sheet mean."""
    ious: list[float] = []
    for pred, gt in zip(preds, gts, strict=False):
        gt_polys = _wall_polygons(gt)
        if not gt_polys:
            continue
        gm = _rasterize(gt_polys)
        pm = _rasterize(_wall_polygons(pred))
        union = np.logical_or(gm, pm).sum()
        inter = np.logical_and(gm, pm).sum()
        ious.append(float(inter / union) if union > 0 else 0.0)
    return float(np.mean(ious)) if ious else 0.0


def _vector_points(doc: DrawingSet) -> np.ndarray:
    pts: list[tuple[float, float]] = []
    for entity in doc.iter_entities():
        geom = entity.geometry
        if geom is not None and geom.type in (GeometryType.POLYLINE, GeometryType.POLYGON):
            pts.extend((p.x, p.y) for p in geom.points)
    return np.array(pts, dtype=float) if pts else np.empty((0, 2))


def chamfer_distance(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Symmetric Chamfer distance between predicted and GT vector points. Lower better."""
    dists: list[float] = []
    for pred, gt in zip(preds, gts, strict=False):
        p = _vector_points(pred)
        g = _vector_points(gt)
        if len(p) == 0 or len(g) == 0:
            continue
        d = np.linalg.norm(p[:, None, :] - g[None, :, :], axis=2)
        dists.append(float(d.min(axis=1).mean() + d.min(axis=0).mean()))
    return float(np.mean(dists)) if dists else 0.0


def loop_closure_validity(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Fraction of predicted POLYGON entities that form valid, non-degenerate loops."""
    valid = total = 0
    for pred in preds:
        for entity in pred.iter_entities():
            geom = entity.geometry
            if geom is None or geom.type != GeometryType.POLYGON:
                continue
            total += 1
            pts = geom.points
            if len(pts) < 3:
                continue
            area = 0.5 * abs(
                sum(
                    pts[i].x * pts[(i + 1) % len(pts)].y - pts[(i + 1) % len(pts)].x * pts[i].y
                    for i in range(len(pts))
                )
            )
            if area > 1e-9:
                valid += 1
    return valid / total if total else 0.0


# ---------------------------------------------------------------------------
# Connectivity-graph metrics (P&ID / electrical)
# ---------------------------------------------------------------------------
def _match_nodes(pred: DrawingSet, gt: DrawingSet, iou_threshold: float) -> dict[str, str]:
    """Greedy label-aware IoU match of pred entities to GT entities -> {pred_id: gt_id}."""
    gt_dets = [(e.id, _label(e), _bbox(e)) for e in gt.iter_entities()]
    used = set()
    mapping: dict[str, str] = {}
    pred_entities = sorted(pred.iter_entities(), key=lambda e: e.confidence, reverse=True)
    for entity in pred_entities:
        pbox = _bbox(entity)
        if pbox is None:
            continue
        best_iou, best_gid = iou_threshold, None
        for gid, glabel, gbox in gt_dets:
            if gid in used or gbox is None or glabel != _label(entity):
                continue
            iou = pbox.iou(gbox)
            if iou >= best_iou:
                best_iou, best_gid = iou, gid
        if best_gid is not None:
            used.add(best_gid)
            mapping[entity.id] = best_gid
    return mapping


def graph_node_ap(
    preds: Sequence[DrawingSet], gts: Sequence[DrawingSet], *, iou_threshold: float = 0.5
) -> float:
    """Average precision of connectivity-graph nodes (entities)."""
    return detection_map(preds, gts, iou_threshold=iou_threshold)


def _gt_edge_key(source: str, target: str, directed: bool) -> tuple[str, str, str]:
    """Canonical key for a ground-truth edge: oriented if directed, else endpoint-sorted."""
    if directed:
        return ("d", source, target)
    lo, hi = sorted((source, target))
    return ("u", lo, hi)


def graph_edge_ap(
    preds: Sequence[DrawingSet], gts: Sequence[DrawingSet], *, iou_threshold: float = 0.5
) -> float:
    """Average precision of connectivity edges (after matching their endpoint nodes).

    Honors each ground-truth edge's :attr:`~cir.Connection.directed` flag: a **directed**
    GT edge is a true positive only when a prediction connects the same endpoints in the
    same orientation; an **undirected** GT edge matches either orientation. A prediction is
    credited against whichever the GT declares, so an undirected graph (P&ID, room
    adjacency) is never mis-scored against a directed prediction, and vice versa. With the
    default ``directed=True`` everywhere (e.g. synthetic electrical), behavior is unchanged.
    """
    scored: list[tuple[float, bool]] = []
    n_gt = 0
    for pred, gt in zip(preds, gts, strict=False):
        node_map = _match_nodes(pred, gt, iou_threshold)
        gt_edges = {
            _gt_edge_key(c.source_id, c.target_id, c.directed)
            for view in (s for sh in gt.sheets for s in sh.views)
            for c in view.connections
        }
        n_gt += len(gt_edges)
        matched: set[tuple[str, str, str]] = set()
        for view in (s for sh in pred.sheets for s in sh.views):
            for conn in view.connections:
                conf = conn.confidence if conn.confidence is not None else 1.0
                src = node_map.get(conn.source_id)
                tgt = node_map.get(conn.target_id)
                if src is None or tgt is None:
                    scored.append((conf, False))
                    continue
                directed_key = ("d", src, tgt)
                lo, hi = sorted((src, tgt))
                undirected_key = ("u", lo, hi)
                # Credit the prediction against whichever form the GT declared.
                if directed_key in gt_edges and directed_key not in matched:
                    matched.add(directed_key)
                    scored.append((conf, True))
                elif undirected_key in gt_edges and undirected_key not in matched:
                    matched.add(undirected_key)
                    scored.append((conf, True))
                else:
                    scored.append((conf, False))
    return _voc_average_precision(scored, n_gt)


# ---------------------------------------------------------------------------
# Reasoning (L4) metrics
# ---------------------------------------------------------------------------
def _qa_pairs(doc: DrawingSet) -> dict[str, str]:
    pairs = doc.metadata.get("qa_pairs", [])
    out: dict[str, str] = {}
    if isinstance(pairs, list):
        for qa in pairs:
            if isinstance(qa, dict) and qa.get("q_id") is not None:
                out[str(qa["q_id"])] = _norm_text(str(qa.get("answer", "")))
    return out


def qa_accuracy(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """Fraction of QA pairs whose predicted answer matches GT (normalized), by q_id."""
    hits = total = 0
    for pred, gt in zip(preds, gts, strict=False):
        gt_qa = _qa_pairs(gt)
        pred_qa = _qa_pairs(pred)
        for qid, gt_ans in gt_qa.items():
            total += 1
            if pred_qa.get(qid) == gt_ans:
                hits += 1
    return hits / total if total else 0.0


def rfi_reward(preds: Sequence[DrawingSet], gts: Sequence[DrawingSet]) -> float:
    """AEC-Bench-style reward for drafted RFIs (heuristic rubric, 0..1).

    A real deployment swaps this for an LLM-judge; here it scores the structural
    quality of a drafted RFI stored in ``metadata["rfi"]`` — does it cite a spec
    clause, reference cropped evidence, and state the detected conflict?
    """
    scores: list[float] = []
    for pred in preds:
        rfi = pred.metadata.get("rfi")
        if not isinstance(rfi, dict):
            scores.append(0.0)
            continue
        components = (
            bool(rfi.get("cited_clause")),
            bool(rfi.get("evidence")),
            bool(rfi.get("conflict")),
            bool(rfi.get("question")),
        )
        scores.append(sum(components) / len(components))
    return float(np.mean(scores)) if scores else 0.0


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
METRICS: dict[str, MetricFn] = {
    "detection_map": detection_map,
    "counting_mape": counting_mape,
    "counting_exact_match": counting_exact_match,
    "ocr_exact_match": ocr_exact_match,
    "dimension_accuracy": dimension_accuracy,
    "panoptic_quality": panoptic_quality,
    "external_wall_iou": external_wall_iou,
    "chamfer_distance": chamfer_distance,
    "loop_closure_validity": loop_closure_validity,
    "graph_node_ap": graph_node_ap,
    "graph_edge_ap": graph_edge_ap,
    "qa_accuracy": qa_accuracy,
    "rfi_reward": rfi_reward,
}

#: Whether a higher value is better (the rest — MAPE, Chamfer — are lower-is-better).
HIGHER_IS_BETTER: dict[str, bool] = dict.fromkeys(METRICS, True)
HIGHER_IS_BETTER["counting_mape"] = False
HIGHER_IS_BETTER["chamfer_distance"] = False


def get_metric(name: str) -> MetricFn:
    """Look up a metric function by name."""
    try:
        return METRICS[name]
    except KeyError as exc:
        raise KeyError(f"Unknown metric {name!r}. Available: {sorted(METRICS)}.") from exc
