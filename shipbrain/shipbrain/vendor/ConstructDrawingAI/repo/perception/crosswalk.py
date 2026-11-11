"""DELP (UK service-key) → DEVICE_CATALOG label crosswalk for the real electrical board.

DELP labels 34 UK domestic-electrical *service keys*; our detector predicts the 10
:mod:`perception.labels` classes. To score the (synthetic-trained) detector on DELP — the
first real sim-to-real number — the ground-truth labels must live in our class space. This
maps DELP → ours where there is a **confident** correspondence and **drops the rest** (HVAC,
plumbing, data/AV, meters, thermostats — not electrical-symbol targets in our vocabulary).

The mapping is deliberately conservative and easy to refine; the few approximations (UK
"single/double socket" → our only receptacle class, US "Duplex Receptacle"; UK "Consumer
Unit" → "Panelboard") are noted. This is a **sim-to-real evaluation aid only** — never a
training-label source (that would relabel real data into our taxonomy and defeat the point).
"""

from __future__ import annotations

from cir import DrawingSet, Sheet, View

from .labels import LABEL_TO_INDEX

#: DELP class name → our DEVICE_CATALOG label. Anything absent is dropped for scoring.
DELP_TO_DETECTOR: dict[str, str] = {
    # receptacles (UK sockets → our nearest receptacle class)
    "Double Socket": "Duplex Receptacle",
    "USB Double Socket": "Duplex Receptacle",
    "Single Socket": "Duplex Receptacle",  # approx: single vs duplex
    # switches
    "Light Switch": "Single-Pole Switch",
    # luminaires
    "Low Energy Downlighter": "Recessed Downlight",
    "Low Energy Pendant Light": "Light Fixture",
    "Track Light": "Light Fixture",
    "Twin LED Strip Light": "Light Fixture",
    "External Wall Light": "Wall Light",
    "Internal Wall Light": "Wall Light",
    # distribution
    "Consumer Unit": "Panelboard",
}

# Sanity: every target must be a real detector class (guards typos as the map is refined).
assert set(DELP_TO_DETECTOR.values()) <= set(
    LABEL_TO_INDEX
), "crosswalk targets must be detector classes"


def remap_labels(ds: DrawingSet, mapping: dict[str, str] = DELP_TO_DETECTOR) -> DrawingSet:
    """Return a copy of ``ds`` with entity labels remapped via ``mapping``; drop unmapped.

    Connections are dropped (DELP is detection-only). Geometry/provenance are preserved, so
    the result scores directly against detector predictions in our class space.
    """
    sheets: list[Sheet] = []
    for sheet in ds.sheets:
        views: list[View] = []
        for view in sheet.views:
            kept = [
                e.model_copy(update={"label": mapping[e.label]}, deep=True)
                for e in view.entities
                if e.label in mapping
            ]
            views.append(View(name=view.name, view_type=view.view_type, entities=kept))
        sheets.append(
            Sheet(sheet_number=sheet.sheet_number, discipline=sheet.discipline, views=views)
        )
    return DrawingSet(
        id=ds.id,
        name=ds.name,
        sheets=sheets,
        license_provenance=ds.license_provenance,
        data_lane=ds.data_lane,
    )
