# Knowledge graph ontology

`graph.json` is a typed property graph: a list of nodes and a list of directed edges. The exact schema is in `schema/graph.schema.json`, and the vocabularies live in `scripts/pidkg/ontology.py`.

## Contents
1. Design choices
2. Node types
3. Edge types
4. How the builder derives edges
5. Kind vocabulary and DEXPI mapping
6. Example queries

## 1. Design choices

- **Pipes are nodes.** Each line is split into `PipeSegment` nodes between its in-line items: `TK-1 → seg → V1 → seg → P-1`. An instrument tap then points at an exact segment, so "where does PT-101 sit" has a precise answer, and upstream/downstream is one traversal over `FLOWS_TO`.
- **Tags are ids.** A tagged item's id is its normalized tag (`660-TK-004`, `FIT-0502`), so the same item on several sheets merges into one node. Untagged items get sheet-scoped ids (`P05.V3`, `P05.L2.1`).
- **Provenance and confidence everywhere.** Each node records the sheet, page and region it was read from, plus a confidence. Derived edges have `derived: true`.
- **One graph per plant.** The `Plant` node and `plant` header identify it.

## 2. Node types

| Type | Id pattern | What it is | Key attributes |
|---|---|---|---|
| `Plant` | `PLANT:<id>` | The plant or facility | `source_file` |
| `Sheet` | `SHEET:<drawing no.>` | One drawing sheet | `page`, `drawing_number`, `title`, `revision`, `drawing_type`, `notes` |
| `Equipment` | tag, or `Pnn.<local>` | Major process equipment | `kind`, `name`, `status`, data-sheet values |
| `PipeSegment` | `Pnn.<line>.<k>` | A stretch of one line between two in-line items | `line_number`, `size`, `service`, `segment`/`segments` |
| `Component` | tag, or `Pnn.<local>` | Valve or in-line fitting | `kind`, `actuator`, `fail_position`, `normal_position`, `size`; for loop valves also `role` and `loop_key` |
| `Instrument` | tag | ISA instrument or function | `variable`, `functions`, `role` (transmitter, controller, switch…), `location`, `loop_key`, `inline` |
| `ControlLoop` | `LOOP:<key>` | Inferred loop | `loop_type` (control, interlock, manual, on_off, monitoring), `variable`, `sensors`, `controllers`, `final_elements`, `relays`, `measured_at`, `manipulated_at`, `cascade_master`/`cascade_slaves`, `description` |
| `OffPageConnector` | `Pnn.<local>` | Continuation flag | `direction`, `other_drawing`, `other_item`, `linked_to`/`linked_from` |
| `Boundary` | `BOUNDARY:<NAME>` | Source or sink outside the drawings | `direction` (source, sink) |

Every node has `label`, a short display name: the tag if present, otherwise the name or kind. It also has `sheets`, `confidence`, `dexpi_class` and `provenance`.

## 3. Edge types

| Type | From → To | Meaning |
|---|---|---|
| `FLOWS_TO` | process item → process item | Physical flow, in flow direction. `flow_direction: inferred` marks a direction that was not drawn; `off_page: true` marks a sheet crossing |
| `FEEDS` | Equipment/Boundary → Equipment/Boundary | Derived. Equipment-level flow with pipes and fittings collapsed. `via_lines` and `via_items` list what lies between |
| `MEASURES` | Instrument → Equipment / PipeSegment / Component / in-line Instrument | Where the instrument senses the process |
| `SIGNAL_TO` | Instrument → Instrument / Component / Equipment | A drawn signal line. `signal_type` (electrical, pneumatic, software…), `purpose` (control, measurement, trip, alarm, status) |
| `ACTUATES` | controller or switch → final element | Derived. What the loop moves; `via` lists relays such as I/P converters |
| `MEMBER_OF` | Instrument/Component → ControlLoop | Derived. `role`: sensor, controller, relay, final_element, sensor_input… |
| `CASCADES_TO` | ControlLoop → ControlLoop | Derived. The master loop sets the setpoint of the slave loop |
| `TRIPS` | initiator → final element | Derived for interlock loops |
| `PART_OF` | Sheet → Plant; mounted Equipment → its parent | An agitator, decanter or drive belongs to the tank or machine it sits on |

