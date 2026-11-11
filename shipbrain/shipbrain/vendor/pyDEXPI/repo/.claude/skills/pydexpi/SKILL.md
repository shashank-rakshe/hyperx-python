---
name: pydexpi
description: >
  Load, inspect, search, validate and export DEXPI 2.0.1 P&ID and process (block flow diagram)
  models with pyDEXPI. Use when working with DEXPI or Proteus XML/JSON plant models,
  process steps, streams and materials, EngineeringModel objects,
  piping network segments, equipment or instrument tags, plant graphs, or exports to
  Neo4j, GraphML, SVG, PNG, PDF or Excel.
---

# Working with pyDEXPI

pyDEXPI implements the [DEXPI 2.0.1](https://dexpi.org/) data model in Python using Pydantic
(`pydexpi.DEXPI_SPEC_VERSION`). It reads DEXPI 2.0 files too, converting them as it loads, and
writes 2.0.1 (workflows.md, *DEXPI 2.0 files are read as 2.0.1*).
Everything flows one way:

```
DEXPI XML / JSON / Proteus  →  loaders  →  EngineeringModel  →  toolkits  →  exports / query / validation
```

`EngineeringModel` is the root. It is a plain Pydantic model tree — no database, no session, no
lazy loading. Once loaded, everything is in memory and reachable by walking attributes.

This file orients. For recipes see [workflows.md](workflows.md); for code you can run see
[examples/](examples/). Conventions for *changing* pyDEXPI itself live in the repository's
`AGENTS.md`.

## Start here

```python
from pydexpi import (
    load_xml_file,
    load_json_file,
    load_model,
    get_graph,
    get_graphs,
    get_display_name,
)

model = load_xml_file("data/reference_pid.xml")
```

`pydexpi.loaders.public` is the loading API. Prefer it over instantiating `DexpiXmlSerializer`
or `JsonSerializer` yourself: each public call builds a fresh serializer, so error registries and
object registries never leak between loads. Proteus files are detected automatically (root
`PlantModel` with a `PlantInformation` child) and routed to `ProteusSerializer`, or to
`PlantEngineerProteusSerializer` when `PlantInformation/@OriginatingSystem` is `"PlantEngineer"`.

The loaders raise rather than return `None`: `FileNotFoundError`, `ValueError` when the
serializer could not build a model (its message quotes what the loader recorded; text that is
not JSON is `json.JSONDecodeError`, a `ValueError` too), `TypeError` when the parsed root is not
an `EngineeringModel`. A JSON document with a part that is not what the format expects -- a
string where an object's `composition` block goes -- loads from the rest, and the part is an
`error` entry carrying it: read `load_json_with_report(...).errors`.

## Finding things in a model

Two layers, and they answer different questions.

**By type — `pydexpi.toolkits.model_toolkit`.** Walks the whole object tree.

```python
from pydexpi.pydexpi_classes.plant import instrumentation, piping, processEquipment
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

equipment = get_all_instances_in_model(model, processEquipment.TaggedPlantItem)
segments = get_all_instances_in_model(model, piping.PipingNetworkSegment)
```

Note the argument order: the class filter is the *last* parameter, not the second —
`get_instances_with_condition(model, predicate, dexpi_classes=...)` and
`get_instances_with_attribute(model, "tagName", "P4711", dexpi_classes=...)`.

**By tag / type name / id — `pydexpi.query`.** Ranked, fuzzy, paginated.

```python
from pydexpi.query import search_objects

page = search_objects(model, "P4711")  # -> SearchResultPage
match = page.results[0]  # -> SearchMatch(.object_id, .label, .score, ...)
```

Repeated queries against one model: build a `QueryEngine(model)` once and call
`engine.search_objects(...)`, `engine.get_by_tag(...)`, `engine.neighbors(...)`,
`engine.find_paths(...)` — it caches the index and the graph.

**Along a line — `pydexpi.toolkits.piping_toolkit.run_items`.** The items of a line in flow
order, from a segment or an item on it, through tees along the run and never into a branch:

```python
from pydexpi.toolkits.piping_toolkit import run_items

items = run_items(model, segment)  # list[PipingNetworkSegmentItem], source to target
```

Do not read flow order off `segment.items`: list order is not flow order in an imported file, and
a line split at a tee is several segments. See [workflows.md](workflows.md).

## Labels

Always `get_display_name(obj)` for an object. It is the single source of truth for the
human-readable caption used by graph exports, search (`SearchMatch.label`,
`ObjectDescription.display_name`), validation messages and the CLI, and it is type-aware. Where
you want the bare tag, `pydexpi.toolkits.display_name.get_tag(obj)` is the same resolution without
the id fallback; the query index and `SearchMatch.tag_name` use it. A process object's tag is its
`identifier`, and its free-text `label` is a caption fallback, never a tag; identifiers repeat in
real process files, so `get_by_tag` may raise `AmbiguousTagError`. Do not re-derive a caption
or tag from `tagName` and friends, and do not add another tag extractor
(`diff.engine.TAG_ATTRIBUTE_ORDER` is the last older, narrower one).

Enum values and attribute names have their own labels, from the same module family:

```python
from pydexpi import attribute_label, enum_value_label
from pydexpi.pydexpi_classes.core.physicalQuantities import PressureGaugeUnit, TemperatureUnit
from pydexpi.pydexpi_classes.plant.enumerations import FailActionClassification

enum_value_label(TemperatureUnit.DEGREECELSIUS)  # "°C" (units: quantity_format.unit_symbol)
enum_value_label(PressureGaugeUnit.BAR)  # "barg" (the pressure reference is spelled out)
enum_value_label(FailActionClassification.FAILCLOSE)  # "Fail close"
attribute_label("designPressure")  # "Design pressure"
attribute_label("pipingComponentName")  # "Component name" (curated override)
```

Use these rather than formatting `member.value` or the attribute name yourself.
`examples/load_and_inspect.py` prints a pump's and a segment's attributes with both.

## The direction trap in piping

The one thing most likely to be got wrong. Two vocabularies meet, and mixing them is the trap:

- **in / out node** describes an **item** — where medium enters it, and where it leaves.
- **source / target node** describes a **connection** — where it draws from, and where it
  discharges.

They meet head to tail: a connection's target is an item's in node, its source is an item's out
node. Under `PipingConnectionConvention.IN_NODE_0_OUT_NODE_1`, **node 0 = in, node 1 = out**,
so a connection's source is the upstream item's `nodes[1]` and its target is the downstream
item's `nodes[0]`. Never assume `nodes[0]` is the source. DEXPI mandates no index convention;
this one is the Proteus default, which is why the toolkit adopted it.

**A segment's own source/target nodes invert this at its ends, by design.** A segment ending
in a *pipe* takes that pipe's target — an in node, index 0. A segment ending in an *item* takes
that item's main out node, index 1. Symmetrically at the start. So the right connector index
depends on whether the connector is inside the segment or beyond it:

| Connector | Internal (segment's own end item) | External (segment ends in a pipe) |
| --- | --- | --- |
| source | `0` | `1` |
| target | `1` | `0` |

Never flip the indices to make a model look consistent: for an external connector that
reverses real flow direction. See AGENTS.md for the full account.

## Validating

```python
from pydexpi.validation.default_validator import validate

issues = validate(model)  # list[ValidationIssue]
```

Each `ValidationIssue` carries `short_description`, `long_description`, `applied_rule_id`,
`level_of_recommendation` (`MANDATORY` / `RECOMMENDED` / `OPTIONAL`) and
`affected_component_ids`. Filter on the level — `OPTIONAL` issues are informational and a
model with them is not broken.

## Exporting

`pydexpi.exports` re-exports the file-writing wrappers: `export_neo4j_csv`, `export_graphml`,
`export_tables`, `export_llm_context`, plus the DataFrame accessors `get_all_tables` /
`get_equipment_dataframe` / `get_valve_dataframe` and friends. Graph-shaped exporters take a
`graph_level` of `"complete"`, `"process"` or `"conceptual"` (P&ID levels), or `"process_flow"`
for a DEXPI process model (steps as nodes, one edge per connection keyed by its id, plus
`delegation` and `measures` edges for delegated ports and measurements; step details,
instrumentation activities and the control loops that compose them are nodes too). That level is
now *recorded in the output* — as a `graph_level` property on the graph, every node and every edge — alongside the
model provenance, so an exported graph identifies itself. Most exporters also have an in-memory
variant (`export_*_bytes` / `export_*_strings` / `get_*_records`) if you do not want to touch
disk. Table exports take `language=` (`"en"`/`"de"`/`"nl"`/`"zh"`); Excel tables are styled as
industrial register documents (title block from the model metadata, styled header, print setup)
unless `styled=False` — the data header is then offset, computed by
`pydexpi.exports.table_style.data_header_row(...)`. See [workflows.md](workflows.md).

## Attribution of written files

Every DEXPI XML/JSON file pyDEXPI writes is stamped with the DEXPI-native
`EngineeringModel.originatingSystem*` fields, and gets a `Generated with …` comment in the XML
header. Graph exports carry a `generator` graph property, Excel a workbook-description line, SVG
a `<metadata>` entry, PDF the `Producer`/`Creator` document info.

**Stamping never overwrites.** Only fields that are `None` get filled, so a model loaded from a
vendor tool keeps its own `originatingSystemName` through a save/load round-trip. An explicit
`Undefined` counts as data and is preserved too.

Rebrand it with environment variables — nothing to call, and no code change needed:

```bash
PYDEXPI_SYSTEM_NAME=ExampleCAD PYDEXPI_SYSTEM_VERSION=1.4.2 PYDEXPI_SYSTEM_VENDOR="ExampleCAD GmbH" \
  pydexpi convert model.xml -o model.json
```

`PYDEXPI_SYSTEM_URL` sets the link, and `PYDEXPI_POWERED_BY=0` drops the "(powered by pyDEXPI
…)" tail that a rebranded export otherwise carries in its free-text banner. The tail never
appears in `originatingSystemName` itself — that field holds the brand alone so it stays
groupable in Neo4j and Excel. `PYDEXPI_EXPORT_DATETIME=1` additionally stamps `exportDateTime`;
it is off by default so that output stays byte-reproducible.

## Shortcuts

```bash
pydexpi info model.xml                  # counts + tags
pydexpi convert model.xml -o model.json
pydexpi svg model.xml -o model.svg
pydexpi export-table model.xml
pydexpi export-graph model.xml

python .claude/skills/pydexpi/scripts/inspect_model.py model.xml --json

pydexpi info process.xml --lenient      # a DEXPI process export: strict=False
```

The script is the same summary as `pydexpi info` plus validation counts, emitted as JSON when
you need to branch on it. Every command that loads a model, and the script, take `--lenient`
(`strict=False`), which a DEXPI 2.0 process export usually needs -- see workflows.md. What a
lenient load keeps fails `pydexpi_mandatory_attribute_has_value` on most of its objects (405 on
the CO2 terminal), so the human output lists five MANDATORY issues per rule and counts the rest;
`--json` lists every one, to filter by `rule`.


Semantic tables retain `id`, `dexpi_class`, `id_kind` and `identity_diagnostic` in
all languages, including empty tables. `id` is the unchanged in-memory model ID,
usable with `get_by_id`; a blank/missing ID is null with `missing_id`. Duplicate
IDs are retained with `duplicate_id` diagnostics (do not join those rows without
repairing the model). `id_kind=generated_shape` flags the UUID shape minted by
pyDEXPI; this is not proof of source provenance, and XML may mint it again on
reload. `id_kind=model` means another model ID spelling, not a source guarantee.
No tag or number substitutes for an ID. Instrument numbers and display tags remain
nullable even when every row lacks them; JSON exports and MCP return null.


For AI engineering inventory and safety analysis, use MCP
`get_complete_piping_inventory()`: it always includes valves and off-page
connectors. Omit `limit` to fetch all rows, or fetch every page before analysing
the inventory. This covers objects in the loaded model; it does not establish
that the source document or plant is complete. In Python, call
`get_piping_component_dataframe(model, include_valves=True, include_connectors=True)`.
The older MCP `get_piping_component_list` retains False defaults for compatibility.
All PipingComponent subclasses, including inline measuring elements, appear; valves have a separate
table by default. Off-page connectors derive from PipeOffPageConnector, not
PipingComponent, and are topology objects included only with `include_connectors`.
With `include_valves=True` alone, the unpaginated total equals summary
`piping_component_count`; adding connectors increases it by their count. Pipes
are PipingConnection objects, not inventory components. Nozzles use the nozzle
table. Inventory is by composition identity, independent of drawings and tags;
MCP `total` counts the entire selected inventory before pagination.


`get_nozzle_dataframe(model)` and MCP `get_nozzle_list` supplement the existing
flat equipment table. Every nozzle retains `id`, `dexpi_class`, `sub_tag_name`,
`parent_id` (direct composition owner), `parent_equipment_id` (nearest tagged
ancestor), `node_ids`, `connection_ids` and `segment_ids`. Join the equipment ID
rather than a duplicate/empty subtag. Arrays name actual pipe/segment references
to the nozzle or its nodes; disconnected nozzles have empty arrays. Null IDs use
the identity diagnostics above. Untagged ancestry yields null equipment ID; shared
composition owners/cycles are explicit export errors rather than guessed parents.
These supplementary columns are untranslated and the five-table default is unchanged.


Line lists contain one row per **segment**, with `piping_system_id`,
`source_item_id`, `target_item_id`, `source_node_id`, `target_node_id` and endpoint
`*_status` columns. Source draws from upstream; target discharges downstream.
Segment boundaries retain the model's endpoints, including its item/pipe boundary
convention. System data is inherited for presentation without mutating the model.
Null endpoints are `missing`; detached referenced objects retain IDs with
`outside_model`; missing/duplicate target IDs are diagnosed separately. A loaded
model cannot recover raw unresolved XML IDs discarded by its loader: a null
reference means absent or unresolved, never a fabricated link.

`get_piping_connection_dataframe(model)` and MCP `get_piping_connection_list`
return each actual connection's identity and `segment_id`, with the same endpoint
columns. They preserve branches, cycles, open ends, connectors and parallel pipes.
Join IDs to the complete component/nozzle inventories; pipes have their own table.
Neither table imposes a universal item sequence. For traversal, MCP `find_paths`
takes explicit source/target references; `describe_run` follows a
well-defined piping run or reports ambiguity. Segment, system and path are distinct.


`get_instrument_relationship_dataframe(model)` / MCP
`get_instrument_relationship_list` expose instrumentation ownership and reference
edges from generated binding metadata. Property rows have `source_id` = owning
object and `target_id` = property value, exact `role`, `category` (composition or
reference), and list `ordinal`. Their `id`/`relationship_id` are the actual owning
DEXPI object ID; `(id, role, ordinal)` distinguishes property rows, without a
fabricated source ID. `category=flow`, `role=flow` rows use each signal/measuring
line's own `relationship_id` and its declared source -> target. Parallel lines,
including lines with identical endpoints, retain separate identities. Target
classes and source/target statuses diagnose missing, detached, blank or duplicate
IDs. Empty optional lists/references produce missing-target rows. Metadata
annotations (persistent IDs, notes, performed roles) are excluded.

Traverse instrument -> `actuatingFunctions` -> `systems` ->
`operatedValveReference` -> `valve`, or instrument ->
`processSignalGeneratingFunctions` -> `sensingLocation` / `systems` -> measuring
objects. These hops preserve intermediate objects and never join duplicate valve
numbers. Existing human instrument tables remain a compact display; their singular
valve/sensing columns are not a lossless relationship representation. Supplementary
DataFrames can be serialized with `to_json(orient="records")`.

Proteus/DEXPI 1.3 inputs use the existing loader's mapping into the current 2.0.1
classes; DEXPI 2.0 is converted on load. Relationship exports query those actual
loaded objects identically across inputs, without reconstructing links lost by a
loader or guessing unresolved IDs. Source-file omissions remain omissions.
