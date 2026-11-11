# pyDEXPI workflows

Recipes for common tasks. Each shows the minimal correct call. Runnable versions of some are in
[examples/](examples/). The Python blocks are executed by
`tests/test_docs/test_skill_workflows.py` in separate namespaces on a fresh reference P&ID.
The test supplies the shorthand model, object ids, common imports and temporary file aliases
used below.

## Load a file

```python
from pydexpi import load_xml_file, load_json_file, load_model

model = load_xml_file("plant.xml")  # DEXPI XML or Proteus — detected automatically
model = load_json_file("plant.json")
model = load_model("plant.xml", format="xml", source_type="file")  # both keyword-only
```

In-memory variants: `load_xml_string`, `load_xml_bytes`, `load_json_string`, `load_json_bytes`.

Proteus routing is by content, not extension: root element `PlantModel` with a
`PlantInformation` child means Proteus, and `OriginatingSystem="PlantEngineer"` on that
`PlantInformation` selects the PlantEngineer dialect loader. Failures raise (`FileNotFoundError`, `ValueError`,
`TypeError`) — they never return `None`. A strict load refusing a DEXPI 2.0 document raises
`ConversionRefusedError`, a `ValueError` (below).

### Process models need `strict=False`

A DEXPI **process** model (`conceptualModel` is a `ProcessModel`, not a `PlantModel`) loses most of
its content at the default strictness, because real process files omit `Identifier` — which the
DEXPI model marks mandatory on 144 classes — on most objects that require it (78 % and 92 % in the
two examples in `data/dexpi_process_examples/`; a strict load builds 146 objects from the CO2
terminal, against 959 with `strict=False`, and refuses Tennessee Eastman, below):

```python
model = load_xml_file("process.xml", strict=False)
```

Leniency also drops individual values the DEXPI model cannot represent — a `Description`
serialised as a plain string, a unit literal the model does not have — keeping the object
without them instead of discarding it. Both kinds of loss are recorded as errors, never silent. An
object that still cannot be built once those values are gone is rejected as usual, and
`strict=True` waives nothing.

To see what was waived, use `load_xml_with_report`. It routes like the other XML loaders
(DEXPI, Proteus, PlantEngineer) but returns the loader's error registry entries with the model:

```python
from pathlib import Path

from pydexpi.loaders.public import load_xml_with_report

report = load_xml_with_report(Path("process.xml").read_bytes(), strict=False)
model = report.model
for entry in report.errors:
    print(entry.level, entry.message)
```

The JSON loaders take the same `strict` (`load_json_file(path, strict=False)`, and
`load_model(..., strict=False)` for either format), because a model loaded leniently and saved as
JSON still omits `Identifier`, so reading it back strictly drops those objects again.
`load_json_with_report` is the JSON twin of `load_xml_with_report`. On the command line it is
`--lenient` (`pydexpi info process.xml --lenient`), which prints only a count of the loader's
entries, to stderr; a strict load prints that count too when the loader recorded an error.
`scripts/inspect_model.py` takes `--lenient` too.

A process object is named by its `identifier` (`get_tag`, `get_display_name`: `"Stream (13)"`),
with its free-text `label` as a caption fallback only. Identifiers repeat in real files -- a
stream and a material state both called `"1"` -- so `get_by_tag` can raise `AmbiguousTagError`
where `find_by_tag` lists every match.

Two reference process models live in `data/dexpi_process_examples/`, each with a `README.md`; both are DEXPI 2.0. For a native DEXPI 2.0.1 process model that loads strictly,
use `data/dexpi_2_0_1/synthetic_process.xml` (or `.json`), a small generated one: a
`MaterialState` composing its `phases` and `state`, percent fraction vectors in the template's
component order, a delegated port pair and `PortNodePosition` anchors. Its neighbour
`data/dexpi_2_0_1/reference_pid.xml` is the DEXPI 2.0.1 release's own reference P&ID.

