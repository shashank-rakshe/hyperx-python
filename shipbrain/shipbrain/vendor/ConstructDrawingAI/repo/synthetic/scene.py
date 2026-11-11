"""Parametric electrical scene generation — the v0 source of truth.

This is the source of truth for electrical content (not IFC — see ``docs/SYNTHETIC.md``),
so **its realism is the engine's quality ceiling**: every model trained on this data
inherits the assumptions encoded here about how real electrical layouts look. Closing the
sim-to-real gap means deepening *this* file toward real-world conventions.

What v0.2 models (toward those conventions):

* **Space types** (:class:`~synthetic.model.RoomType`) drive device kinds and densities —
  e.g. GFCI receptacles in restrooms/break rooms (code), 3-way switching in corridors and
  conference rooms, the panel living in an electrical room.
* **Code-plausible circuiting** — receptacle and lighting circuits are split, sized to a
  connected-load budget (NEC-style VA), and **balanced across phases**, so the panel
  schedule reconciles against the plan.
* **Switch legs** — switches are control devices (no connected load) wired to the luminaire
  they control via a ``switch_leg`` edge, rather than sitting on the power daisy-chain.

It builds *our in-memory canonical model directly*; it does **not** synthesize IFC. All
coordinates are normalized to the sheet inside ``layout.PLAN_REGION``, so a device's
coordinate *is* its CIR bounding-box center (no transform to the ground truth).
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .layout import PLAN_REGION
from .model import (
    DEVICE_CATALOG,
    Circuit,
    Device,
    DeviceKind,
    Dimension,
    ElectricalModel,
    Panel,
    Room,
    RoomType,
    Wall,
)

# Glyph half-size headroom kept clear of room edges so symbols stay inside the plan.
_INSET = 0.022
# Connected-load budget per 20 A / 120 V branch circuit (NEC continuous: 20*120*0.8).
_CIRCUIT_VA_BUDGET = 1920
_MAX_DEVICES_PER_CIRCUIT = 12


@dataclass
class _RoomRule:
    """How a space type is populated: receptacle/light kinds + count ranges + switching."""

    recept_kind: DeviceKind
    recept_range: tuple[int, int]
    light_kinds: tuple[DeviceKind, ...]
    light_range: tuple[int, int]
    switch_kind: DeviceKind
    switch_range: tuple[int, int]


# Per-space-type population rules — the heart of "realistic densities + code conventions".
_ROOM_RULES: dict[RoomType, _RoomRule] = {
    RoomType.OFFICE: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (3, 5),
        (DeviceKind.LIGHT_FIXTURE, DeviceKind.RECESSED_DOWNLIGHT),
        (1, 2),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 1),
    ),
    RoomType.OPEN_OFFICE: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (6, 10),
        (DeviceKind.RECESSED_DOWNLIGHT, DeviceKind.LIGHT_FIXTURE),
        (4, 6),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 2),
    ),
    RoomType.CONFERENCE: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (4, 6),
        (DeviceKind.RECESSED_DOWNLIGHT,),
        (2, 4),
        DeviceKind.THREE_WAY_SWITCH,
        (2, 2),
    ),
    RoomType.CORRIDOR: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (1, 2),
        (DeviceKind.RECESSED_DOWNLIGHT,),
        (2, 4),
        DeviceKind.THREE_WAY_SWITCH,
        (2, 2),
    ),
    RoomType.RESTROOM: _RoomRule(
        DeviceKind.GFCI_RECEPTACLE,
        (1, 2),  # code: GFCI in wet areas
        (DeviceKind.WALL_LIGHT, DeviceKind.RECESSED_DOWNLIGHT),
        (1, 2),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 1),
    ),
    RoomType.BREAK_ROOM: _RoomRule(
        DeviceKind.GFCI_RECEPTACLE,
        (2, 4),  # kitchen counter receptacles -> GFCI
        (DeviceKind.LIGHT_FIXTURE,),
        (1, 2),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 1),
    ),
    RoomType.STORAGE: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (1, 1),
        (DeviceKind.RECESSED_DOWNLIGHT,),
        (1, 1),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 1),
    ),
    RoomType.ELECTRICAL: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (1, 1),
        (DeviceKind.LIGHT_FIXTURE,),
        (1, 1),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 1),
    ),
    RoomType.MECHANICAL: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (1, 2),
        (DeviceKind.LIGHT_FIXTURE,),
        (1, 2),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 1),
    ),
    RoomType.LOBBY: _RoomRule(
        DeviceKind.DUPLEX_RECEPTACLE,
        (2, 3),
        (DeviceKind.RECESSED_DOWNLIGHT,),
        (3, 4),
        DeviceKind.SINGLE_POLE_SWITCH,
        (1, 2),
    ),
}

# Non-electrical room types are sampled for variety; one room is forced ELECTRICAL.
_SAMPLEABLE_TYPES = [
    RoomType.OFFICE,
    RoomType.OPEN_OFFICE,
    RoomType.CONFERENCE,
    RoomType.CORRIDOR,
    RoomType.RESTROOM,
    RoomType.BREAK_ROOM,
    RoomType.STORAGE,
    RoomType.MECHANICAL,
    RoomType.LOBBY,
]


@dataclass
class _RoomBuild:
    """Bookkeeping for one populated room (used to wire switch legs to local lights)."""

    room: Room
    light_ids: list[str] = field(default_factory=list)
    switch_ids: list[str] = field(default_factory=list)


def _ft_in(feet: float) -> tuple[str, float]:
    """A real length in feet -> (printed ft-in string, canonical millimetres)."""
    total_in = round(feet * 12)
    ft, inch = divmod(total_in, 12)
    return (f"{ft}'-{inch}\"", total_in * 25.4)


def _panel_phases(voltage: str) -> list[str]:
    """Phases available for balancing: split-phase (A/B) vs three-phase (A/B/C)."""
    return ["A", "B"] if voltage.startswith("120/240") else ["A", "B", "C"]


def _grid(x0: float, y0: float, x1: float, y1: float, n: int) -> list[tuple[float, float]]:
    """``n`` points on a centered grid within a rectangle (for ceiling luminaires)."""
    if n <= 0:
        return []
    cols = math.ceil(math.sqrt(n))
    rows = math.ceil(n / cols)
    pts: list[tuple[float, float]] = []
    for i in range(n):
        r, c = divmod(i, cols)
        fx = (c + 1) / (cols + 1)
        fy = (r + 1) / (rows + 1)
        pts.append((x0 + fx * (x1 - x0), y0 + fy * (y1 - y0)))
    return pts


def build_electrical_model(
    *, seed: int, model_id: str | None = None, project_name: str | None = None
) -> ElectricalModel:
    """Deterministically build one electrical model from ``seed``."""
    rng = random.Random(seed)
    mid = model_id or f"syn-elec-{seed:08d}"
    pname = project_name or f"Synthetic Electrical Project {seed:08d}"

    gx0, gy0, gx1, gy1 = (
        PLAN_REGION[0] + 0.02,
        PLAN_REGION[1] + 0.03,
        PLAN_REGION[2] - 0.02,
        PLAN_REGION[3] - 0.03,
    )
    cols = rng.choice([2, 3])
    n_rooms = rng.randint(2, min(6, cols * 2))
    rows = -(-n_rooms // cols)
    cell_w = (gx1 - gx0) / cols
    cell_h = (gy1 - gy0) / rows
    gap = 0.006

    building_ft = rng.uniform(48.0, 120.0)
    ft_per_norm_x = building_ft / (gx1 - gx0)

    room_types = _assign_room_types(rng, n_rooms)

    rooms: list[Room] = []
    walls: list[Wall] = []
    devices: list[Device] = []
    builds: list[_RoomBuild] = []
    recept_pool: list[str] = []
    light_pool: list[str] = []
    didx = 0
    electrical_rect: tuple[float, float, float, float] | None = None

    for r in range(n_rooms):
        ci, ri = r % cols, r // cols
        x0, y0 = gx0 + ci * cell_w + gap, gy0 + ri * cell_h + gap
        x1, y1 = gx0 + (ci + 1) * cell_w - gap, gy0 + (ri + 1) * cell_h - gap
        poly = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        rtype = room_types[r]
        room = Room(id=f"{mid}-rm{r}", name=_room_name(rtype, r), polygon=poly, room_type=rtype)
        rooms.append(room)
        walls.append(Wall(id=f"{mid}-w{r}", polygon=poly))
        if rtype is RoomType.ELECTRICAL:
            electrical_rect = (x0, y0, x1, y1)

        build = _RoomBuild(room=room)
        didx = _populate_room(
            mid, rng, rtype, (x0, y0, x1, y1), devices, build, recept_pool, light_pool, didx
        )
        builds.append(build)

    _wire_switch_legs(builds, devices)

    panel = _place_panel(mid, rng, electrical_rect, gy0, gy1)
    circuits = _build_circuits(mid, rng, devices, recept_pool, light_pool, panel)
    dimensions = _build_dimensions(mid, rng, gx0, gx1, gy1, ft_per_norm_x)

    model = ElectricalModel(
        id=mid,
        panel=panel,
        devices=devices,
        circuits=circuits,
        rooms=rooms,
        walls=walls,
        dimensions=dimensions,
        project_name=pname,
        sheet_prefix="E",
    )
    model.assert_consistent()
    return model


def _assign_room_types(rng: random.Random, n_rooms: int) -> list[RoomType]:
    """Assign space types; exactly one room is ELECTRICAL (it holds the panel)."""
    types = [rng.choice(_SAMPLEABLE_TYPES) for _ in range(n_rooms)]
    types[rng.randrange(n_rooms)] = RoomType.ELECTRICAL
    return types


def _room_name(rtype: RoomType, index: int) -> str:
    label = rtype.value.replace("_", " ").title()
    return f"{label} {101 + index}"


def _populate_room(
    mid: str,
    rng: random.Random,
    rtype: RoomType,
    rect: tuple[float, float, float, float],
    devices: list[Device],
    build: _RoomBuild,
    recept_pool: list[str],
    light_pool: list[str],
    didx: int,
) -> int:
    """Place a room's devices per its space-type rule; returns the next device index."""
    x0, y0, x1, y1 = rect
    rule = _ROOM_RULES[rtype]

    # receptacles along the bottom wall, wrapping to the top wall if needed
    n_recept = rng.randint(*rule.recept_range)
    for k in range(n_recept):
        per_row = max(1, math.ceil(n_recept / 2)) if n_recept > 4 else n_recept
        row, col = divmod(k, per_row)
        fx = (col + 1) / (per_row + 1)
        x = x0 + _INSET + fx * (x1 - x0 - 2 * _INSET)
        y = (y1 - _INSET) if row == 0 else (y0 + _INSET)
        dev = Device(id=f"{mid}-d{didx}", kind=rule.recept_kind, x=x, y=y)
        devices.append(dev)
        recept_pool.append(dev.id)
        didx += 1

    # luminaires on a centered ceiling grid
    n_lights = rng.randint(*rule.light_range)
    for x, y in _grid(x0 + _INSET, y0 + 0.04, x1 - _INSET, y1 - 0.05, n_lights):
        kind = rng.choice(rule.light_kinds)
        dev = Device(id=f"{mid}-d{didx}", kind=kind, x=x, y=y)
        devices.append(dev)
        light_pool.append(dev.id)
        build.light_ids.append(dev.id)
        didx += 1

    # switches near the lower-left "door"
    n_switch = rng.randint(*rule.switch_range)
    for k in range(n_switch):
        dev = Device(
            id=f"{mid}-d{didx}", kind=rule.switch_kind, x=x0 + _INSET + 0.018 * k, y=y1 - _INSET
        )
        devices.append(dev)
        build.switch_ids.append(dev.id)
        didx += 1

    return didx


