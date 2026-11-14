# Benchmarks

Results for the perception stack (detection + connectivity) and the takeoff engine, measured on
**held-out real test splits** and compared to published state of the art. Evaluation is performed
only on real annotated drawings; synthetic data is used for pipeline validation, not accuracy
reporting.

## Detection (Model 1)

| Discipline | Dataset | Split | Classes | Model | mAP@50 | mAP@50-95 | Reference |
|---|---|---|---:|---|---:|---:|---|
| Electrical | DELP / SkeySpot | official (375/16/12) | 34 | YOLO11m, 300ep, 3 seeds | **0.847 ± 0.024** | 0.485 ± 0.015 | SkeySpot 0.825 |
| Architectural | FloorPlanCAD | 80/10/10, 3 seeds | 35 | YOLO11s, 100ep | **0.820 ± 0.005** | 0.742 | — |
| Architectural | CubiCasa5K | official (4199/399/399), 3 seeds | 9 | YOLO11s, 100ep | **0.604 ± 0.001** | 0.512 | — |
| P&ID | PID2Graph OPEN100 | plan-level (8/2/2), 3 seeds | 6 | YOLO11s, 100ep, imgsz 1024 | **0.926 ± 0.008** | 0.729 | — |

The electrical model exceeds the SkeySpot benchmark (0.847 vs 0.825 mAP@50). Performance is broad
across classes in every discipline; the weakest classes are thin or rare shapes (e.g. FloorPlanCAD
`railing`). Per-seed values and additional configs are reproducible via the scripts in `infra/arc/`.

## Connectivity (Model 2)

| Task | Dataset | Setting | Metric | Value | Reference |
|---|---|---|---|---:|---|
| Edge extraction (end-to-end) | PID2Graph OPEN100 | detected nodes → edge classifier | edge AP | **0.752** | Relationformer 0.755 |
| Edge classifier (given GT nodes) | PID2Graph OPEN100 | GT nodes, k-NN candidates | edge AP | 0.852 | — |

The end-to-end result detects all node types (symbols + connector/crossing/arrow junctions) with a
9-class detector (0.806 mAP@50), matches them to ground truth, and classifies edges — matching the
Relationformer joint-detection baseline (0.755). Method: orientation-invariant pairwise features
(Δposition, distance, node-class one-hots) → 2-layer MLP.

## Quantity takeoff (L3)

Detections and connectivity are aggregated into a takeoff: component counts, room areas, and
wall/run lengths, mapped to MasterFormat / UniFormat codes, each line carrying a confidence score
and evidence link. On a real floor plan (ResPlan), room areas reconstruct the plan's stated net
area to within measurement tolerance.

## Methods

- **Detector:** Ultralytics YOLO11 (n/s/m), imgsz 640 (1024 for P&ID); the electrical SOTA config
  adds mosaic/mixup/copy-paste augmentation, 300 epochs.
- **Hardware:** RTX 4090 for iteration; VT ARC A100 (Apptainer container) for the SOTA runs.
- **Evaluation:** held-out test split; COCO mAP for detection; edge AP (area under the
  precision–recall curve) for connectivity; 3 seeds for confidence intervals.

## Generalization

Cross-dataset transfer between architectural datasets is limited by differing drawing and
annotation conventions; combined-dataset training is planned to improve cross-domain robustness.

## References

- SkeySpot / DELP — arXiv 2508.10449 (YOLOv8, real UK electrical, 0.825 mAP)
- FloorPlanCAD — panoptic symbol spotting (PQ 0.889)
- Relationformer — arXiv 2411.13929 (0.755 edge mAP on real OPEN100)
- SynthPID — arXiv 2604.16513 (0.638 on real OPEN100)