A 2.0.1 composition's fractions are `PhysicalQuantityVector`s in `RatioUnit`, in the order of the
template's component list. Whether a value fits its property -- a vector or a
scalar, a Double or an Integer, which unit enumeration -- is
`pydexpi.toolkits.qualified_values.check_value(owner, attribute, value)`; `validate` reports a
misfit (`pydexpi_qualified_value_binding`, MANDATORY) and a fraction vector that does not sum to
its unit's full scale (`pydexpi_composition_fractions`, RECOMMENDED).

### DEXPI 2.0 files are read as 2.0.1

pyDEXPI's classes are DEXPI 2.0.1, and both process examples (and most files around) are DEXPI
2.0. Every loader converts a 2.0 document as it reads it -- XML whose `<Import>`s name
`models/2.0.0/`, JSON without a root `"dexpiVersion"` -- and reports each step in the registry
(`load_xml_with_report`): renamed properties (`MoleFractiona`, `Capacity` on a `StoringEnergy`)
and units (`PercentageUnit` → `RatioUnit`) at INFO, and the model-level `compositions` and
`materialStateTypes` 2.0.1 removed moved into the owners that name them (a `Composition` into its
`MaterialStateType`, which a `MaterialState` owns through `state` or `phases`). What 2.0.1 cannot
hold without copying or dropping data is refused by a strict load and converted by a lenient one:

```python
from pydexpi.loaders.compat import ConversionRefusedError

try:
    model = load_xml_file("TennesseeEastman-vpd-enriched.xml")
except ConversionRefusedError as refusal:  # ten Compositions no MaterialStateType claims
    print(refusal.problems)
report = load_xml_with_report(Path("TennesseeEastman-vpd-enriched.xml").read_bytes(), strict=False)
dropped = [entry.content for entry in report.errors if entry.content]  # each orphan's XML
```

An object two owners share is copied for the second with new ids (`<id>__<owner-id>`), a WARNING
giving the mapping; one nobody claims is dropped with an ERROR whose `content` is its XML or JSON.
pyDEXPI writes only 2.0.1: XML `<Import>`s and a JSON `"dexpiVersion": "2.0.1"`.
`pydexpi convert --fast` refuses a 2.0 source; convert without it.

## Summarise a model

```python
from pydexpi.toolkits.model_summary import summarize_model

summary = summarize_model(model)
summary.to_dict()  # counts by kind, plus equipment_tags / instrument_tags
summary.equipment[0]  # SummaryEntry(id=..., type="Tank", tag="T4750", display_name=...)
summary.instrument_tags  # ["PI-4712.01", "PICSA-4712.02", ...]
```

This is what `pydexpi info`, the MCP server's `get_model_summary` and `scripts/inspect_model.py`
report, so their numbers agree. Counts cover the whole model, and a process model reports its
process steps and its process connections, in all (`process_connection_count`) and by kind
(`stream_count`, `energy_flow_count`, `information_flow_count`). `TaggedPlantItem` is the base class
for "equipment" -- it catches pumps, tanks and heat exchangers alike -- and piping components
include valves.

To collect the objects themselves, walk the model by type:

```python
from pydexpi.pydexpi_classes.plant import instrumentation, processEquipment
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

equipment = get_all_instances_in_model(model, processEquipment.TaggedPlantItem)
instruments = get_all_instances_in_model(model, instrumentation.ProcessInstrumentationFunction)
```

Filtered variants when a type alone is too coarse. Mind the argument order — the class filter
is the last parameter, not the second:

```python
from pydexpi.toolkits.model_toolkit import (
    get_instances_with_attribute,
    get_instances_with_condition,
)

pumps = get_instances_with_condition(
    model,
    lambda o: type(o).__name__.endswith("Pump"),
    dexpi_classes=(processEquipment.TaggedPlantItem,),
)
by_tag = get_instances_with_attribute(model, "tagName", "P4711")
has_any_tag = get_instances_with_attribute(model, "tagName")  # target_value omitted: any value
```

## Search by tag, type or id

```python
from pydexpi.query import search_objects

page = search_objects(model, "P4711")  # all fields, ranked
page = search_objects(model, "pump", scope="types", limit=10)
page.total  # count before pagination
for m in page:  # SearchMatch
    m.object_id, m.label, m.dexpi_type, m.matched_field, m.score
```