def _wire_switch_legs(builds: list[_RoomBuild], devices: list[Device]) -> None:
    """Connect each room's switch(es) to a representative luminaire (a switch leg)."""
    by_id = {d.id: d for d in devices}
    for build in builds:
        if not build.light_ids:
            continue
        target = build.light_ids[0]
        for sid in build.switch_ids:
            by_id[sid].controls = [target]


def _place_panel(
    mid: str,
    rng: random.Random,
    electrical_rect: tuple[float, float, float, float] | None,
    gy0: float,
    gy1: float,
) -> Panel:
    """Place the panelboard on the wall of the electrical room (or the left margin)."""
    voltage = rng.choice(["120/208V", "120/240V", "277/480V"])
    if electrical_rect is not None:
        x0, y0, _x1, y1 = electrical_rect
        return Panel(
            id=f"{mid}-panel",
            name=rng.choice(["LP-1", "LP-2", "PP-1", "H-1"]),
            x=x0 + 0.012,
            y=(y0 + y1) / 2,
            voltage=voltage,
        )
    return Panel(
        id=f"{mid}-panel",
        name=rng.choice(["LP-1", "LP-2", "PP-1", "H-1"]),
        x=PLAN_REGION[0] + 0.012,
        y=(gy0 + gy1) / 2,
        voltage=voltage,
    )


