# Extraction procedure: one sheet → `extract/page_NN.json`

## Contents
1. Reading order
2. What to capture
3. Modelling rules (lines, tees, taps, signals, off-page connectors)
4. Confidence and coordinates
5. Worked example
6. Self-check before saving
7. Pitfalls seen on real drawings

---

## 1. Reading order

Work from `<work>/pages/page_NN/`.

1. **Overview first.** Open `overview_grid.png`.
   - Confirm the orientation.
   - Read the title block: drawing number, title and revision.
   - Note the legend and general notes.
   - Note the scope convention. Many drawings show existing or future plant in grey or dashed lines, and new work in solid black.
   - Sketch the sheet in your notes: the major equipment, where the main process lines run, and where lines leave the sheet.
2. **Every non-blank tile, in order** (r1c1, r1c2, …; blank tiles are grey in the grid and flagged in `tiles.json`). For each tile:
   - list every tagged item and every unlabelled valve or fitting on the lines;
   - follow each line to the tile edge, then pick it up in the neighbouring tile. Tiles overlap by about 15%, so the same item may appear twice: record it once.
   - read the instrument bubbles and the signal lines leaving them.
3. **Zoom when unsure.** Use `python scripts/crop.py <work> --page N --bbox x0 y0 x1 y1` for small text, crowded areas, or to check flow arrows and valve symbols. Don't guess a tag you cannot read; put it in `unreadable` instead.
4. **Trace before you write.** For every line, know its two ends and the in-line items between them in flow order before you write it down.

Record each tile you read in `tiles_reviewed`. QA checks the list against the non-blank tiles. A tile that the overview clearly shows to hold nothing but the title block, revision table, stamps, notes or empty border may be recorded as reviewed from the overview. If in doubt, open it.

## 2. What to capture

| Section | Capture | Key fields |
|---|---|---|
| `sheet` | Title block | `drawing_number`, `title`, `revision`, `drawing_type` (`pid`, `pfd` or `other`), `issue_status` (as printed: as-built, issued for tender, draft...), `legend_notes` (notes that change meaning, e.g. "TYP OF 2", "greyed = existing") |
| `equipment` | Tanks, vessels, pumps, compressors, exchangers, filters, screens, clarifiers, conveyors, packaged units, sumps, ponds… | `id`, `tag`, `kind`, `name` (the descriptive text), `status`, `part_of` (for agitators, mixers, decanters, diffusers and drives mounted on another item), `attributes` (capacity, size, motor kW, materials, if printed) |
| `components` | Every valve and in-line fitting **on a line**: manual, check, control, on/off, relief, regulators, strainers, reducers, blinds, hoses, sample points | `id`, `tag` (often blank for manual valves), `kind`, `actuator`, `fail_position`, `normal_position`, `size` |
| `instruments` | Every bubble, and every tag in an I/O or panel list | `id`, `tag` (or `function`, e.g. `"PI"`, for an untagged gauge — never invent a tag), `location` (from the bubble symbol), `measures` |
| `lines` | Every pipe run between two endpoints | `id`, `line_number`, `size`, `service`, `from`, `to`, `path`, `flow_direction` |
| `signals` | Every instrument/control signal line | `from`, `to`, `type` (from the line style), `purpose` |
| `off_page_connectors` | Arrows/flags where lines continue on another drawing | `id`, `direction`, `other_drawing`, `other_item`, `line_number`, `name` (the flag text) |
| `boundaries` | Where a line starts or ends at something not drawn as equipment on any sheet: "FROM LIFT STATION", "TO POND A-19", "TREATED WATER", "PLANT AIR", chemical feed labels. Also rooms and areas that area instruments monitor (gas detectors, flood switches) | `id`, `name`, `direction` (`source`, `sink`, or `area`) |

Use the vocabulary in [ontology.md](ontology.md) for `kind`. If nothing fits, use the closest term or `other` and put the printed description in `name`.

## 3. Modelling rules

