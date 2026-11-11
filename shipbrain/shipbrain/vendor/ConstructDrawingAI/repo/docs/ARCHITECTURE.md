# Architecture

The layered design and how the pieces fit. For the schema deep-dive see [`CIR.md`](CIR.md);
for the perception models see [`PERCEPTION.md`](PERCEPTION.md).

## Design

A **perception-first** system: fine-tuned specialist models extract structured,
ontology-grounded, topologically-valid data from a drawing, and a reasoning layer turns those
facts into workflows (Q&A, RFI drafting). Extraction and reasoning are kept separate — different
quality ceilings, different tooling — with specialists underneath and orchestration on top, rather
than a single vision-language model over raw pixels.

Everything reads and writes **one schema**, the Canonical Intermediate Representation (CIR). That
decouples perception from reasoning (swap a detector without touching the agent), makes evaluation
tractable (score the CIR, not screenshots), and gives every drawing type a common target so breadth
doesn't fragment into N pipelines.

## Layers

```
 L4  agent/        Reasoning        — Q&A and RFI drafting over the CIR, with citations.
 L3  engines/      Product engines  — quantity takeoff (counts, areas, lengths).
 L2  grounding/    Semantic mapping — IFC / MasterFormat / UniFormat / OmniClass codes.
 L1  perception/   Perception       — symbol/component detection + connectivity extraction.
 L0  ingest/       Ingestion        — PDF / DWG-DXF / IFC / image → CIR; tiling; sheet index;
                                      title blocks; vector-first with raster fallback.
 ──  cir/          Canonical Intermediate Representation — the substrate every layer reads and
                   writes. DrawingSet → Sheet → View → Entity (+ Connection).
```

### Runtime pipeline

```
ingest & normalize → tile → specialist heads (detection, connectivity) →
aggregate into the CIR with per-entity confidence → grounding → engines →
agent synthesizes answers with source citations
```

Detection, connectivity, grounding, takeoff, and the backend run locally; heavy training runs on a
GPU node (RTX 4090 for iteration, an A100/H200 cluster for the SOTA configs).

## Supporting components

| Component | Directory | Notes |
|---|---|---|
| Evaluation harness | `eval/` | Per-type native metrics, multi-seed CIs, SQLite leaderboard, cited baselines. |
| Dataset registry | `datasets/` | Source-of-truth registry + license-aware preparers. Holds the contract, not the data. |
| Synthetic engine | `synthetic/` | IFC / parametric → rendered drawings + degradation, for pipeline validation. |
| Backend API | `backend/` | FastAPI over the CIR + a demo console. |
| Infra | `infra/` | Container and cluster (Slurm / Apptainer) templates. |

## Data discipline

Code travels by **git**; datasets and model weights travel by **DVC** and are never committed.
Each CIR entity records its dataset provenance and license so downstream consumers can honor
upstream terms.

## Evaluation discipline

Perception is scored on two separate boards: a synthetic board (held-out synthetic data) used only
as a pipeline smoke test, and a **real board** (held-out real drawings) compared against published
state of the art. Only the real board is reported as accuracy — see [`BENCHMARKS.md`](BENCHMARKS.md).
