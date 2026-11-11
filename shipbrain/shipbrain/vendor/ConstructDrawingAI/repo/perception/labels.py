"""The electrical symbol detector's class set — derived from the synthetic engine.

Model 1 (the electrical symbol detector, Build Playbook 2.1) predicts exactly the
device/equipment classes the synthetic engine can render, so that a prediction's class
label and the CIR ground-truth label are **the same string** and the evaluation metrics
(:mod:`eval.metrics`, which match on :func:`eval.metrics._label`) compare them with no
translation table to drift. The single source of truth for those classes is the
synthetic engine's :data:`~synthetic.model.DEVICE_CATALOG` (plus the panelboard), so
adding a device kind to the engine automatically extends the detector's vocabulary here
— there is no second list to keep in sync.

The class *order* is pinned explicitly (:data:`DETECTOR_KINDS`): class indices are
persisted in YOLO label files and baked into trained weights, so reordering the catalog
must never silently renumber a trained model's classes. Append new kinds at the END.
"""

from __future__ import annotations

from dataclasses import dataclass

from cir import EntityType
from synthetic.model import DEVICE_CATALOG, PANEL_CLASS, DeviceKind

# Explicit, frozen class order. Indices are persisted in YOLO labels + trained weights,
# so this order is a compatibility contract: append new kinds at the END, never reorder.
DETECTOR_KINDS: tuple[DeviceKind, ...] = (
    DeviceKind.DUPLEX_RECEPTACLE,
    DeviceKind.QUAD_RECEPTACLE,
    DeviceKind.GFCI_RECEPTACLE,
    DeviceKind.LIGHT_FIXTURE,
    DeviceKind.RECESSED_DOWNLIGHT,
    DeviceKind.WALL_LIGHT,
    DeviceKind.SINGLE_POLE_SWITCH,
    DeviceKind.THREE_WAY_SWITCH,
    DeviceKind.JUNCTION_BOX,
)


@dataclass(frozen=True)
class DetectorClass:
    """One detector class: its index plus the CIR semantics to stamp on a prediction."""

    index: int
    label: str  # the CIR Entity.label (matches synthetic GT exactly)
    ifc_class: str  # native IFC class, copied onto predicted entities
    masterformat: str  # MasterFormat code (grounding-ready)
    entity_type: EntityType  # SYMBOL for devices, EQUIPMENT for the panel


def _build_classes() -> list[DetectorClass]:
    """Build the ordered class list from the synthetic catalog + the panelboard."""
    classes: list[DetectorClass] = []
    for kind in DETECTOR_KINDS:
        dc = DEVICE_CATALOG[kind]
        classes.append(
            DetectorClass(
                index=len(classes),
                label=dc.label,
                ifc_class=dc.ifc_class,
                masterformat=dc.masterformat,
                entity_type=dc.entity_type,
            )
        )
    # The panelboard is a detection target too (it sits on the plan, in the elec room).
    classes.append(
        DetectorClass(
            index=len(classes),
            label=PANEL_CLASS.label,
            ifc_class=PANEL_CLASS.ifc_class,
            masterformat=PANEL_CLASS.masterformat,
            entity_type=PANEL_CLASS.entity_type,
        )
    )
    return classes


#: The detector's classes, in index order. The one table the rest of L1 reads.
DETECTOR_CLASSES: list[DetectorClass] = _build_classes()

#: Ordered class names (the YOLO ``names`` list); index i -> CIR label.
CLASS_NAMES: list[str] = [c.label for c in DETECTOR_CLASSES]
#: CIR label -> class index.
LABEL_TO_INDEX: dict[str, int] = {c.label: c.index for c in DETECTOR_CLASSES}
#: class index -> :class:`DetectorClass`.
INDEX_TO_CLASS: dict[int, DetectorClass] = {c.index: c for c in DETECTOR_CLASSES}
#: CIR label -> :class:`DetectorClass` (used by the adapter to enrich predicted entities).
BY_LABEL: dict[str, DetectorClass] = {c.label: c for c in DETECTOR_CLASSES}

#: Number of detector classes (the panelboard + every renderable device kind).
NUM_CLASSES: int = len(DETECTOR_CLASSES)


def is_detectable(label: str) -> bool:
    """Whether ``label`` is one of the detector's classes (a device/panel symbol).

    Used to filter a full synthetic ground-truth :class:`~cir.DrawingSet` (which also
    carries walls, room tags, dimensions, and schedule rows) down to just the symbols
    the detector is responsible for, so the detection scoreboard compares like with like.
    """
    return label in LABEL_TO_INDEX
