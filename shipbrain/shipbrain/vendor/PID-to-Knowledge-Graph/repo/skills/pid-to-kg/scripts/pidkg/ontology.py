"""Controlled vocabularies for the P&ID knowledge graph.

Vocabularies are deliberately permissive: an unknown ``kind`` is accepted and
reported by QA rather than rejected, because real drawings always contain
something the vocabulary did not anticipate.

``DEXPI_CLASS`` maps each kind to the closest DEXPI (ISO 15926-based P&ID
exchange standard) class name. The mapping is informative: it helps users
align the graph with DEXPI tooling but is not a certified DEXPI export.
"""

from __future__ import annotations

# --------------------------------------------------------------------------
# Node and edge types
# --------------------------------------------------------------------------

NODE_TYPES = (
    "Plant",
    "Sheet",
    "Equipment",
    "PipeSegment",
    "Component",
    "Instrument",
    "ControlLoop",
    "OffPageConnector",
    "Boundary",
)

EDGE_TYPES = (
    # Physical process connectivity (directed in the direction of flow).
    "FLOWS_TO",
    # Derived equipment-to-equipment flow, collapsing pipes and fittings.
    "FEEDS",
    # Instrument -> the equipment, pipe segment or component it senses.
    "MEASURES",
    # Instrument/control signal (directed from sender to receiver).
    "SIGNAL_TO",
    # Controller or logic -> the final element it moves (valve, VFD/motor).
    "ACTUATES",
    # Instrument/component -> ControlLoop, with a ``role`` attribute.
    "MEMBER_OF",
    # ControlLoop -> ControlLoop (master -> slave in a cascade).
    "CASCADES_TO",
    # Safety/interlock action: initiator -> the item it trips.
    "TRIPS",
    # Sheet -> Plant; mounted equipment -> its parent (agitator -> tank).
    "PART_OF",
)

# Edge types followed when tracing upstream/downstream process flow.
FLOW_EDGE_TYPES = ("FLOWS_TO",)

# --------------------------------------------------------------------------
# Equipment
# --------------------------------------------------------------------------

EQUIPMENT_DEXPI = {
    "tank": "Tank",
    "vessel": "Vessel",
    "pressure_vessel": "PressureVessel",
    "pump": "Pump",
    "centrifugal_pump": "CentrifugalPump",
    "positive_displacement_pump": "ReciprocatingPump",
    "metering_pump": "ReciprocatingPump",
    "slurry_pump": "CentrifugalPump",
    "sump_pump": "CentrifugalPump",
    "compressor": "Compressor",
    "blower": "Blower",
    "fan": "Fan",
    "heat_exchanger": "HeatExchanger",
    "cooler": "HeatExchanger",
    "heater": "HeatExchanger",
    "boiler": "Boiler",
    "furnace": "Furnace",
    "column": "Column",
    "reactor": "Vessel",
    "agitated_tank": "Tank",
    "agitator": "Agitator",
    "mixer": "Mixer",
    "static_mixer": "StaticMixer",
    "filter": "Filter",
    "filter_press": "Filter",
    "membrane_filter": "Filter",
    "strainer_unit": "Filter",
    "screen": "Sieve",
    "cyclone": "CycloneSeparator",
    "hydrocyclone": "CycloneSeparator",
    "separator": "Separator",
    "clarifier": "Separator",
    "thickener": "Separator",
    "flotation_cell": "Separator",
    "centrifuge": "Centrifuge",
    "dryer": "Dryer",
    "mill": "Mill",
    "crusher": "Crusher",
    "conveyor": "Conveyor",
    "feeder": "Feeder",
    "hopper": "Silo",
    "bin": "Silo",
    "silo": "Silo",
    "sump": "Tank",
    "pond": "Tank",
    "box": "Tank",
    "electrowinning_cell": "Vessel",
    "kiln": "Furnace",
    "scrubber": "Column",
    "ion_exchange": "Column",
    "uv_unit": "Equipment",
    "sampler": "Equipment",
    "package_unit": "Equipment",
    "motor": "ElectricMotor",
    "other": "Equipment",
}
EQUIPMENT_KINDS = tuple(EQUIPMENT_DEXPI)

# --------------------------------------------------------------------------
# In-line piping components
# --------------------------------------------------------------------------