`scope` is one of `"all" | "tags" | "types" | "ids"`. Fuzzy matching is on by default
(`fuzzy_threshold=0.6`); pass `0.0` for exact-only. Empty queries and unknown scopes raise
`ValueError`.

For more than one query against the same model, build the engine so the index is reused:

```python
from pydexpi.query import QueryEngine

engine = QueryEngine(model)
engine.get_by_tag("P4711")  # raises ObjectNotFoundError / AmbiguousTagError
engine.find_by_tag("P4711")  # list, no raising
engine.neighbors(pump.id)  # ConnectionResult
engine.find_paths(src, dst)  # PathResult
engine.find_on_sheet("Sheet 1")
```

Call `engine.invalidate()` after mutating the model — the index and graph are cached.

Instrument numbers can name both a loop and its members. Use
`engine.get_by_tag("4712.01", type="ProcessInstrumentationFunction")` to select the instrument
or `type="InstrumentationLoopFunction"` for its loop. Printed tags such as
`engine.get_by_tag("PI-4712.01")` are additional lookup keys. Multiple members sharing a number
or a printed tag remain ambiguous; use `find_by_tag` to inspect every match.

## Walk a line in flow order

`segment.items` is list order, which an imported file does not promise to be flow order, and a
line split at a tee or a valve is several segments. `piping_toolkit.run_items` walks the line for
you, read-only:

```python
from pydexpi.toolkits import piping_toolkit as pt

segment = next(
    s
    for system in model.conceptualModel.pipingNetworkSystems
    for s in system.segments
    if s.id == "PipingNetworkSegment9"
)
items = pt.run_items(model, segment)  # [PipeTee2, PipeTee1, PipeTee3, BallValve4, ...]
pt.run_items(model, items[2])  # from an item on the line: itself first, then downstream
pt.run_items(model, segment, across_segments=False)  # this segment only
pt.segment_chain(segment)  # one segment, pipes and items interleaved: [Pipe, PipeTee]
```

At a segment's end the walk carries on into the segment that starts on the **same item and the
same node object** the previous one ends on. At a tee that is the run outlet; a branch leaves from
another node, so it is never followed (walk a branch by starting at its segment). It stops at the
line's end -- an open end, a nozzle, an item nothing continues from -- and does not list nozzles or
other items outside every segment. Where the model does not say which way the run goes (two
segments on one node, a segment end that names no node, a cycle) it raises
`PipingTraversalException` rather than guess. It raises too where a segment leaves an item of at
most two nodes from another node than the one the line ends on: that item is no branch point, so
stopping there would return the line cut short. A segment that is not one chain raises
`DexpiCorruptPipingSegmentException`. `examples/load_and_inspect.py` prints the longest line. The
MCP server's `describe_run` tool is the same walk, as ids.

## Build plant graphs

```python
from pydexpi import get_graph, get_graphs

g = get_graph(model, graph_level="process")  # nx.MultiDiGraph
gs = get_graphs(model, embed_shape_usage=True)  # GraphSet
gs.complete, gs.process, gs.conceptual  # three independent graphs
```

- `complete` — everything, minus the top-level structural nodes.
- `process` — piping nodes collapsed; signals and instrumentation become edges.
- `conceptual` — `process` plus equipment internals and nozzles removed.
- `process_flow` — for a DEXPI *process model* (a BFD): one node per process step, step detail,
  instrumentation activity and instrumentation system, the control loop that composes activities
  (`kind`, `parent` for a sub-step or detail, `instrumentationSystemActivity` for an activity),
  one edge per stream,
  energy or information flow, **keyed by the connection id**, so two streams between the same
  steps stay two edges. Ports fold into the edge (`sourcePort` / `targetPort`); quantities split
  (`massFlow`, `massFlow_unit`). An edge's `kind` says what it is: `ProcessConnection`,
  `hierarchy` (a sub-step or detail under its step, or an activity under its instrumentation
  system; `attr_name` says which), `delegation` (a port handed down to a
  sub-step: `superPort`, `subPort`) or `measures` (a measurement to the step, detail or
  connection it measures). Not part of a `GraphSet`, and empty for a P&ID.