## 4. How the builder derives edges

1. **Lines become chains:** `from → segment → path[0] → segment → … → to`. A tee (`{"line": "L2", "after": "V2"}`) attaches to the segment of L2 just downstream of V2.
2. **Measurements:**
   - In-line instruments measure the segment just upstream of them.
   - A transmitter with no location of its own inherits the location of the primary element that signals to it, or failing that, of an element in the same ISA loop (FIT-0502 takes its location from FE-0502).
3. **Off-page connectors are paired across sheets.** The score combines whether each connector names the other's drawing, a matching line number and overlapping label text. A connector with no partner is linked by `other_item` when that tag exists on another sheet. Any connector still unmatched is reported in QA.
4. **Loops:**
   - Items are grouped by ISA loop key: the first letter plus the number, e.g. F-101.
   - A controller's output signals are followed through relays to the final element (`ACTUATES`), even when the numbers differ.
   - A signal from one controller to another becomes `CASCADES_TO`.
   - A signal with purpose `trip` makes the loop an interlock, and `TRIPS` edges are added.
   - Groups with fewer than two members and no controller are not loops.
5. **Equipment-level flow:** `FEEDS` comes from walking `FLOWS_TO` from each equipment item or boundary through segments, components, instruments and connectors to the next equipment item or boundary.

## 5. Kind vocabulary and DEXPI mapping

`dexpi_class` gives the closest [DEXPI](https://dexpi.org) class, to help users align the graph with DEXPI tooling. It is informative, not a certified DEXPI export.

**Equipment kinds:** tank, vessel, pressure_vessel, pump, centrifugal_pump, positive_displacement_pump, metering_pump, slurry_pump, sump_pump, compressor, blower, fan, heat_exchanger, cooler, heater, boiler, furnace, column, reactor, agitated_tank, agitator, mixer, static_mixer, filter, filter_press, membrane_filter, strainer_unit, screen, cyclone, hydrocyclone, separator, clarifier, thickener, flotation_cell, centrifuge, dryer, mill, crusher, conveyor, feeder, hopper, bin, silo, sump, pond, box, electrowinning_cell, kiln, scrubber, ion_exchange, uv_unit, sampler, package_unit, motor, other.

**Component kinds:** manual_valve, gate_valve, globe_valve, ball_valve, butterfly_valve, plug_valve, knife_gate_valve, diaphragm_valve, pinch_valve, needle_valve, three_way_valve, check_valve, control_valve, on_off_valve, solenoid_valve, motor_operated_valve, pressure_regulator, relief_valve, rupture_disc, vacuum_breaker, strainer, reducer, blind, spectacle_blind, flexible_hose, expansion_joint, sight_glass, steam_trap, flame_arrestor, sample_point, drain, vent, quick_connect, tee, other.

**Boundary directions:** source, sink, area (a room or zone measured by area instruments).

**Instrument locations:** field, local_panel, main_panel, behind_panel, dcs, plc, scada, sis, computer, unknown.

**Statuses:** new, existing, future, demolish, unknown.

## 6. Example queries

DuckDB (`graph.duckdb`):

```sql
-- Everything downstream of a tank, equipment only
SELECT * FROM downstream('660-TK-001') WHERE type = 'Equipment';

-- Equipment-level flow sheet
SELECT from_label, to_label, via_lines FROM equipment_flow ORDER BY from_label;

-- Where each flow instrument senses the process
SELECT tag, role, location, measures_label FROM instruments WHERE variable = 'flow';

-- Control loops and their final elements
SELECT loop, loop_type, description FROM loops ORDER BY loop;
```

Python:

```python
import json
g = json.load(open("graph.json"))
feeds = [(e["source"], e["target"]) for e in g["edges"] if e["type"] == "FEEDS"]
```
