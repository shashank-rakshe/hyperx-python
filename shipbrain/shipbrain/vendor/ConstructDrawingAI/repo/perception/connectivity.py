"""Model 2 — electrical connectivity-graph extraction (the wedge differentiator).

Counting devices is table stakes; the wedge is the **graph** — which devices share a
circuit, which home-runs go to which panel, which switch controls which luminaire. That
connectivity is what powers takeoff (wire/conduit lengths), RFI origination ("panel lists
14 circuits, plan shows 12 home-runs"), and code checks.

Approach: a **directed edge classifier** over node pairs. Given the device/panel nodes
(from Model 1 at inference, from ground truth at train), each candidate ordered pair
``{a, b}`` gets an orientation-invariant feature vector — relative position + distance +
both class one-hots (the pair ordered by position) — and a small MLP predicts the
*undirected* edge **type** ``{none, conductor, home_run, switch_leg}``. Predicting type
(not direction) is the easier, well-posed problem; the edge is then **oriented by trade
convention** (``home_run`` -> the panel, ``switch_leg`` from the switch, ``conductor``
left-to-right), which reproduces the ground-truth direction exactly. Candidates are each
node's k nearest neighbours (local wiring) **plus** every node<->panel pair (home-runs can
span the sheet), so the true edges are always reachable.

Scored by ``graph_node_ap`` (the nodes, == detection mAP) and ``graph_edge_ap`` (edges,
matched after their endpoint nodes) — see :mod:`eval.metrics`. The published P&ID
connectivity SOTA (Relationformer on PID2Graph, arXiv 2411.13929) is **75.5 edge mAP on
real OPEN100** (88.9 in-distribution synthetic); the bar for our synthetic-only commercial
lane is **SynthPID's 63.8** on real OPEN100 with no real training (arXiv 2604.16513) — all
in ``eval.fixtures``. As with Model 1, the synthetic number is a **smoke test**; real-drawing
connectivity is UNVALIDATED until real annotated plans exist. ``torch`` is imported lazily.
"""

from __future__ import annotations

import json
import logging
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

import cir
from cir import Connection, DataLane, DrawingSet
from eval.adapters import ModelAdapter
from eval.tasks import EvalSample
from synthetic.model import DEVICE_CATALOG, PANEL_CLASS, DeviceKind

from .config import resolve
from .dataset import assign_split, discover_samples, plan_sheet
from .labels import LABEL_TO_INDEX, NUM_CLASSES

logger = logging.getLogger(__name__)

#: Edge classes the model predicts (undirected type). Index 0 is "no edge".
EDGE_TYPES: tuple[str, ...] = ("none", "conductor", "home_run", "switch_leg")
EDGE_TYPE_TO_IDX: dict[str, int] = {t: i for i, t in enumerate(EDGE_TYPES)}
N_EDGE_CLASSES = len(EDGE_TYPES)
#: Pair feature = [dx, dy, dist] + lower-node class one-hot + upper-node class one-hot,
#: with the pair ordered by (x, y) so the feature is orientation-invariant.
FEATURE_DIM = 3 + 2 * NUM_CLASSES
_PANEL_LABEL = PANEL_CLASS.label
_SWITCH_LABELS = {
    DEVICE_CATALOG[DeviceKind.SINGLE_POLE_SWITCH].label,
    DEVICE_CATALOG[DeviceKind.THREE_WAY_SWITCH].label,
}


@dataclass
class GraphNode:
    """A connectivity node: a device/panel symbol with its center + CIR entity id."""

    label: str
    x: float
    y: float
    entity_id: str

    @property
    def class_index(self) -> int:
        return LABEL_TO_INDEX[self.label]


def nodes_from_entities(entities: Any) -> list[GraphNode]:
    """The detectable symbols (with geometry) among ``entities``, as graph nodes."""
    nodes: list[GraphNode] = []
    for entity in entities:
        if entity.label not in LABEL_TO_INDEX or entity.geometry is None:
            continue
        bounds = entity.geometry.bounds()
        if bounds is None:
            continue
        center = bounds.center
        nodes.append(GraphNode(entity.label, center.x, center.y, entity.id))
    return nodes