### Ids and tags
- `id` must be unique within the page. Use the tag as the id when there is one (`"id": "660-TK-004"`). Otherwise use short ids: `V1`, `V2`, …, `L1`, `L2`, …, `OPC1`, `B1`.
- Write `tag` **exactly as printed**, including area prefixes (`660-TK-004`) and suffixes (`P-101A`). For ISA bubbles, join the two lines: `FIT` over `0502` → `FIT-0502`. Normalization is automatic, so `FIT 0502` and `FIT-0502` are the same.
- An item drawn on several sheets with the same tag is merged automatically. Do not rename it to avoid duplicates.

### Lines: runs between endpoints
A **line** is a run of pipe from one endpoint to another: equipment, boundary, off-page connector, or a tee on another line. `path` lists the in-line items **in flow order**.

```json
{"id": "L2", "line_number": "2\"-SG-660-007-SSB-ET", "from": "660-PP-011", "to": "OPC1",
 "path": ["V3", "V4", "FE-0502", "V5"], "flow_direction": "shown"}
```

- **Split runs at equipment.** A line enters a pump and a new line leaves it.
- **Direction.** Use arrows, pump orientation and equipment logic to set `from` and `to`. If no arrow shows the direction, give your best reading and set `"flow_direction": "inferred"`.
- **In-line instruments** go in `path`: magnetic and other in-line flowmeters, orifice plates (FE), in-line analysers. Do not repeat them as a separate tap.
- **Tees and branches** start or end on another line, placed after a path item:
  `"from": {"line": "L2", "after": "V2"}` means the branch leaves L2 just downstream of V2. Omit `after` when the tee is before L2's first path item.
- **Recycle and minimum-flow lines** are ordinary branches back to the upstream vessel.
- **Utility and chemical feeds** (polymer, lime, air, water) are lines from a `boundary` to the injection point.
- A **drain or vent** that ends at the atmosphere or at grade can be a `component` of kind `drain` or `vent` at the end of a short branch. Ignore it only if it carries no tag and no valve.

### Instruments
- `location` comes from the bubble symbol; see [isa_5_1.md](isa_5_1.md). A plain circle is `field`; a circle in a square is `dcs`; a diamond in a square is `plc`; and so on. Tags shown only in a PLC or SCADA I/O list (as on some sheets with an I/O band across the top) are instruments with `location` `plc` or `scada`.
- `measures` says where the instrument senses the process. **Every field sensor needs it**, unless it is in-line in a `path`:
  - On equipment: `{"item": "660-TK-004"}`. Level, tank temperature and agitator vibration are examples.
  - On a pipe: `{"line": "L2", "after": "V4"}`, the tap position on that run. A pressure gauge on a pump discharge is `{"line": "<discharge line>"}`, with `after` the last item before the tap.
  - On a component: `{"item": "FV-0502"}`. Valve position switches (ZSO/ZSC) are an example.
- Panel or DCS functions (controllers, indicators, alarms) normally have no `measures`. Signals connect them to the field.
- A control valve **is** the final element of its loop. Record it once as a `component` (`kind: "control_valve"`, `tag: "FV-0502"`) on its line. Do not record it again as an instrument.

### Signals
- One entry per signal line, in the signal's direction: transmitter → controller → (I/P relay) → valve.
- Set `type` from the line style: dashed = `electrical`, line with double hatch marks = `pneumatic`, line with small circles = `software`/data link. See [isa_5_1.md](isa_5_1.md).
- Set `purpose`:
  - `control`: controller output
  - `measurement`: sensor to controller or indicator
  - `trip`: interlock or shutdown action, e.g. a low-low level switch stopping a pump
  - `alarm`
  - `status`: e.g. motor running feedback
- A signal into a pump or motor (VFD speed, start/stop) uses the equipment id as `to`.
- Loops are built automatically from tag numbers and signals. Do not write loops yourself. For a non-ISA tag that clearly belongs to a loop, set `"loop": "F-101"` on the item.