def _build_circuits(
    mid: str,
    rng: random.Random,
    devices: list[Device],
    recept_pool: list[str],
    light_pool: list[str],
    panel: Panel,
) -> list[Circuit]:
    """Split receptacles/lights into load-budgeted circuits and balance across phases."""
    by_id = {d.id: d for d in devices}
    phases = _panel_phases(panel.voltage)
    circuits: list[Circuit] = []
    number = 1

    def add_pool(ids: list[str], desc: str) -> None:
        nonlocal number
        chunk: list[str] = []
        load = 0
        # order left-to-right for tidy daisy-chains, then split by the load budget
        ordered = sorted(ids, key=lambda d: (by_id[d].x, by_id[d].y))

        def flush() -> None:
            nonlocal number, chunk, load
            if not chunk:
                return
            cid = f"{mid}-c{number}"
            for did in chunk:
                by_id[did].circuit_id = cid
            circuits.append(
                Circuit(
                    id=cid,
                    number=number,
                    panel_id=panel.id,
                    device_ids=list(chunk),
                    description=desc,
                    breaker_amps=20,
                    poles=1,
                    load_va=load,
                    phase=phases[(number - 1) % len(phases)],
                )
            )
            number += 1
            chunk, load = [], 0

        for did in ordered:
            va = DEVICE_CATALOG[by_id[did].kind].load_va
            if chunk and (load + va > _CIRCUIT_VA_BUDGET or len(chunk) >= _MAX_DEVICES_PER_CIRCUIT):
                flush()
            chunk.append(did)
            load += va
        flush()

    add_pool(recept_pool, "Receptacles")
    add_pool(light_pool, "Lighting")
    return circuits


def _build_dimensions(
    mid: str, rng: random.Random, gx0: float, gx1: float, gy1: float, ft_per_norm_x: float
) -> list[Dimension]:
    """A couple of horizontal dimension strings with exact canonical millimetre values."""
    dims: list[Dimension] = []
    n = rng.randint(1, 3)
    for i in range(n):
        x0 = gx0 + rng.uniform(0.0, 0.15)
        x1 = gx1 - rng.uniform(0.0, 0.15)
        y = gy1 + 0.02 + 0.02 * i
        feet = (x1 - x0) * ft_per_norm_x
        raw, value_mm = _ft_in(feet)
        dims.append(
            Dimension(id=f"{mid}-dim{i}", p0=(x0, y), p1=(x1, y), value_mm=value_mm, raw=raw)
        )
    return dims
