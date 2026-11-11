# L1 perception

L1 turns a drawing into structured CIR entities and connections. Two models:

- **Model 1 — symbol/component detection** ([`perception/detector.py`](../perception/detector.py),
  [`perception/adapter.py`](../perception/adapter.py))
- **Model 2 — connectivity-graph extraction** ([`perception/connectivity.py`](../perception/connectivity.py))

Results are measured on held-out real drawings — see [`BENCHMARKS.md`](BENCHMARKS.md).

## Evaluation: two scoreboards

[`perception/scoreboard.py`](../perception/scoreboard.py) keeps two boards apart:

- **Synthetic board** — the model on held-out synthetic sheets. A pipeline smoke test: a high
  number means the training loop, the L0→L1 handoff, and the CIR wiring all work. It is not
  evidence the model reads real drawings and is never reported as accuracy.
- **Real board** — the model on held-out real annotated plans, compared against cited published
  state of the art. This is the only board reported as accuracy.

```bash
python -m perception eval-detector     --profile local_debug
python -m perception eval-connectivity --profile local_debug
python -m perception eval-detector     --profile local_debug --oracle   # wiring check, no GPU
```

## Model 1 — detection

A YOLO11 detector ([`ultralytics`](https://docs.ultralytics.com/)) trained per discipline.

- **Class set derives from the dataset vocabulary** ([`perception/labels.py`](../perception/labels.py)),
  so a prediction's label is the same string the ground truth uses — the metrics match with no
  translation table to drift.
- **Train the way we infer.** [`perception/dataset.py`](../perception/dataset.py) tiles each sheet
  with the same `ingest.tiling` the adapter uses at inference and writes boxes in
  tile-local-normalized coordinates — the frame the L0→L1 handoff contract
  ([`HANDOFF.md`](HANDOFF.md)) specifies. The train/val split is persisted so the scoreboard scores
  exactly the held-out samples.
- **Wired through the contract.** [`DetectorAdapter`](../perception/adapter.py) tiles → predicts per
  tile → composes back with `ingest.handoff.aggregate` (the one audited place a stitching error
  could become a counting error), emitting CIR entities with IFC class, MasterFormat code,
  confidence, a pixel-exact `source_bbox` (the evidence link), and the `produced_by`/`model_version`
  provenance.
- **Few-shot legend head.** [`perception/fewshot.py`](../perception/fewshot.py) is a
  prototypical-network classifier over a frozen encoder: a project's bespoke glyphs are added from a
  handful of legend exemplars (mean-embedding prototypes, nearest-cosine match), no retraining.
- **Resumable + tracked.** Checkpoints every N epochs (survives cluster preemption via ultralytics
  `resume`), with offline-friendly W&B logging.

Trained on real data, the detector reaches 0.847 mAP@50 on electrical (DELP, above the SkeySpot
0.825 benchmark), 0.820 on architectural (FloorPlanCAD), 0.604 on the official CubiCasa5K split, and
0.926 on P&ID (PID2Graph).

## Model 2 — connectivity-graph extraction

Beyond counting devices, Model 2 recovers the **graph** — which components connect to which — into
CIR `Connection` edges, scored by `graph_node_ap` (nodes) and `graph_edge_ap` (edges, matched after
their endpoint nodes). The edge metric is directedness-aware, so undirected P&ID graphs and directed
electrical graphs are each scored correctly.

Each candidate node pair (k-nearest neighbours + every node↔hub pair) is classified from an
orientation-invariant feature (relative position + distance + both class one-hots) by a 2-layer MLP,
then oriented by convention. End-to-end (detected nodes → edges) on real PID2Graph OPEN100 reaches
0.752 edge AP, matching the Relationformer baseline (0.755); with ground-truth nodes the classifier
reaches 0.852.

**Limitation — node features only.** The edge model sees node geometry and classes, not the drawn
wires. Circuit membership lives in the conductor polylines, so two adjacent receptacles on different
circuits look identical to a geometric model. The next step is a vision edge reader that follows the
rendered conductor lines between candidate nodes.

## Configuration

Profiles in [`perception/conf/`](../perception/conf), loaded with OmegaConf (overridable with
`-o train.epochs=5`):

- `local_debug` — tiny subset, 1 GPU, fast — proves the loop locally.
- `h200_full` — full data, multi-GPU, multi-seed — the SOTA run, submitted to the cluster
  ([`infra/slurm/train.slurm`](../infra/slurm/train.slurm)).
