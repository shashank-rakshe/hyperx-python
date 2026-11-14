"""Pydantic models for page extractions and the knowledge graph.

Two schemas live here:

* ``PageExtraction`` is what Claude writes for every P&ID sheet after reading
  it visually (``extract/page_NN.json``). It mirrors how an engineer reads a
  drawing: items on the sheet, the pipe runs between them, and the signal
  lines between instruments.
* ``KnowledgeGraph`` is the canonical output (``graph.json``) produced by
  ``build_kg.py``. It is a typed property graph in node-link form.

JSON Schemas for both are generated into ``references/schema/`` by
``python scripts/build_kg.py --write-schemas``.
"""

from __future__ import annotations

from typing import Any, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from . import EXTRACTION_SCHEMA_VERSION, GRAPH_SCHEMA_VERSION

BBox = list[float]  # normalized [x0, y0, x1, y1] on the upright page, 0..1


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


def _check_bbox(v: Optional[BBox]) -> Optional[BBox]:
    if v is None:
        return v
    if len(v) != 4:
        raise ValueError("bbox must be [x0, y0, x1, y1]")
    if any(c < -0.01 or c > 1.01 for c in v):
        raise ValueError("bbox must be normalized to 0..1 of the page")
    x0, y0, x1, y1 = v
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


# ==========================================================================
# Page extraction (written by Claude, one file per sheet)
# ==========================================================================


class ProcessRef(_Strict):
    """A point in the process: an item, or a position on a pipe run.

    Use ``item`` for equipment, components and in-line instruments. Use
    ``line`` (plus optional ``after``) for a tap or tee on a pipe run, where
    ``after`` is the path item immediately upstream of the tap.
    """

    item: Optional[str] = None
    line: Optional[str] = None
    after: Optional[str] = None

    @model_validator(mode="after")
    def _one_target(self) -> "ProcessRef":
        if bool(self.item) == bool(self.line):
            raise ValueError("ProcessRef needs exactly one of 'item' or 'line'")
        if self.after and not self.line:
            raise ValueError("'after' is only valid together with 'line'")
        return self


Endpoint = Union[str, ProcessRef]


class _Item(_Strict):
    id: str = Field(description="Unique within the page. Use the tag when the item has one.")
    tag: Optional[str] = Field(None, description="Tag exactly as printed, e.g. 'FIT-0502'.")
    name: Optional[str] = Field(None, description="Descriptive text printed with the item.")
    status: Optional[Literal["new", "existing", "future", "demolish", "unknown"]] = None
    confidence: float = Field(0.9, ge=0.0, le=1.0)
    bbox: Optional[BBox] = None
    notes: Optional[str] = None
    attributes: dict[str, Any] = Field(default_factory=dict)

    @field_validator("bbox")
    @classmethod
    def _bbox_ok(cls, v: Optional[BBox]) -> Optional[BBox]:
        return _check_bbox(v)


class Equipment(_Item):
    kind: str = Field(description="Vocabulary in references/ontology.md, e.g. 'tank', 'centrifugal_pump'.")
    part_of: Optional[str] = Field(None, description="Id of the equipment this is mounted on (agitator on a tank, drive on a pump).")


class Component(_Item):
    kind: str = Field(description="Vocabulary in references/ontology.md, e.g. 'gate_valve', 'control_valve'.")
    actuator: Optional[
        Literal["manual", "pneumatic", "electric", "hydraulic", "solenoid", "self", "none"]
    ] = None
    fail_position: Optional[Literal["FO", "FC", "FL", "FI"]] = None
    normal_position: Optional[Literal["open", "closed"]] = None
    size: Optional[str] = None
    loop: Optional[str] = Field(None, description="Override the ISA loop this item belongs to.")


class Instrument(_Item):
    tag: Optional[str] = Field(None, description="Printed tag. Leave empty for untagged gauges and give 'function'.")
    function: Optional[str] = Field(None, description="ISA letters for an untagged instrument, e.g. 'PI' for a bare pressure gauge.")
    location: str = Field("unknown", description="field | local_panel | main_panel | behind_panel | dcs | plc | scada | sis | computer | unknown")
    measures: Optional[ProcessRef] = Field(None, description="Where the instrument senses the process.")
    loop: Optional[str] = Field(None, description="Override the ISA loop this instrument belongs to.")

    @model_validator(mode="after")
    def _tag_or_function(self) -> "Instrument":
        if not self.tag and not self.function:
            raise ValueError("an instrument needs a 'tag', or a 'function' (e.g. 'PI') if untagged")
        return self