### Off-page connectors
- Record the flag text in `name`, the drawing number it points to in `other_drawing`, and the named equipment at the far end, if printed, in `other_item`. Example: flag `660-PI-208 / 660-BX-001` → `other_drawing: "660-PI-208"`, `other_item: "660-BX-001"`.
- Set `direction` to `out` when flow leaves this sheet and `in` when it arrives.
- The line touching the connector uses its id as `to` (for `out`) or `from` (for `in`).
- A flag with **no drawing number** that names a utility or an existing system ("EXIST LINE PLANT AIR", "COAGULANT") is a `boundary`, not an off-page connector: there is no other sheet to pair it with.

### Scope and status
Set `status` to `existing`, `future` or `demolish` where the drawing distinguishes scope, using greyed or dashed linework, "EXISTING" or "BY OTHERS" labels, or the legend. Leave it out otherwise. Extract greyed items like any other: the graph should describe the whole process drawn.

## 4. Confidence and coordinates

`confidence` is your probability that the item, or the connection, is right as written:

| Confidence | When to use it |
|---|---|
| 0.95 | Crisp text and an unambiguous symbol, confirmed in two tiles or a zoom |
| 0.85 | Clear, but read once |
| 0.7 | Partly legible: one character uncertain, or symbol type uncertain |
| 0.5 | Inferred from context, e.g. a line passing behind a note, or a tag guessed from a neighbour |
| < 0.5 | Don't record it; put it in `unreadable` instead |

`bbox` is `[x0, y0, x1, y1]` on the **upright page**, normalized 0–1 with the origin at the top-left. Estimate it from the overview grid or from tile positions in `tiles.json`, where each tile has a `norm` box. Approximate is fine: it is used to send QA re-checks to the right tile. Give a bbox for every equipment item, instrument, tagged component and off-page connector.

## 5. Worked example

The fragment shows a transfer pump with a discharge flowmeter, a local pressure gauge, and a flow loop in the DCS.

```json
{
  "schema_version": "1.0",
  "page": 5,
  "sheet": {"drawing_number": "660-PI-203", "title": "Lamella clarifier transfer pumps",
            "revision": "0", "drawing_type": "pid"},
  "equipment": [
    {"id": "660-EQ-002", "tag": "660-EQ-002", "kind": "clarifier", "name": "LAMELLA CLARIFIER",
     "bbox": [0.48, 0.42, 0.80, 0.68]},
    {"id": "660-PP-011", "tag": "660-PP-011", "kind": "centrifugal_pump", "bbox": [0.38, 0.40, 0.42, 0.44]}
  ],
  "components": [
    {"id": "V1", "kind": "gate_valve", "bbox": [0.45, 0.40, 0.47, 0.43]},
    {"id": "V2", "kind": "check_valve", "bbox": [0.33, 0.40, 0.35, 0.43]},
    {"id": "V3", "kind": "gate_valve", "bbox": [0.24, 0.40, 0.26, 0.43]}
  ],
  "instruments": [
    {"id": "PI-0501", "tag": "PI-0501", "location": "field",
     "measures": {"line": "L2", "after": "V2"}, "bbox": [0.34, 0.35, 0.36, 0.38]},
    {"id": "FE-0502", "tag": "FE-0502", "location": "field", "bbox": [0.25, 0.41, 0.27, 0.45]},
    {"id": "FIT-0502", "tag": "FIT-0502", "location": "field", "bbox": [0.25, 0.45, 0.27, 0.49]}
  ],
  "lines": [
    {"id": "L1", "line_number": "12\"-TW-660-008-PEA17-NA", "from": "660-EQ-002", "to": "660-PP-011",
     "path": ["V1"]},
    {"id": "L2", "line_number": "2\"-SG-660-007-SSB-ET", "from": "660-PP-011", "to": "OPC1",
     "path": ["V2", "FE-0502", "V3"]}
  ],
  "signals": [
    {"from": "FE-0502", "to": "FIT-0502", "type": "unknown", "purpose": "measurement"}
  ],
  "off_page_connectors": [
    {"id": "OPC1", "direction": "out", "name": "660-PI-202 / 660-BX-001",
     "other_drawing": "660-PI-202", "other_item": "660-BX-001",
     "line_number": "2\"-SG-660-007-SSB-ET", "bbox": [0.08, 0.38, 0.14, 0.42]}
  ],
  "boundaries": [],
  "tiles_reviewed": ["r1c1", "r1c2", "r2c1", "r2c2"],
  "unreadable": []
}
```