def candidate_pairs(nodes: list[GraphNode], *, k_neighbors: int = 8) -> list[tuple[int, int]]:
    """Unordered candidate edges ``(i < j)``: each node's k nearest neighbours + every
    node<->panel pair. Home-runs can be long, so panel pairs are always included
    regardless of distance. Orientation is decided later, by :func:`_orient`.
    """
    n = len(nodes)
    if n < 2:
        return []
    pts = np.array([[nd.x, nd.y] for nd in nodes])
    dist = np.linalg.norm(pts[:, None, :] - pts[None, :, :], axis=2)
    panels = [i for i, nd in enumerate(nodes) if nd.label == _PANEL_LABEL]
    pairs: set[tuple[int, int]] = set()
    for i in range(n):
        for j in np.argsort(dist[i])[1 : k_neighbors + 1]:
            pairs.add((min(i, int(j)), max(i, int(j))))
    for p in panels:
        for i in range(n):
            if i != p:
                pairs.add((min(i, p), max(i, p)))
    return sorted(pairs)


def pair_features(n1: GraphNode, n2: GraphNode) -> np.ndarray:
    """Orientation-invariant feature vector for the unordered pair ``{n1, n2}``.

    The two nodes are ordered by ``(x, y)`` so the same pair yields the same features
    regardless of argument order (the model predicts type, not direction).
    """
    a, b = sorted((n1, n2), key=lambda nd: (nd.x, nd.y))
    feat = np.zeros(FEATURE_DIM, dtype=np.float32)
    feat[0] = b.x - a.x
    feat[1] = b.y - a.y
    feat[2] = math.hypot(b.x - a.x, b.y - a.y)
    feat[3 + a.class_index] = 1.0
    feat[3 + NUM_CLASSES + b.class_index] = 1.0
    return feat


def gt_undirected_edges(view: Any) -> dict[frozenset[str], str]:
    """Map ``{source_id, target_id}`` -> connection_type for a view's GT edges (undirected)."""
    return {
        frozenset((c.source_id, c.target_id)): c.connection_type
        for c in view.connections
        if c.connection_type in EDGE_TYPE_TO_IDX and c.connection_type != "none"
    }


def build_examples(
    sample_dirs: list[Path], *, k_neighbors: int = 8
) -> tuple[np.ndarray, np.ndarray]:
    """Build (features, labels) for the edge classifier from synthetic ground truth."""
    feats: list[np.ndarray] = []
    labels: list[int] = []
    for sample_dir in sample_dirs:
        ds = cir.load(DrawingSet, str(sample_dir / "ground_truth.cir"))
        view = plan_sheet(ds).views[0]
        nodes = nodes_from_entities(view.entities)
        edges = gt_undirected_edges(view)
        for i, j in candidate_pairs(nodes, k_neighbors=k_neighbors):
            key = frozenset((nodes[i].entity_id, nodes[j].entity_id))
            feats.append(pair_features(nodes[i], nodes[j]))
            labels.append(EDGE_TYPE_TO_IDX[edges.get(key, "none")])
    if not feats:
        return np.empty((0, FEATURE_DIM), dtype=np.float32), np.empty((0,), dtype=np.int64)
    return np.stack(feats), np.array(labels, dtype=np.int64)


# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------
class ConnectivityModel:
    """An MLP edge classifier (torch built lazily so importing this module is cheap)."""

    def __init__(self, *, hidden: tuple[int, ...] = (64, 64), device: str | None = None) -> None:
        self.hidden = tuple(hidden)
        self.device = device
        self.net: Any = None

    def _build(self) -> Any:
        import torch.nn as nn

        layers: list[Any] = []
        in_dim = FEATURE_DIM
        for width in self.hidden:
            layers += [nn.Linear(in_dim, width), nn.ReLU()]
            in_dim = width
        layers.append(nn.Linear(in_dim, N_EDGE_CLASSES))
        return nn.Sequential(*layers)

    def fit(
        self,
        x: np.ndarray,
        y: np.ndarray,
        *,
        epochs: int = 60,
        lr: float = 1e-3,
        batch_size: int = 4096,
        val: tuple[np.ndarray, np.ndarray] | None = None,
        tracker: Any = None,
    ) -> dict[str, float]:
        import torch
        from torch import nn

        device = self.device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.device = device
        self.net = self._build().to(device)

        # Inverse-frequency class weights: "none" dominates, so weight the rare edges up.
        counts = np.bincount(y, minlength=N_EDGE_CLASSES).astype(np.float64)
        weights = (counts.sum() / np.maximum(counts, 1.0)).astype(np.float32)
        criterion = nn.CrossEntropyLoss(weight=torch.tensor(weights, device=device))
        optimizer = torch.optim.Adam(self.net.parameters(), lr=lr)

        xt = torch.tensor(x, dtype=torch.float32, device=device)
        yt = torch.tensor(y, dtype=torch.long, device=device)
        n = len(xt)
        last: dict[str, float] = {}
        for epoch in range(epochs):
            self.net.train()
            perm = torch.randperm(n, device=device)
            total = 0.0
            for start in range(0, n, batch_size):
                idx = perm[start : start + batch_size]
                optimizer.zero_grad()
                loss = criterion(self.net(xt[idx]), yt[idx])
                loss.backward()
                optimizer.step()
                total += loss.item() * len(idx)
            last = {"loss": total / max(n, 1)}
            if val is not None:
                last.update(self._edge_metrics(val[0], val[1], prefix="val_"))
            if tracker is not None:
                tracker.log(last, step=epoch)
        return last

    def _edge_metrics(self, x: np.ndarray, y: np.ndarray, *, prefix: str = "") -> dict[str, float]:
        """Macro edge-F1 + any-edge F1 on (x, y) — the intrinsic connectivity quality."""
        if len(x) == 0:
            return {}
        pred = self.predict_proba(x).argmax(1)
        macro_f1 = float(np.mean([_f1(y, pred, c) for c in range(1, N_EDGE_CLASSES)]))
        any_f1 = _f1((y > 0).astype(int), (pred > 0).astype(int), 1)
        return {f"{prefix}edge_macro_f1": macro_f1, f"{prefix}any_edge_f1": any_f1}

    def predict_proba(self, x: np.ndarray) -> np.ndarray:
        import torch

        self.net.eval()
        with torch.no_grad():
            logits = self.net(torch.tensor(x, dtype=torch.float32, device=self.device))
            return torch.softmax(logits, dim=1).cpu().numpy()

    def predict_edges(
        self, nodes: list[GraphNode], *, k_neighbors: int = 8, threshold: float = 0.5
    ) -> list[tuple[int, int, int, float]]:
        """Classify + orient edges -> list of (src_idx, tgt_idx, type_idx, score).

        Each unordered candidate pair is classified into an edge type, then oriented by
        trade convention (:func:`_orient`) to match the ground-truth edge direction.
        """
        candidates = candidate_pairs(nodes, k_neighbors=k_neighbors)
        if not candidates:
            return []
        feats = np.stack([pair_features(nodes[i], nodes[j]) for i, j in candidates])
        probs = self.predict_proba(feats)
        best_type = probs.argmax(1)
        best_score = probs.max(1)
        edges: list[tuple[int, int, int, float]] = []
        for k, (i, j) in enumerate(candidates):
            type_idx = int(best_type[k])
            score = float(best_score[k])
            if type_idx == 0 or score < threshold:
                continue
            src, tgt = _orient(i, j, nodes, EDGE_TYPES[type_idx])
            edges.append((src, tgt, type_idx, score))
        return edges

    def save(self, path: str | Path) -> None:
        import torch

        Path(path).parent.mkdir(parents=True, exist_ok=True)
        torch.save({"hidden": list(self.hidden), "state_dict": self.net.state_dict()}, str(path))

    @classmethod
    def load(cls, path: str | Path, *, device: str | None = None) -> ConnectivityModel:
        import torch

        blob = torch.load(str(path), map_location=device or "cpu")
        model = cls(hidden=tuple(blob["hidden"]), device=device)
        model.net = model._build()
        model.net.load_state_dict(blob["state_dict"])
        dev = device or ("cuda" if torch.cuda.is_available() else "cpu")
        model.device = dev
        model.net.to(dev)
        return model