class Line(_Strict):
    id: str = Field(description="Unique within the page, e.g. 'L1'.")
    line_number: Optional[str] = None
    size: Optional[str] = None
    service: Optional[str] = Field(None, description="Fluid/service code or description.")
    from_: Endpoint = Field(alias="from")
    to: Endpoint
    path: list[str] = Field(default_factory=list, description="Ids of in-line items in flow order.")
    flow_direction: Literal["shown", "inferred"] = "shown"
    status: Optional[Literal["new", "existing", "future", "demolish", "unknown"]] = None
    confidence: float = Field(0.85, ge=0.0, le=1.0)
    notes: Optional[str] = None


class Signal(_Strict):
    from_: str = Field(alias="from")
    to: str
    type: str = Field("unknown", description="electrical | pneumatic | software | hydraulic | capillary | wireless | mechanical | unknown")
    purpose: Literal["control", "measurement", "trip", "alarm", "status", "unknown"] = "unknown"
    confidence: float = Field(0.85, ge=0.0, le=1.0)
    notes: Optional[str] = None


class OffPageConnector(_Item):
    direction: Literal["in", "out"]
    other_drawing: Optional[str] = Field(None, description="Drawing number the flow continues on/comes from.")
    other_item: Optional[str] = Field(None, description="Item named at the far end, e.g. '660-TK-004'.")
    line_number: Optional[str] = None


class Boundary(_Item):
    direction: Literal["source", "sink", "area"] = Field(
        description="source/sink for streams entering or leaving; 'area' for a room or zone that "
                    "area instruments (gas detectors, room temperature) measure")


class SheetInfo(_Strict):
    drawing_number: Optional[str] = None
    title: Optional[str] = None
    revision: Optional[str] = None
    drawing_type: Literal["pid", "pfd", "other"] = "pid"
    issue_status: Optional[str] = Field(None, description="As printed: 'as-built', 'issued for construction', 'draft', 'superseded'...")
    rotation: Optional[int] = None
    legend_notes: list[str] = Field(default_factory=list)


class PageExtraction(_Strict):
    schema_version: str = EXTRACTION_SCHEMA_VERSION
    page: int = Field(ge=1, description="1-based page number in the input PDF.")
    sheet: SheetInfo = Field(default_factory=SheetInfo)
    equipment: list[Equipment] = Field(default_factory=list)
    components: list[Component] = Field(default_factory=list)
    instruments: list[Instrument] = Field(default_factory=list)
    lines: list[Line] = Field(default_factory=list)
    signals: list[Signal] = Field(default_factory=list)
    off_page_connectors: list[OffPageConnector] = Field(default_factory=list)
    boundaries: list[Boundary] = Field(default_factory=list)
    tiles_reviewed: list[str] = Field(default_factory=list)
    unreadable: list[str] = Field(default_factory=list, description="Things seen but not legible.")

    @model_validator(mode="after")
    def _unique_ids(self) -> "PageExtraction":
        seen: dict[str, str] = {}
        groups = {
            "equipment": self.equipment,
            "components": self.components,
            "instruments": self.instruments,
            "off_page_connectors": self.off_page_connectors,
            "boundaries": self.boundaries,
            "lines": self.lines,
        }
        for group, items in groups.items():
            for it in items:
                if it.id in seen:
                    raise ValueError(f"duplicate id '{it.id}' in {group} and {seen[it.id]}")
                seen[it.id] = group
        return self


# ==========================================================================
# Knowledge graph (written by build_kg.py)
# ==========================================================================


class Provenance(_Strict):
    sheet: str
    page: int
    bbox: Optional[BBox] = None
    source: str = "vision"
    local_id: Optional[str] = None


class Node(_Strict):
    id: str
    type: str
    label: str
    tag: Optional[str] = None
    kind: Optional[str] = None
    name: Optional[str] = None
    status: Optional[str] = None
    dexpi_class: Optional[str] = None
    sheets: list[str] = Field(default_factory=list)
    confidence: float = 1.0
    attributes: dict[str, Any] = Field(default_factory=dict)
    provenance: list[Provenance] = Field(default_factory=list)


class Edge(_Strict):
    id: str
    source: str
    target: str
    type: str
    confidence: float = 1.0
    derived: bool = False
    attributes: dict[str, Any] = Field(default_factory=dict)
    sheet: Optional[str] = None


class PlantInfo(_Strict):
    id: str
    name: str
    source_file: Optional[str] = None
    sheets: list[str] = Field(default_factory=list)


class KnowledgeGraph(_Strict):
    schema_version: str = GRAPH_SCHEMA_VERSION
    generator: str
    generated_at: str
    plant: PlantInfo
    nodes: list[Node]
    edges: list[Edge]
    stats: dict[str, Any] = Field(default_factory=dict)
    issues: list[dict[str, Any]] = Field(default_factory=list)
