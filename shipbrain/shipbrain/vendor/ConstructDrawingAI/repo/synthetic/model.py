"""The canonical electrical model — **the single source of truth** for a sample.

Everything the synthetic engine produces for one drawing is derived from one
:class:`ElectricalModel`: the rendered pixels *and* the CIR ground truth *and* the
validator's expectation. Because all three come from this one object, the ground
truth can never disagree with what was drawn — which is the governing invariant of
the whole engine (a renderer that emits subtly-wrong labels silently poisons every
model trained downstream, so we make disagreement structurally impossible).

The model is populated two ways, both yielding *this same type*:

* parametrically, from a seeded generation request (:mod:`synthetic.scene`) — this is
  the v0 workhorse, because it lets us state "N receptacles on M circuits" exactly and
  because open IFC is electrically-poor (see ``docs/SYNTHETIC.md``);
* from a real IFC model (:mod:`synthetic.ifc_source`), via IfcOpenShell.

Coordinates are in the CIR **normalized sheet frame** — fractions of the sheet
extent, origin top-left, x→right, y→down, nominally ``[0, 1]`` — so a device's stored
position *is* the center of its CIR bounding box, with no hidden transform between the
model and the ground truth. ``DEVICE_CATALOG`` is the one table mapping a device kind
to its CIR class + ontology + glyph size; both rendering and ground-truth emission
read it, so a device can never be drawn as one thing and labelled another.
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

from cir import EntityType


class DeviceKind(str, Enum):
    """The electrical devices v0 can place. (Electrical only — no mech/plumbing.)"""

    DUPLEX_RECEPTACLE = "duplex_receptacle"
    QUAD_RECEPTACLE = "quad_receptacle"
    GFCI_RECEPTACLE = "gfci_receptacle"
    LIGHT_FIXTURE = "light_fixture"
    RECESSED_DOWNLIGHT = "recessed_downlight"
    WALL_LIGHT = "wall_light"
    SINGLE_POLE_SWITCH = "single_pole_switch"
    THREE_WAY_SWITCH = "three_way_switch"
    JUNCTION_BOX = "junction_box"


class RoomType(str, Enum):
    """Space type — drives realistic device kinds, densities, and circuiting.

    Real electrical layout depends heavily on what a space *is*: an office is wired
    differently from a restroom (GFCI, code-required) or a corridor (egress lighting,
    3-way switching). Modeling space type is how the scene generator moves toward
    real-world conventions instead of a uniform device sprinkle — and it is where the
    sim-to-real gap is closed (see ``docs/SYNTHETIC.md``).
    """

    OFFICE = "office"
    OPEN_OFFICE = "open_office"
    CONFERENCE = "conference"
    CORRIDOR = "corridor"
    RESTROOM = "restroom"
    BREAK_ROOM = "break_room"
    STORAGE = "storage"
    ELECTRICAL = "electrical"
    MECHANICAL = "mechanical"
    LOBBY = "lobby"


class DeviceClass(BaseModel):
    """The fixed CIR semantics of a device kind — the auditable class mapping.

    Read by BOTH the renderer (to draw the glyph) and the ground-truth emitter (to
    label the entity), so the drawn symbol and its CIR class are always the same fact.
    """

    model_config = ConfigDict(extra="forbid", frozen=True)

    label: str  # human/CIR label, e.g. "Duplex Receptacle"
    ifc_class: str  # native IFC class, e.g. "IfcOutlet"
    entity_type: EntityType  # coarse CIR primitive kind (SYMBOL for devices)
    masterformat: str  # MasterFormat spec/estimating code
    nominal_size: float  # glyph bbox side in normalized sheet units (pre-style-scale)
    load_va: int  # connected load in volt-amps (NEC-style), for circuit sizing + schedule


#: The single source of device semantics. Adding a device kind means adding one row
#: here (and a glyph variant in :mod:`synthetic.symbols`) — nothing else.
DEVICE_CATALOG: dict[DeviceKind, DeviceClass] = {
    DeviceKind.DUPLEX_RECEPTACLE: DeviceClass(
        label="Duplex Receptacle",
        ifc_class="IfcOutlet",
        entity_type=EntityType.SYMBOL,
        masterformat="26 27 26",
        nominal_size=0.022,
        load_va=180,  # NEC 220.14(I): 180 VA per receptacle yoke
    ),
    DeviceKind.QUAD_RECEPTACLE: DeviceClass(
        label="Quad Receptacle",
        ifc_class="IfcOutlet",
        entity_type=EntityType.SYMBOL,
        masterformat="26 27 26",
        nominal_size=0.026,
        load_va=360,  # two yokes
    ),
    DeviceKind.GFCI_RECEPTACLE: DeviceClass(
        label="GFCI Receptacle",
        ifc_class="IfcOutlet",
        entity_type=EntityType.SYMBOL,
        masterformat="26 27 26",
        nominal_size=0.024,
        load_va=180,
    ),
    DeviceKind.LIGHT_FIXTURE: DeviceClass(
        label="Light Fixture",
        ifc_class="IfcLightFixture",
        entity_type=EntityType.SYMBOL,
        masterformat="26 51 13",
        nominal_size=0.030,
        load_va=100,  # 2x4 troffer-class
    ),
    DeviceKind.RECESSED_DOWNLIGHT: DeviceClass(
        label="Recessed Downlight",
        ifc_class="IfcLightFixture",
        entity_type=EntityType.SYMBOL,
        masterformat="26 51 13",
        nominal_size=0.024,
        load_va=60,
    ),
    DeviceKind.WALL_LIGHT: DeviceClass(
        label="Wall Light",
        ifc_class="IfcLightFixture",
        entity_type=EntityType.SYMBOL,
        masterformat="26 51 13",
        nominal_size=0.022,
        load_va=75,
    ),
    DeviceKind.SINGLE_POLE_SWITCH: DeviceClass(
        label="Single-Pole Switch",
        ifc_class="IfcSwitchingDevice",
        entity_type=EntityType.SYMBOL,
        masterformat="26 27 26",
        nominal_size=0.020,
        load_va=0,  # control device, no connected load
    ),
    DeviceKind.THREE_WAY_SWITCH: DeviceClass(
        label="Three-Way Switch",
        ifc_class="IfcSwitchingDevice",
        entity_type=EntityType.SYMBOL,
        masterformat="26 27 26",
        nominal_size=0.020,
        load_va=0,
    ),
    DeviceKind.JUNCTION_BOX: DeviceClass(
        label="Junction Box",
        ifc_class="IfcJunctionBox",
        entity_type=EntityType.SYMBOL,
        masterformat="26 05 33",
        nominal_size=0.018,
        load_va=0,
    ),
}

#: CIR semantics of the panelboard (a device-distribution board, not a point device).
PANEL_CLASS = DeviceClass(
    label="Panelboard",
    ifc_class="IfcElectricDistributionBoard",
    entity_type=EntityType.EQUIPMENT,
    masterformat="26 24 16",
    nominal_size=0.05,
    load_va=0,
)

# Connection types in the canonical connectivity graph (CIR Connection.connection_type).
CONDUCTOR = "conductor"  # a wiring run between two devices on the same circuit
HOME_RUN = "home_run"  # a circuit's home-run back to the panel
FEEDER = "feeder"  # panel -> circuit-node edge on the single-line diagram
SWITCH_LEG = "switch_leg"  # control wiring from a switch to the luminaire(s) it controls

# Non-device CIR entity labels. Defined once so the renderer (which emits them) and the
# validator's expectation (which counts them) can never disagree about the spelling.
WALL_LABEL = "Wall"
ROOM_TAG_LABEL = "Room Tag"
DIMENSION_LABEL = "Dimension"
CIRCUIT_ROW_LABEL = "Panel Circuit Row"  # one per circuit on the panel-schedule sheet
CIRCUIT_NODE_LABEL = "Circuit"  # one per circuit on the single-line diagram


class Device(BaseModel):
    """One placed electrical device, in normalized sheet coordinates."""

    model_config = ConfigDict(extra="forbid")

    id: str
    kind: DeviceKind
    x: float  # normalized [0,1] center x — this IS the CIR bbox center x
    y: float  # normalized [0,1] center y
    circuit_id: str | None = None  # the circuit this device is wired to
    rotation_deg: float = 0.0
    controls: list[str] = Field(default_factory=list)  # ids a switch controls (switch legs)


class Panel(BaseModel):
    """The panelboard: the root of the connectivity graph."""

    model_config = ConfigDict(extra="forbid")

    id: str
    name: str  # e.g. "LP-1"
    x: float
    y: float
    voltage: str = "120/208V"
    phases: int = 1


class Circuit(BaseModel):
    """One branch circuit: an ordered run of devices home-running to the panel.

    ``device_ids`` is ordered so the renderer can daisy-chain conductor runs
    (device→device) and draw one home-run from the run back to the panel. The number
    of circuits is the headline connectivity quantity the validator pins ("M circuits").
    """

    model_config = ConfigDict(extra="forbid")

    id: str
    number: int  # circuit number on the panel (1, 3, 5, ...)
    panel_id: str
    device_ids: list[str] = Field(default_factory=list)
    description: str = ""
    breaker_amps: int = 20
    poles: int = 1
    load_va: int = 0  # connected VA (reconciles against the devices on the circuit)
    phase: str = "A"  # phase assignment (A/B/C) for panel load balancing


class Room(BaseModel):
    """A room polygon (normalized), for context and the floor-plan walls."""

    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    polygon: list[tuple[float, float]]
    room_type: RoomType = RoomType.OFFICE


class Wall(BaseModel):
    """A wall polygon (normalized). Scored by ``external_wall_iou`` downstream."""

    model_config = ConfigDict(extra="forbid")

    id: str
    polygon: list[tuple[float, float]]


class Dimension(BaseModel):
    """A dimension annotation with its exact real-world value (canonical mm)."""

    model_config = ConfigDict(extra="forbid")

    id: str
    p0: tuple[float, float]
    p1: tuple[float, float]
    value_mm: float
    raw: str  # as printed, e.g. "10'-0\""


class ElectricalModel(BaseModel):
    """The complete, exact description of one synthetic electrical drawing set.

    This is the auditable source of truth: :mod:`synthetic.render` turns it into pixels
    *and* CIR ground truth in one pass, and :mod:`synthetic.scene` /
    :mod:`synthetic.ifc_source` are the only things that build it. Serializes to JSON
    (``extra="forbid"`` catches schema drift) so the standalone validator can re-derive
    the expectation from the persisted model — an independent check that the CIR on disk
    matches the model it claims to come from.
    """

    model_config = ConfigDict(extra="forbid")

    id: str
    panel: Panel
    devices: list[Device] = Field(default_factory=list)
    circuits: list[Circuit] = Field(default_factory=list)
    rooms: list[Room] = Field(default_factory=list)
    walls: list[Wall] = Field(default_factory=list)
    dimensions: list[Dimension] = Field(default_factory=list)
    project_name: str = "Synthetic Electrical Project"
    sheet_prefix: str = "E"  # discipline letter for sheet numbers

    # -- accessors used by the renderer and the expectation builder --------------
    def device(self, device_id: str) -> Device:
        """The device with ``device_id`` (raises if absent — a model-integrity bug)."""
        for d in self.devices:
            if d.id == device_id:
                return d
        raise KeyError(f"device {device_id!r} not in model {self.id!r}")

    def devices_on(self, circuit: Circuit) -> list[Device]:
        """The circuit's devices, in wiring order."""
        return [self.device(did) for did in circuit.device_ids]

    def circuit_load_va(self, circuit: Circuit) -> int:
        """Connected VA on a circuit = sum of its devices' loads (the reconciling value)."""
        return sum(DEVICE_CATALOG[d.kind].load_va for d in self.devices_on(circuit))

    def device_count_by_kind(self) -> dict[DeviceKind, int]:
        """How many of each device kind — the per-class counts the validator pins."""
        counts: dict[DeviceKind, int] = {}
        for d in self.devices:
            counts[d.kind] = counts.get(d.kind, 0) + 1
        return counts

    def assert_consistent(self) -> None:
        """Cheap internal-integrity checks on the model itself (not the render).

        Catches a malformed *model* before it is ever rendered: every circuit device
        exists, device circuit back-references agree, ids are unique. A model that
        fails here is a scene/IFC-loader bug.
        """
        ids = [d.id for d in self.devices]
        if len(ids) != len(set(ids)):
            raise ValueError(f"model {self.id!r}: duplicate device ids")
        circuit_ids = {c.id for c in self.circuits}
        if len(circuit_ids) != len(self.circuits):
            raise ValueError(f"model {self.id!r}: duplicate circuit ids")
        for circuit in self.circuits:
            for did in circuit.device_ids:
                dev = self.device(did)  # raises if missing
                if dev.circuit_id != circuit.id:
                    raise ValueError(
                        f"model {self.id!r}: device {did!r} on circuit {circuit.id!r} but "
                        f"its circuit_id is {dev.circuit_id!r}"
                    )
        known = set(ids)
        for dev in self.devices:
            for controlled in dev.controls:
                if controlled not in known:
                    raise ValueError(
                        f"model {self.id!r}: device {dev.id!r} controls unknown {controlled!r}"
                    )