def _f1(y_true: np.ndarray, y_pred: np.ndarray, cls: int) -> float:
    tp = int(np.sum((y_pred == cls) & (y_true == cls)))
    fp = int(np.sum((y_pred == cls) & (y_true != cls)))
    fn = int(np.sum((y_pred != cls) & (y_true == cls)))
    denom = 2 * tp + fp + fn
    return (2 * tp / denom) if denom > 0 else 0.0


def _orient(i: int, j: int, nodes: list[GraphNode], edge_type: str) -> tuple[int, int]:
    """Orient an undirected edge to match the GT direction, by trade convention."""
    a, b = nodes[i], nodes[j]
    if edge_type == "home_run":  # device -> panel
        return (i, j) if b.label == _PANEL_LABEL else (j, i)
    if edge_type == "switch_leg":  # switch -> the luminaire it controls
        return (i, j) if a.label in _SWITCH_LABELS else (j, i)
    return (i, j) if (a.x, a.y) <= (b.x, b.y) else (j, i)  # conductor: left-to-right


# ---------------------------------------------------------------------------
# Training entry point
# ---------------------------------------------------------------------------
@dataclass
class ConnectivityTrainResult:
    """Outcome of training the connectivity model."""

    weights: Path
    metrics: dict[str, float] = field(default_factory=dict)


def _split_dirs(cfg: Any) -> tuple[list[Path], list[Path]]:
    """Train/val sample dirs — reuse the detector's split.json if present, else split here."""
    synthetic_root = resolve(cfg.data.synthetic_root)
    split_json = Path(cfg.data.split_json) if cfg.data.get("split_json") else None
    if split_json and split_json.is_file():
        split = json.loads(split_json.read_text())
        train = [synthetic_root / n for n in split["train"]]
        val = [synthetic_root / n for n in split["val"]]
    else:
        all_dirs = discover_samples(synthetic_root)
        if cfg.data.limit_samples is not None:
            all_dirs = all_dirs[: int(cfg.data.limit_samples)]
        assigned = assign_split(
            [d.name for d in all_dirs],
            val_fraction=float(cfg.data.val_fraction),
            seed=int(cfg.seed),
        )
        train = [d for d in all_dirs if assigned[d.name] == "train"]
        val = [d for d in all_dirs if assigned[d.name] == "val"]
    return train, val