COMPONENT_DEXPI = {
    "manual_valve": "OperatedValve",
    "gate_valve": "GateValve",
    "globe_valve": "GlobeValve",
    "ball_valve": "BallValve",
    "butterfly_valve": "ButterflyValve",
    "plug_valve": "PlugValve",
    "knife_gate_valve": "GateValve",
    "diaphragm_valve": "DiaphragmValve",
    "pinch_valve": "OperatedValve",
    "needle_valve": "NeedleValve",
    "three_way_valve": "OperatedValve",
    "check_valve": "CheckValve",
    "backflow_preventer": "CheckValve",
    "control_valve": "OperatedValve",
    "on_off_valve": "OperatedValve",
    "solenoid_valve": "OperatedValve",
    "motor_operated_valve": "OperatedValve",
    "pressure_regulator": "OperatedValve",
    "relief_valve": "SafetyValveOrFitting",
    "rupture_disc": "RuptureDisc",
    "vacuum_breaker": "SafetyValveOrFitting",
    "strainer": "Strainer",
    "filter": "Filter",
    "reducer": "PipeReducer",
    "blind": "Blind",
    "spectacle_blind": "SpectacleBlind",
    "flexible_hose": "Hose",
    "expansion_joint": "Compensator",
    "sight_glass": "SightGlass",
    "steam_trap": "SteamTrap",
    "flame_arrestor": "FlameArrestor",
    "sample_point": "PipingComponent",
    "drain": "PipingComponent",
    "vent": "PipingComponent",
    "quick_connect": "PipingComponent",
    "tee": "PipeTee",
    "other": "PipingComponent",
}
COMPONENT_KINDS = tuple(COMPONENT_DEXPI)

# Components that can be the final element of a control or trip loop.
ACTUATED_COMPONENT_KINDS = {
    "control_valve",
    "on_off_valve",
    "solenoid_valve",
    "motor_operated_valve",
    "three_way_valve",
}

# --------------------------------------------------------------------------
# Instruments
# --------------------------------------------------------------------------

INSTRUMENT_LOCATIONS = (
    "field",          # plain circle
    "local_panel",    # circle with line, dashed or in a local/field panel
    "main_panel",     # circle with solid line: main control room panel
    "behind_panel",   # circle with dashed line
    "dcs",            # circle in square: shared display / DCS
    "plc",            # diamond in square
    "scada",
    "sis",            # safety instrumented system
    "computer",       # hexagon
    "unknown",
)

SIGNAL_TYPES = (
    "electrical",   # dashed line
    "pneumatic",    # line with double cross-hatches
    "software",     # line with circles / data link
    "hydraulic",
    "capillary",    # line with x's
    "wireless",     # zig-zag / wave
    "mechanical",
    "unknown",
)

STATUSES = ("new", "existing", "future", "demolish", "unknown")

# ISA-5.1 first letters (measured or initiating variable).
ISA_MEASURED = {
    "A": "analysis",
    "B": "burner/flame",
    "C": "conductivity",      # user's choice; conductivity is the most common
    "D": "density",           # user's choice
    "E": "voltage",
    "F": "flow",
    "G": "gauging/position",  # user's choice
    "H": "hand",
    "I": "current",
    "J": "power",
    "K": "time",
    "L": "level",
    "M": "moisture",          # user's choice
    "N": "user-defined",
    "O": "user-defined",
    "P": "pressure",
    "Q": "quantity",
    "R": "radiation",
    "S": "speed/frequency",
    "T": "temperature",
    "U": "multivariable",
    "V": "vibration",
    "W": "weight/force",
    "X": "unclassified",
    "Y": "event/state",
    "Z": "position",
}

# Variable modifiers that may follow the first letter.
ISA_VARIABLE_MODIFIERS = {
    "D": "differential",
    "F": "ratio",
    "J": "scan",
    "K": "rate of change",
    "Q": "integrate/totalize",
}

# Succeeding letters (readout/passive or output functions).
ISA_FUNCTIONS = {
    "A": "alarm",
    "B": "user's choice",
    "C": "control",
    "D": "differential",
    "E": "primary element",
    "G": "glass/gauge",
    "H": "high",
    "I": "indicate",
    "K": "control station",
    "L": "light/low",
    "M": "middle",
    "N": "user's choice",
    "O": "orifice/restriction",
    "P": "test point",
    "Q": "totalize",
    "R": "record",
    "S": "switch",
    "T": "transmit",
    "U": "multifunction",
    "V": "valve/damper",
    "W": "well",
    "X": "unclassified",
    "Y": "relay/compute/convert",
    "Z": "driver/actuator",
}