FIT-0502 is not in a `path` because the flow element FE-0502 is the in-line part. The transmitter reads FE-0502 through the signal. The builder therefore places FIT-0502's measurement at FE-0502's location.

## 6. Self-check before saving

- [ ] Title block captured; `page` matches the file name.
- [ ] Every non-blank tile is in `tiles_reviewed`.
- [ ] Every tagged item on the sheet is in exactly one section. Scan the overview once more for missed bubbles and tags.
- [ ] Every line has `from`, `to` and an ordered `path`, and each valve on it appears in exactly one `path`.
- [ ] Every equipment item has at least one line, unless it really stands alone on this sheet (e.g. a spare).
- [ ] Every field sensor has `measures`, or is in a `path`, or is connected by a signal to an in-line element.
- [ ] Every controller has its input and output signals, as far as the drawing shows them.
- [ ] Every line end that leaves the sheet is an off-page connector or a boundary.
- [ ] No invented tags. Anything unclear is in `unreadable` or has a lowered `confidence`.
- [ ] The JSON parses. `build_kg.py` reports schema problems precisely.

## 7. Pitfalls seen on real drawings

- **Text rotated relative to the page.** Orient by the drawing labels. The title block may be rotated differently.
- **Reduced drawings.** Large sheets printed on letter paper have tiny text. Zoom with `crop.py` rather than guessing digits.
- **Manual valve tags in boxes** (e.g. `BAV-1201` for ball valves, `KGV-1201` for knife gate valves). These are **components** with tags, not instruments, even though the letters look like ISA codes. Decide by the symbol: a valve body on the line is a component; a circle or bubble is an instrument.
- **Mounted equipment.** Agitators, mixers, decanters, diffuser grids and separately tagged motors are `equipment` with `part_of` set to the tank or machine they sit on. They need no process line; signals (start/stop, VFD) go to them directly.
- **Area instruments.** Gas detectors (methane, H2S), room temperature and flood switches measure a room, not a stream: add a `boundary` with `direction: "area"` and point `measures` at it.
- **Same tag drawn twice.** Two physically different items printed with the same tag on one sheet (common on duplex pumps: both discharge gauges labelled PI-0502) are recorded as two items with different ids and the same `tag`; QA reports `duplicate_tag`. The same tag on two sheets is merged automatically, unless the two sheets show it on different equipment (e.g. numbering restarted per area), in which case it is kept apart and reported as `tag_reused`.
- **Shared loop numbers.** Some plants give every instrument on a piece of equipment its number: LIT-1201, FIT-1201 and HS-1201 all belong to SCR-1201. That is fine. Loops are grouped by variable letter + number, so they stay separate.
- **"TYP" and "TYP OF 2" notes.** Model what is drawn. Put the note in the item's `notes` or in `legend_notes`; do not copy items that are not drawn.
- **Packaged units.** A dashed box labelled as a vendor package becomes one `equipment` item (`kind: "package_unit"`). Model its connections at the boundary of the box, plus any internals that carry tags.
- **Two revisions of one drawing** (same tags, different title-block revision or status): extract only the revision the user wants; see SKILL.md.
- **Valve-type codes are not ISA tags.** KGV (knife gate), BAV (ball), PLV (plug), BUV (butterfly), CHV (check) are valve labels, not instruments. Record them as `components`; the builder does not put them in control loops unless they carry an actuator.
- **PFD sheets** have few instruments and no line numbers. Still capture equipment, streams (lines) and boundaries, and set `drawing_type: "pfd"`.
