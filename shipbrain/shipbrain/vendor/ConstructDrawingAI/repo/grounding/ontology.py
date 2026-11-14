"""L2 grounding — map CIR entity labels to IFC classes + spec codes (MasterFormat / UniFormat).

L1 says "there is a *valve* here, 0.9 confident." L2 makes it estimating-ready: an IFC class
plus the standard spec codes an estimator/BIM tool consumes. This is a deterministic reference
table over the label vocabularies we actually produce (electrical DEVICE_CATALOG + DELP,
FloorPlanCAD architectural, PID2Graph process). Codes are the standard MasterFormat sections
(Div 26 electrical, 08 openings, 22 plumbing, 40/43 process, …) and UniFormat elements —
level-appropriate, not invented. Unknown labels are left ungrounded (honest), never guessed.

Full OmniClass/Uniclass + a learned classifier are later work; a correct label → correct code
is deterministic, which is why the investment is in L1 getting the label right.
"""

from __future__ import annotations

from dataclasses import dataclass

from cir import DrawingSet, OntologyCodes


@dataclass(frozen=True)
class OntologyEntry:
    """The grounded codes for one label."""

    ifc: str
    masterformat: str
    uniformat: str


# Grouped families → one entry, then expanded to per-label below.
_RECEPTACLE = OntologyEntry("IfcOutlet", "26 27 26", "D5010")
_SWITCH = OntologyEntry("IfcSwitchingDevice", "26 27 26", "D5010")
_LUMINAIRE = OntologyEntry("IfcLightFixture", "26 51 00", "D5020")
_PANEL = OntologyEntry("IfcElectricDistributionBoard", "26 24 16", "D5010")
_JBOX = OntologyEntry("IfcJunctionBox", "26 05 33", "D5010")
_DOOR = OntologyEntry("IfcDoor", "08 10 00", "C1020")
_WINDOW = OntologyEntry("IfcWindow", "08 50 00", "B2020")
_WALL = OntologyEntry("IfcWall", "09 21 00", "B2010")
_STAIR = OntologyEntry("IfcStair", "05 51 00", "B1080")
_RAILING = OntologyEntry("IfcRailing", "05 52 00", "C2010")
_PLUMB = OntologyEntry("IfcSanitaryTerminal", "22 42 00", "D2010")
_FURN = OntologyEntry("IfcFurniture", "12 50 00", "E2010")
_CASEWORK = OntologyEntry("IfcFurniture", "12 35 00", "E2010")
_APPLIANCE = OntologyEntry("IfcElectricAppliance", "11 31 00", "E1090")
_ELEVATOR = OntologyEntry("IfcTransportElement", "14 20 00", "D1010")
_ESCALATOR = OntologyEntry("IfcTransportElement", "14 30 00", "D1010")
_VALVE = OntologyEntry("IfcValve", "40 05 23", "D3010")
_PUMP = OntologyEntry("IfcPump", "43 21 00", "D3010")
_TANK = OntologyEntry("IfcTank", "43 41 00", "D3010")
_INSTRUMENT = OntologyEntry("IfcSensor", "40 90 00", "D3060")
_PROCESS = OntologyEntry("IfcFlowController", "40 05 00", "D3010")
_HVAC_FAN = OntologyEntry("IfcFan", "23 34 00", "D3040")
_RADIATOR = OntologyEntry("IfcSpaceHeater", "23 82 00", "D3050")
_DATA = OntologyEntry("IfcCommunicationsAppliance", "27 15 00", "D5030")
_SMOKE = OntologyEntry("IfcAlarm", "28 46 00", "D5030")
_THERMOSTAT = OntologyEntry("IfcController", "23 09 00", "D3060")


def _expand(pairs: list[tuple[list[str], OntologyEntry]]) -> dict[str, OntologyEntry]:
    out: dict[str, OntologyEntry] = {}
    for labels, entry in pairs:
        for lab in labels:
            out[lab] = entry
    return out