def train_connectivity(cfg: Any) -> ConnectivityTrainResult:
    """Train the connectivity edge classifier for ``cfg`` (a connectivity config)."""
    from omegaconf import OmegaConf

    from eval.tracking import ExperimentTracker

    train_dirs, val_dirs = _split_dirs(cfg)
    x_train, y_train = build_examples(train_dirs, k_neighbors=int(cfg.data.k_neighbors))
    val = build_examples(val_dirs, k_neighbors=int(cfg.data.k_neighbors)) if val_dirs else None
    logger.info(
        "connectivity training pairs: %d (train), %d (val)", len(x_train), len(val[0]) if val else 0
    )

    mode = str(cfg.wandb.mode) if bool(cfg.wandb.enabled) else "disabled"
    tracker = ExperimentTracker(
        str(cfg.wandb.project),
        data_lane=DataLane(str(cfg.data_lane)),
        name=f"connectivity-{cfg.profile}",
        config=dict(OmegaConf.to_container(cfg, resolve=True)),  # type: ignore[arg-type]
        tags=["connectivity", str(cfg.profile)],
        mode=mode,
    ).start()

    model = ConnectivityModel(hidden=tuple(cfg.model.hidden))
    metrics = model.fit(
        x_train,
        y_train,
        epochs=int(cfg.train.epochs),
        lr=float(cfg.train.lr),
        batch_size=int(cfg.train.batch_size),
        val=val,
        tracker=tracker,
    )
    weights = resolve(cfg.train.project) / cfg.train.name / "weights" / "connectivity.pt"
    model.save(weights)
    if weights.is_file():
        tracker.log_artifact(weights, name=f"connectivity-{cfg.profile}", artifact_type="model")
    tracker.finish()
    logger.info("connectivity trained -> %s  (%s)", weights, metrics)
    return ConnectivityTrainResult(weights=weights, metrics=metrics)


def latest_connectivity_weights(project: str | Path, name: str) -> Path:
    """The connectivity weights for run ``name`` under ``project`` (raises if absent)."""
    weights = resolve(str(project)) / name / "weights" / "connectivity.pt"
    if not weights.is_file():
        raise FileNotFoundError(f"no connectivity weights at {weights} — train it first.")
    return weights


# ---------------------------------------------------------------------------
# The adapter: full pipeline (detector nodes -> predicted edges -> CIR graph)
# ---------------------------------------------------------------------------
class ConnectivityAdapter(ModelAdapter):
    """Detect nodes (Model 1) then predict their connectivity edges into the CIR.

    Respects the harness contract — it reads only the image (via the detector adapter),
    never ``sample.ground_truth`` — so ``graph_edge_ap`` here is the **end-to-end** number
    (bounded by node recall). The intrinsic edge quality (given correct nodes) is the
    ``val_*`` metric reported by :func:`train_connectivity`.
    """

    is_stochastic = False

    def __init__(
        self,
        detector_adapter: ModelAdapter,
        connectivity: ConnectivityModel,
        *,
        k_neighbors: int = 8,
        edge_conf: float = 0.5,
        name: str = "cdai-connectivity",
        model_version: str = "0.1.0",
    ) -> None:
        self.detector_adapter = detector_adapter
        self.connectivity = connectivity
        self.k_neighbors = k_neighbors
        self.edge_conf = edge_conf
        self.name = name
        self.model_version = model_version

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        ds = self.detector_adapter.predict(sample, seed=seed)  # nodes from Model 1
        view = ds.sheets[0].views[0]
        nodes = nodes_from_entities(view.entities)
        edges = self.connectivity.predict_edges(
            nodes, k_neighbors=self.k_neighbors, threshold=self.edge_conf
        )
        view.connections = [
            Connection(
                source_id=nodes[i].entity_id,
                target_id=nodes[j].entity_id,
                connection_type=EDGE_TYPES[type_idx],
                confidence=score,
                attributes={"produced_by": self.name, "model_version": self.model_version},
            )
            for (i, j, type_idx, score) in edges
        ]
        return ds

    @classmethod
    def from_config(
        cls, cfg: Any, *, detector_adapter: ModelAdapter, weights: str | Path | None = None
    ) -> ConnectivityAdapter:
        """Build from a connectivity config + an already-built detector adapter."""
        weights_path = (
            Path(weights)
            if weights is not None
            else latest_connectivity_weights(cfg.train.project, cfg.train.name)
        )
        model = ConnectivityModel.load(weights_path)
        return cls(
            detector_adapter,
            model,
            k_neighbors=int(cfg.infer.k_neighbors),
            edge_conf=float(cfg.infer.edge_conf),
            name=f"cdai-connectivity-{cfg.profile}",
            model_version=f"connectivity-{cfg.profile}",
        )