```python
flow = get_graph(process_model, graph_level="process_flow")
for u, v, key, data in flow.edges(keys=True, data=True):
    if data["kind"] == "ProcessConnection":
        print(key, data["label"], u, "->", v)  # key == data["connectionId"]

# Follow a stream into the sub-step its port is delegated to: the delegation edge runs from the
# step the stream ends at to the step inside it, and names the delegated port as `superPort`.
feed = flow["Step_Feed"]["Step_Column"]["Stream_Feed"]
inside = [
    (inner, data["subPort"])
    for _, inner, data in flow.out_edges("Step_Column", data=True)
    if data["kind"] == "delegation" and data["superPort"] == feed["targetPort"]
]
assert inside == [("Step_StrippingSection", "Port_StrippingFeed")]

# What each measurement measures. A measured connection is an edge itself, so the measurement
# has one edge to each of its two ends, with the connection's id in `measuredConnection`.
measured = [
    (activity, target, data.get("measuredConnection"), data.get("measuredProperty"))
    for activity, target, data in flow.edges(data=True)
    if data["kind"] == "measures"
]
assert measured == [("Activity_PT101", "Detail_FeedTray", None, "pressure")]
assert flow.nodes["Detail_FeedTray"]["pressure"] == 1.2  # the property the edge names

# A control loop (an InstrumentationSystemActivity) is a node with its own identifier and label,
# and the activities it composes are its out-neighbours.
loops = {
    data["identifier"]: (data["dexpiLabel"], list(flow.successors(loop)))
    for loop, data in flow.nodes(data=True)
    if data["kind"] == "InstrumentationSystemActivity"
}
assert loops == {"PIC-101": ("Feed tray pressure loop", ["Activity_PT101"])}
```

The three graphs in a `GraphSet` are independent; mutating one does not affect the others.
`embed_shape_usage=True` attaches graphical position data (`x` / `y`) as node attributes.

Every graph carries properties of its own in `g.graph`, the networkx graph-attribute dict:

```python
g.graph["graph_level"]  # "process" -- also on every node and every edge
g.graph["projectName"]  # model provenance, lifted from MetaData
g.graph["drawingNumber"]  # ... and from the EngineeringModel root
```

The level is stamped on nodes and edges too, so it survives into backends that have no graph
object. Provenance has to live here because `MetaData` nodes are deleted at every abstraction
level. `pydexpi.toolkits.model_provenance.get_model_provenance` is the extractor; pass
`stamp_graph_level=False` to `get_graph` / `get_graphs` to opt out of the level stamp.

## Where a symbol sits, and what it overlaps