#: label → codes. Case-insensitive lookup via :func:`_norm`.
ONTOLOGY: dict[str, OntologyEntry] = _expand(
    [
        # --- electrical (DEVICE_CATALOG + DELP) ---
        (
            [
                "Duplex Receptacle",
                "Quad Receptacle",
                "GFCI Receptacle",
                "Double Socket",
                "Single Socket",
                "USB Double Socket",
                "Shaver Socket",
                "Outside Socket",
            ],
            _RECEPTACLE,
        ),
        (["Single-Pole Switch", "Three-Way Switch", "Light Switch", "Grid Switch"], _SWITCH),
        (
            [
                "Light Fixture",
                "Recessed Downlight",
                "Wall Light",
                "Low Energy Downlighter",
                "Low Energy Pendant Light",
                "Track Light",
                "Twin LED Strip Light",
                "External Wall Light",
                "Internal Wall Light",
            ],
            _LUMINAIRE,
        ),
        (["Panelboard", "Consumer Unit"], _PANEL),
        (["Junction Box"], _JBOX),
        # --- architectural (FloorPlanCAD) ---
        (["door", "single_door", "double_door", "sliding_door"], _DOOR),
        (["window", "bay_window", "blind_window"], _WINDOW),
        (["wall"], _WALL),
        (["stair"], _STAIR),
        (["railing"], _RAILING),
        (["sink", "toilet", "squat_toilet", "urinal", "bath", "bath_tub", "shower"], _PLUMB),
        (["chair", "table", "sofa", "bed", "bench", "bedside_cupboard"], _FURN),
        (["half_height_cabinet", "high_cabinet", "tv_cabinet", "wardrobe", "closet"], _CASEWORK),
        (["refrigerator", "washing_machine", "gas_stove"], _APPLIANCE),
        (["elevator"], _ELEVATOR),
        (["escalator"], _ESCALATOR),
        # --- P&ID (PID2Graph) ---
        (["valve"], _VALVE),
        (["pump"], _PUMP),
        (["tank"], _TANK),
        (["instrumentation"], _INSTRUMENT),
        (["general", "inlet/outlet"], _PROCESS),
        # --- MEP / comms (DELP) ---
        (["Radiator"], _RADIATOR),
        (
            [
                "Ceiling Mounted Continuous Extract Fan With Boost Mode Activated By Light Switch",
                "Ceiling Mounted Continuous Extract Fan With Local Boost Switch",
                "Recirculating Extractor Fan",
            ],
            _HVAC_FAN,
        ),
        (
            [
                "Cat 6 Data Socket",
                "Telephone Socket",
                "Co-Ax TV Socket",
                "TV - Satellite Multisocket",
                "BT Entry Point",
            ],
            _DATA,
        ),
        (["Mains Wired Smoke Detector"], _SMOKE),
        (["Programmable Room Thermostat"], _THERMOSTAT),
    ]
)


def _norm(label: str) -> str:
    return label.strip().lower()


_BY_NORM: dict[str, OntologyEntry] = {_norm(k): v for k, v in ONTOLOGY.items()}


def lookup(label: str | None) -> OntologyEntry | None:
    """The ontology entry for ``label`` (case-insensitive), or ``None`` if unmapped."""
    if label is None:
        return None
    return _BY_NORM.get(_norm(label))


def ground_drawing_set(ds: DrawingSet) -> tuple[DrawingSet, int, int]:
    """Fill ``ifc_class`` + ``ontology`` on every mappable entity, in place.

    Returns ``(ds, grounded, total)`` — how many labelled entities were grounded, for QA.
    """
    grounded = total = 0
    for sheet in ds.sheets:
        for view in sheet.views:
            for e in view.entities:
                if e.label is None:
                    continue
                total += 1
                entry = lookup(e.label)
                if entry is None:
                    continue
                e.ifc_class = entry.ifc
                e.ontology = OntologyCodes(
                    masterformat=entry.masterformat, uniformat=entry.uniformat
                )
                grounded += 1
    return ds, grounded, total