`diagram_toolkit.object_extent(model, obj)` is the sheet area an object's symbol occupies: its
shape's own extent, mirrored, scaled, rotated and placed as a renderer draws it, as an axis-aligned
`Bounds`. It is the symbol only: labels, data tables and the groups of other objects nested under it
(an equipment's nozzles) are left out. `None` means the object is not drawn, or is drawn with a
shape that has nothing measurable (the placeholder).

```python
from pydexpi.toolkits.diagram_toolkit import object_extents

extents = object_extents(model)  # one walk of the diagram, every drawn object
footprint = extents.get(pump.id)
clash = [
    other.tagName
    for other in model.conceptualModel.taggedPlantItems
    if other is not pump
    and footprint is not None
    and (box := extents.get(other.id)) is not None
    and footprint.intersects(box.expanded(5))  # 5 units of clearance
]
```

`object_extent(model, obj)` answers for one object; for many, `object_extents` walks the diagram
once instead of once per object. `symbol_extent(group)` does the same for a representation group,
and `usage_extent(shape_usage)` for one placed symbol. A primitive drawn directly into a symbol's
group (as Proteus imports draw them) is measured where it is; a usage both of whose scales are
below the renderers' hidden threshold occupies nothing. An elliptic arc counts what it draws, the
box of its sweep (`ellipse_arc_extent`), not its whole ellipse: a vessel's dished heads do not
widen its footprint. Nothing here places or moves anything: choosing a free spot is the caller's.

## Validate

```python
from pydexpi.validation.default_validator import validate
from pydexpi.validation.engine import LevelOfRecommendation

issues = validate(model)
blocking = [i for i in issues if i.level_of_recommendation is LevelOfRecommendation.MANDATORY]
```

A model loaded with `strict=False` reports every object it kept without a mandatory attribute
(`pydexpi_mandatory_attribute_has_value`), one MANDATORY issue each: on a process export that is
most of its objects, the `identifier` they omit. For a custom rule set, build a
`ValidationEngine(rules)` directly and call `.validate(model)`.
Rules live one per module under `pydexpi/validation/rules/` — see `AGENTS.md` before adding one.

To validate some objects rather than a model — after an edit, say — use `validate_objects`.
It runs only the rules that can be evaluated from a single object and **names the ones it
could not run**, so a partial check is never mistaken for a clean model:

```python
from pydexpi.validation import validate_objects

result = validate_objects([edited_segment])
result.issues  # from the rules that ran
result.unchecked_mandatory_rules  # dangling refs, duplicate objects, instrument in two loops
result.validated_object_ids  # exactly what was inspected
```

## Export

```python
from pydexpi.exports import (
    export_neo4j_csv,
    export_graphml,
    export_tables,
    export_llm_context,
    get_all_tables,
)

paths = export_neo4j_csv(
    model, "out/", graph_level="process"
)  # {"nodes": ..., "relationships": ...}
export_graphml(model, "out/plant.graphml", graph_level="complete")
export_tables(model, "out/plant", lists=["equipment", "line"], formats=[".xlsx", ".csv"])
export_tables(model, "out/tabellen", language="de")  # translated headers + sheet names
export_llm_context(model, "out/plant.txt", mode="topology")
tables = get_all_tables(model)  # dict[str, pd.DataFrame], incl. "valve"
```

Excel tables are styled industrial documents by default: a title block from the model metadata
sits above the data, so the header is *not* in row 1 — read it back with
`pd.read_excel(path, header=table_style.data_header_row(provenance, language, styled=True) - 1)`
or export with `styled=False`. The combined JSON gets the metadata under a top-level
`"metadata"` key; CSV stays plain. Valves have their own list — the piping-component list
excludes them unless `include_valves=True`.

For identity-based engineering joins, the supplementary tables preserve model IDs
and relationship roles. Display tags/numbers are not unique keys. Nullable IDs and
unresolved endpoints have explicit diagnostics; inspect them before joining.
MCP agents should use `get_complete_piping_inventory()` for this inventory: all
valve families and off-page connectors are included without flags. Omit `limit`
or fetch every page; use the separate connection and nozzle tools for those objects.

```python
from pydexpi.exports import (
    get_equipment_dataframe,
    get_nozzle_dataframe,
    get_piping_component_dataframe,
    get_piping_connection_dataframe,
    get_instrument_relationship_dataframe,
)

inventory = get_piping_component_dataframe(model, include_valves=True, include_connectors=True)
nozzles = get_nozzle_dataframe(model)
equipment = get_equipment_dataframe(model)
nozzle_equipment = nozzles.merge(
    equipment, left_on="parent_equipment_id", right_on="id", suffixes=("_nozzle", "_equipment")
)
connections = get_piping_connection_dataframe(model)
relationships = get_instrument_relationship_dataframe(model)
flow_rows = relationships[relationships["category"] == "flow"]
records_json = relationships.to_json(orient="records")  # retains nulls and parallel line IDs
```

Neo4j CSVs use `:ID` / `:LABEL` / `:TYPE` headers. Plain Cypher `LOAD CSV` does not understand
those — import them with `neo4j-admin database import`, or `LOAD CSV` plus APOC. The module
docstring in `pydexpi/exports/neo4j_export.py` spells out both.

Node identity there is `[<id_namespace>:]<graph_level>:<sourceId>` — namespaced by abstraction
level always, and by a caller-supplied model namespace on request — so several levels *and*
several independent models can share one database:

| column | value | use |
|---|---|---|
| `:ID` | `dexpi-model-123:process:CentrifugalPump1` | unique across levels and models |
| `sourceId` | `CentrifugalPump1` | the raw DEXPI id — join across levels on this |
| `graph_level` | `process` | filter: `MATCH (n {graph_level: 'process'})` |
| `id_namespace` | `dexpi-model-123` | caller-supplied; separates independent models — omit for a single model |

Index and match on `:ID`, not `sourceId`. `sourceId` is not globally unique — pass
`id_namespace=...` when loading independent models, and when you do, cross-level joins should
match **both** `id_namespace` and `sourceId`. pyDEXPI never generates the namespace; the caller
owns it. GraphML writes bare ids by default and can carry the same composite identity on request
— `export_graphml(..., namespace_ids=True, id_namespace=...)`, or `pydexpi export-graph
--namespace-ids`, which also applies to `--format json`; both compose it through
`exports/export_identity.namespaced`, so the ids match the Neo4j `:ID` exactly and the raw id
travels as `sourceId`. Provenance does not reach Neo4j at
all — both are documented in the module docstring.

Diagram exports (`svg_export`, `png_export`, `pdf_export`) work off `model.diagram`, not the
graph, and do nothing useful if the model carries no diagram data. PNG and PDF need the optional
`png` / `pdf` extras.

## Copy, clean, remove

```python
from pydexpi.toolkits.model_toolkit import (
    clone_model,
    reassign_ids_in_model,
    remove_object_from_model,
    remove_references_to_objects,
    combine_engineering_models,
)

copy = clone_model(model)  # deep copy — ALSO reassigns every id
reassign_ids_in_model(model)  # fresh ids in place

# Raw removal: the object must have no required incoming references, and its drawing stays.
from pydexpi.pydexpi_classes import PlantSystem

obj = PlantSystem(plantSystemName="Temporary")
model.conceptualModel.plantStructureItems.append(obj)  # unreferenced and undrawn
objs = [obj]
remove_object_from_model(model, obj)  # also clears references to it
remove_references_to_objects(model, objs)  # clear refs to many objects in ONE model traversal
```

`clone_model` reassigning ids is the sharp edge here: any id you captured before the clone will
not resolve against the copy. If you need a copy that preserves ids, use
`model.model_copy(deep=True)` instead.

## Compare revisions, review in Git

Different things; do not substitute one for another (docs/mkdocs/versioning.md):

```python
import copy

from pydexpi.diff import id_diff
from pydexpi.versioning import model_to_projection

new = copy.deepcopy(old)
new.conceptualModel.taggedPlantItems[0].tagName = "P-NEW"
diff = id_diff(old, new)  # what differs -- diff.model_dump(mode="json")
diff.semantic_only()
id_diff(old, new, scope=[pump.id])
text = model_to_projection(new)  # stable review text for Git
```

- `id_diff` needs **stable ids**: revisions of one model (kept as JSON, or changed copies). Two
  loads of one XML file re-mint ids; compare those with `PyDexpiDiffEngine(TagEquality())`.
- A diff is strict JSON however it is serialized (`model_dump_json`, `model_dump(mode="json")`).
  A NaN or an infinity a loaded model holds is written as the string `"NaN"`, `"Infinity"` or
  `"-Infinity"`. A JSON document written by `JsonSerializer` spells it the same way;
  `model_digest` does not depend on the spelling.
- A Git text diff of the projection is for reading; never parse it back. Load both revisions and
  diff the models instead.

## CLI

```bash
pydexpi info plant.xml
pydexpi convert plant.xml -o plant.json          # format inferred from the extension
pydexpi svg plant.xml -o plant.svg [--pretty]
pydexpi export-table plant.xml -o out/plant -f xlsx -l equipment [--language de] [--plain]
pydexpi export-graph plant.xml -o out/plant.graphml -l process -f graphml
pydexpi diff old.json new.json [--json] [--semantic-only] [--exit-code]
pydexpi git-projection model.json [--id-policy source|all] [--no-graphics]
```

`python .claude/skills/pydexpi/scripts/inspect_model.py plant.xml --json` gives the `info`
summary plus validation counts as machine-readable JSON.
