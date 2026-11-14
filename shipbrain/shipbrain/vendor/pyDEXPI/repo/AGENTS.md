# pyDEXPI — conventions for AI-assisted development

> Short, living notes for agents working on pyDEXPI.  
> When a convention changes, update this file.

This is the single source of truth. `CLAUDE.md` is a one-line import of this file — edit here,
not there. `AGENTS.md` is the vendor-neutral name and is read by Devin, Cursor, Codex and
Copilot as well as Claude Code.

This file is about **changing** pyDEXPI. For **using** it — load, inspect, search, validate,
export — see the skill in [`.claude/skills/pydexpi/`](.claude/skills/pydexpi/), which
carries task recipes (`workflows.md`), runnable examples (`examples/`), and a standalone model
inspector (`scripts/inspect_model.py`).

## What pyDEXPI is

pyDEXPI is an engineering toolkit for [DEXPI](https://dexpi.org/) models: loading, analysis,
validation, visualization and export, through Python, CLI, and MCP interfaces. Generated Pydantic classes provide the model foundation; the runtime and engineering
tools build on it.

The classes implement **DEXPI 2.0.1** (`pydexpi.DEXPI_SPEC_VERSION`), and everything pyDEXPI
writes declares 2.0.1: the `<Import>` URIs of DEXPI XML, a root `"dexpiVersion"` in JSON. It reads
DEXPI 2.0 by converting the parsed document to 2.0.1 before building it. See *Generated
classes* and *Reading DEXPI 2.0* below.
The typical flow is:

```
DEXPI XML/JSON/Proteus/GraphML  →  loaders  →  EngineeringModel  →  toolkits  →  export/query/validation
```

The public loading API is `pydexpi.loaders.public` (`load_xml_file`, `load_json_file`,
`load_model`, `get_graph`, …) and the public label helpers are `pydexpi.get_display_name`
(objects), `pydexpi.enum_value_label` (enum values and units) and `pydexpi.attribute_label`
(attribute names).

## Layout

| Path | Purpose |
|---|---|
| `pydexpi/pydexpi_classes/` | **Generated** Pydantic DEXPI 2.0.1 classes, by [pyDEXPI-builder](https://github.com/process-intelligence-research/pyDEXPI-builder). Do not hand-edit; the two hand-written modules below are the exception, and a fix to a generated class belongs in the builder. See *Generated classes*. |
| `pydexpi/pydexpi_classes/pydexpi_classes.py` | Monolithic generated class file. |
| `pydexpi/pydexpi_classes/_spec_info.py` | Generated: `DEXPI_SPEC_VERSION` and `MODEL_URIS`, which specification the classes are. Read by the XML export's `<Import>`s and `pydexpi.DEXPI_SPEC_VERSION`. |
| `pydexpi/pydexpi_classes/_base.py` | Hand-written, never generated: `make_id`, `PyDexpiBaseModel`, `PyDexpiDataTypeBaseModel` (cycle-safe `__eq__`/`__repr__`/`__str__`, `__deepcopy__`, value equality and hashing for data types, the unit hook). The generated file imports it; the generator ([pyDEXPI-builder](https://github.com/process-intelligence-research/pyDEXPI-builder)) never writes it. |
| `pydexpi/pydexpi_classes/unit_resolution.py` | Hand-written. Resolves unit spellings; imports nothing from pyDEXPI. |
| `pydexpi/pydexpi_classes/{core,plant,process}/` | Same classes split by domain (re-exports); the module a class sits in is its DEXPI package (`process/diagram.py` holds `Process.Diagram.PortNodePosition`). |
| `pydexpi/loaders/` | Serializers: XML, JSON, Proteus, GraphML, and `public.py`. |
| `pydexpi/loaders/compat/` | Reading a document written for an earlier DEXPI version: `dexpi_2_0_to_2_0_1.py` converts a parsed DEXPI 2.0 tree to 2.0.1. See *Reading DEXPI 2.0*. |
| `pydexpi/toolkits/` | Analysis helpers (graph, piping, model, display names, labels, quantity formatting, …). |
| `pydexpi/exports/` | Output formats: Excel/CSV tables, GraphML, Neo4j, SVG, PNG, PDF. |
| `pydexpi/query/` | Search and indexing over a model. |
| `pydexpi/validation/` | Validation engine and rules. |
| `pydexpi/diff/` | Semantic diff between models. |
| `pydexpi/versioning/` | `model_to_projection` (stable review text for Git), and the composition index it reads a model by. Depends on `diff`. |
| `pydexpi/syndata/` | Synthetic P&ID generation. |
| `pydexpi/hashing.py` | Canonical-JSON hashing, for order-insensitive model equality, and `model_digest`, the exact-state fingerprint. |
| `pydexpi/cli.py` | Typer CLI for common workflows; plug-ins add commands through entry points. |
| `pydexpi/mcp_server/` | MCP server over the public API (extra `mcp`, command `pydexpi-mcp`); extensions add tools through entry points. See *The MCP server*. |
| `data/dexpi_training_test_cases/` | DEXPI's 35 verified reference P&IDs, vendored byte-identical. Do not reformat. |
| `data/dexpi_2_0_1/` | Native DEXPI 2.0.1 documents: the release's reference P&ID, vendored byte-identical (do not reformat), and the synthetic process fixture with its generator. See *Sample data and the corpus sweep*. |
| `tests/` | Mirror of the `pydexpi/` package structure. |
| `scripts/` | Entry points for checks / tests. |
| `.claude/skills/pydexpi/` | Agent Skill: how to *use* the library. Examples run in CI. |
| `docs/mkdocs/` | The published documentation. |
| `tests/fixtures/built/` | Saved DEXPI documents some tests load (`tests.fixtures.load_fixture`), kept byte-stable. |

## Commands

From a clean checkout:

```bash
pip install -e ".[dev,export,cli,mcp]"   # the extras CI installs; without them their suites skip
pre-commit install
./scripts/test       # pytest ./tests
./scripts/lint       # ruff format + ruff check --fix on pydexpi tests scripts .claude
./scripts/check      # the same set, read-only: what CI rejects
./scripts/typecheck  # mypy over the allow-list in pyproject.toml
```

Pre-commit runs `ruff-format` and `ruff` (with `--fix`) on staged Python files under
`pydexpi/`, `tests/`, `scripts/` and `.claude/` — the `files:` regex in
`.pre-commit-config.yaml`, not every staged file. `./scripts/lint` and `./scripts/check` cover
the same four paths, so all three agree.

**CI** runs one leg -- Ubuntu, Python 3.14, with coverage and the type check -- on every pull
request, and nothing on a push to `main` (commented out to halve the bill). Windows and Pythons
3.12 and 3.13 run only on demand: `gh workflow run main.yml --ref <branch>`
(or Actions -> CI -> Run workflow). Run it before a release, and on any change to file I/O,
paths or line endings, where Windows is the platform that differs. After a batch of merges,
`gh workflow run main.yml --ref main` checks what landed together. The manual run's primary leg
also runs the skill's recipes a second time, on the DEXPI 2.0.1 release's reference P&ID
(*Sample data and the corpus sweep*).

`./scripts/lint` is not idempotent — it formats and *then* fixes, so one pass can still leave
work for `./scripts/check`. Run lint twice, then check.

`./scripts/typecheck` with no arguments checks exactly the modules allow-listed under
`[[tool.mypy.overrides]]` in `pyproject.toml`; everything else is parsed for its types but its own
diagnostics are suppressed until it is cleaned and added. Given a path,
`./scripts/typecheck pydexpi/exports` reports what bringing that module onto the checked surface
would cost, without changing anything on disk.

It runs in CI on the primary matrix leg only and is **non-blocking** (`continue-on-error: true` in
`.github/workflows/main.yml`, with the count in the step summary): the diagnostics are visible on
every PR without a mypy release turning the repository red overnight. Deleting that one line is
the promotion to a required check, so do not treat a green CI as meaning the type check passed —
run it.

## Conventions

### Generated classes: DEXPI 2.0.1, regenerated, never edited

`pydexpi/pydexpi_classes/` is pyDEXPI-builder's output for **DEXPI 2.0.1** (`main.py --spec
2.0.1`, the builder's default), from the release's `Dexpi.xmi` and model files, which the builder
vendors with their provenance (`data/dexpi_xmi_files/2.0.1/PROVENANCE.md` there). 594 classes and
enumerations; what changed from 2.0 is inventoried, item by item against DEXPI's changelog, in the
builder's `docs/inventory-2.0-to-2.0.1.md`.

**Regenerating** is mechanical, and nothing else may change a generated file:

1. in the builder, `python main.py --spec 2.0.1 --output <tmp>`;
2. copy `<tmp>/pydexpi_classes/` over this package. The builder never writes `_base.py` or
   `unit_resolution.py`, so both stay as they are;
3. `ruff format pydexpi/pydexpi_classes` with this repository's settings: the builder's output is
   not formatted, and formatting is the one step between the two. Nothing else
   touches the files;
4. confirm with the builder's `python scripts/compare_with_pydexpi.py --pydexpi <this checkout>`,
   which formats both sides the same way and must report no difference, and name the builder
   commit in the commit message. It defaults to `--spec 2.0.1` and runs from any
   directory without installing the builder.

`tests/test_pydexpi_classes/test_dexpi_2_0_1.py` pins what a regeneration must keep: the version,
the 594 classes, the attribution and the three deviations, and that `NOTICE` names every deviation
the classes carry.

**Attribution.** The classes are an adaptation of the DEXPI Specification 2.0.1, (c) 2026 DEXPI
(DEXPI e.V.), CC BY 4.0. The generated module header and the package docstring carry the
attribution, and `NOTICE` carries it for the distribution, with the list of changes. When a
regeneration changes the specification version or the deviations, update `NOTICE` with it.

**`_spec_info.py`** is generated next to the classes: `DEXPI_SPEC_VERSION` (`"2.0.1"`) and
`MODEL_URIS` (each DEXPI model's URI). The XML export writes its `<Import>`s from it
(`xml_serializer.default_imports`) and `pydexpi.DEXPI_SPEC_VERSION` re-exports it; do not hard-code
a DEXPI version or a model URI anywhere else. It is not pyDEXPI's package version
(`attribution.get_version`), and the JSON class URIs
(`https://pyDEXPI.org/schemas/pydexpi_2_0/<Class>`) do not carry it either: they are pyDEXPI's
schema namespace, unchanged across DEXPI versions.

**The binding metadata** is in each field's `json_schema_extra`, beside `attribute_category`:

- `unit_type`: the unit enumeration the specification binds a quantity to, on a `PhysicalQuantity`
  data attribute and on a `QualifiedValue`-bound composition alike (`QUANTITY_UNIT_ENUMS` is
  derived from it; see *Physical quantity units*);
- `value_types`: what the `value` of a `QualifiedValue`-bound composition may be
  (`["PhysicalQuantityVector", "Undefined"]` for `Composition.moleFractions`, `["int",
  "Undefined"]` for `Compressing.numberOfStages`);
- `is_ordered`: the list is ordered;
- `spec_deviation`: the field deviates from the specification (below);
- `dexpi_name`: the DEXPI name of a renamed field.

**Three deliberate deviations from the specification** are declared, each with its reason and
evidence, in the builder's `SPEC_DEVIATIONS` table, which fails the build when the specification no
longer matches what an entry was written against. A deviation is a builder change, never a hand
edit here:

- `QV-VALUE-UNION`: `QualifiedValue.value` is `float | int | PhysicalQuantity |
  PhysicalQuantityVector | Undefined`, required -- the union of what the bindings give it, where
  the specification declares `PhysicalQuantity | Double`. See the trap below;
- `COMPONENT-ORDER`: `ListOfMaterialComponents.component` is ordered, as the specification's text
  says and `Composition`'s fraction vectors rely on;
- `PORT-SUBREFERENCE`: **`Port.subReference` is a reference, not the composition the
  specification declares**. A delegated port is a port of its sub-step, owned by that step's
  `ports`; the parent step's port lists it in `subReference`, and it points back with
  `superReference` (a reference in the specification too). Owned through `subReference` as well, it
  would be owned twice, which `ModelCompositionTreeUnique` reports as MANDATORY. Both producers we
  have write it as a reference: the CO2 example as `<References property="SubReference">`, which
  the XML loader reads; bpmn2dexpi as `<ObjectReference>` children of `<Components>`, which the
  loader reads as references (see *Reading DEXPI 2.0*).

**A wrong class description is the specification's, and stays**. The docstrings are DEXPI's
descriptions as written, and two contradict their class: `GeneratingDCPower` has the description
of `GeneratingACPower` ("produces alternating current"), and `Flaring` is described as a
`SupplyingThermalEnergy` process and derives from `ProcessStep`. Both reach a reader through the
`label_description` of a graph node and the MCP server's `describe_dexpi_class`. They are not
corrected here, and no deviation is declared for them: a deviation changes the model, a
description changes nothing a document holds, and a hand edit is reverted by the next
regeneration. They are erratum 8 of `data/dexpi_process_examples/ERRATA.md`, which holds the
texts as filed with DEXPI. `test_generated_text.py` pins the two sentences, that no other two generated
classes share a description, and that no other process step's description opens by naming a class
it does not derive from.

### Docstrings and style

- Numpy docstring convention (see `pyproject.toml`).
- Ruff line length is 100.
- Tests mirror `pydexpi/`: `pydexpi/toolkits/display_name.py` →
  `tests/test_toolkits/test_display_name.py`.

### Graph collapses keep parallel engineering edges

P&ID node-to-edge collapses remove only redundant `composition`/`reference` edges
between endpoints, in either direction. Parallel and reverse engineering edges stay;
I08V01 pins all four signal lines and six conceptual edges. Never widen the
cleanup to every parallel edge.

### Source / target direction in piping

Two vocabularies meet here, and most confusion comes from mixing them. From @DPGoldstein:

- **In node / out node** is a property of an **item**: the node through which the process
  medium enters, or leaves, that item.
- **Source node / target node** is a property of a **connection** (a pipe, or a segment): the
  node it draws from, and the node it discharges into.

So the two line up head to tail: a connection's **target** node coincides with an item's **in**
node, and a connection's **source** node coincides with an item's **out** node.

DEXPI itself fixes no index convention — other arrangements are legal.
`PipingConnectionConvention.IN_NODE_0_OUT_NODE_1` (**node 0 = in, node 1 = out**) is the
common one because it is what Proteus defaults to, and the piping toolkit picked it for the
same reason. It is a default, not a rule the format enforces, so read node indices from the
convention in force rather than assuming them.

**Proteus does carry endpoint indices, and pyDEXPI now reads them.** A segment's `FromID` /
`ToID` name the item and the sibling `FromNode` / `ToNode` name the port on it, **1-based into
the item's parsed `nodes`** — `PipingNetworkSegmentParser._resolve_external_node` subtracts one
and registers an ERROR when the index falls outside them.

Both halves of that matter. `item.nodes` is **not** the raw `<Node>` list: `parser_factory`
builds a `PipingNode` only from `Type="process"` entries, sending `Type="signal"` to the
instrumentation path and dropping untyped entries such as `Nozzle-1-DefaultNode` entirely. So the
index counts process nodes, and nothing else.

The training corpus cannot establish that, which is the trap. Every item there carries exactly
one untyped node, at position 0, so "1-based into the process nodes" and "0-based into the raw
list" name the same node for all 108 references: the same answer by coincidence, not by
agreement. Checked against the **drawn geometry** across every Proteus file in `data/` — 150
endpoint references whose segment has a centreline, matching a node position to within 0.05:

| reading | geometric matches |
| --- | --- |
| 1-based into the item's process nodes (what the parser does) | **130** of 150 |
| 1-based into all typed nodes | 130 of 150 |
| 0-based into the raw `<Node>` list | 102 of 150 |

`data/exports/xvisual/pump_example_v2.xml` is what separates the first from the last: its `PC_*`
components carry four process nodes and no untyped one. `Pipe_5` declares `ToNode="1"` and ends
at x = 121.8736, which is `PC_4_0` (x = 121.875) to within 0.002; read 0-based it would be
`PC_4_1`, **1.25** away. `Pipe_7` declares `FromNode="2"` and starts at x = 123.125, which is
`PC_4_1`; read 0-based it would be `PC_4_2`, **2.58** away and not even on the pipe's axis —
`PC_4_2` is the component's south node.

The middle row ties only because all 64 items that carry both kinds list their signal nodes after
all their process nodes, so no index in any file distinguishes the two. Do not read that tie as
licence to widen the rule: the parser counts process nodes, and a file that interleaves them
would tell the two apart.

Beware that the vendor's node ids encode a *0-based* ordinal, so `PC_4_0` being "node 0" makes
the wrong reading look right. `test_v2_endpoint_indices_are_one_based_into_the_parsed_nodes` pins
the geometry instead. Before the fix the parser read both attributes and
discarded them, which is where the folklore that Proteus cannot express this came from.
What Proteus genuinely lacks is a way to say so for a *pipe's* own source and target, which is
why the ordering convention above still does that job. Many documents omit the attributes anyway —
`test_training_test_cases.py` shows which — so a segment with unset endpoints is normal and not
by itself a parse failure.

**A segment's own source/target nodes invert this at the boundary, and that is not a bug.**
The meaning depends on what the segment ends in:

| The segment ends in… | its `targetNode` is… | index |
| --- | --- | --- |
| a pipe | the target node of that final pipe, i.e. an **in** node of the item beyond it | 0 |
| an item | the main **out** node of that final item | 1 |

and symmetrically for `sourceNode` at the start. A node is one port, so a pipe attaches to it at
most once: `pydexpi_piping_node_single_connection` reports a node two connection ends name, a
pyDEXPI convention rather than DEXPI compliance, and `piping_toolkit.node_holders` is the one
answer to "is this port taken".

**A line in flow order is `piping_toolkit.run_items`; one segment is `segment_chain`**.
`segment_chain` is the one walk of a segment's items and connections by `sourceItem`/`targetItem`
identity; do not write a second one. `run_items` crosses from a segment into the one that starts on the **same item and
the same node object** it ends on, which is what makes it follow a tee's run and not its branch.
Never pick the continuation by node index: tee C1 (`PipeTee2`) in `data/reference_pid.xml` carries its
run on node 0. Where the model leaves the choice open it raises `PipingTraversalException` rather
than guess, and the MCP server's `describe_run` reports that as an error. It also raises rather than
stop where stopping would cut a line short: segments leave the end item, none on the end node, and
the item has no more than two nodes, so it is no branch point. `PipeReducer-1` in training case
`C03V04` is that case, because the Proteus loader gives the segment ending there the reducer's
inflow node; a walk that stopped there dropped the off-page connector beyond it unannounced.

### The vendored DEXPI TrainingTestCases are a coverage map, not a smoke test

`data/dexpi_training_test_cases/` holds the 35 verified reference P&IDs from
[TrainingTestCases](https://gitlab.com/dexpi/TrainingTestCases), pinned at commit `a23d61e2` and
**byte-identical to upstream** — do not reformat or re-serialize them. Provenance, licence
(CC BY 4.0) and per-file SHA-256 are in that directory's `README.md`. They are vendored rather
than pulled in as a submodule because CI checks out with no `submodules:` input, so a submodule
would silently collect zero tests on every run.

The point of this corpus is that each file isolates one feature — `P01` is a pipe between two
nozzles and nothing else, `E13`/`E14` are a tank plus a plant hierarchy, `I01`–`I15` walk
instrumentation feature by feature. So `tests/test_loaders/test_training_test_cases.py` pins
**per-file** numbers (objects, error counts by level, conceptual graph size, how many segments
carry endpoint nodes, round-trip stability) in an explicit `CASES` table rather than globbing the
directory and asserting "nothing raised". A glob asserts nothing; the table is what makes a
regression visible and tells you *which* feature moved.

Those numbers are **current behaviour, not correct behaviour** — several of them record data
pyDEXPI loses today, and the module docstring names the defect behind each one.
When you fix one,
update its rows in the same commit, so the diff shows exactly what was recovered. Do not relax a
row to make a change pass.

Two things about that file are easy to get wrong:

- **Error counts are environment-sensitive, so `_load` pins the environment.** The Proteus
  parser wraps attribute parsing in a broad `except` that records the exception in the
  `ErrorRegistry`. Under the suite-wide `filterwarnings = ["error"]` a *Python warning* raised in
  there is therefore promoted into an extra **registry error**, and because `warnings`
  deduplicates per code location, whether it lands depends on whether an earlier test in the
  session already tripped it — `C01V04` used to score 60 or 61 for exactly that reason (the
  `ForwardRef._evaluate` deprecation, now fixed; the parser resolves annotations through
  `typing.get_type_hints`). The trap is the mechanism, not that one warning: `_load` loads under
  `simplefilter("ignore")` so the counts describe the document and nothing else, and a new
  warning anywhere under that `except` would otherwise reintroduce it.
- **A test that must observe a Python warning has to run out of process.** For the same
  deduplication reason, `test_generic_attribute_parsing_is_warning_free` shells out to
  `python -W error`; in-process it passed for the wrong reason, because the corpus had already
  been loaded.

`data/C01V04-VER.EX01.xml` used to sit at the top of `data/` as a lone reserialized copy of `C01`;
it now lives in this directory with upstream's bytes, and `test_integration_proteus_serializer.py`
pins what it parses to: **1574 objects and 31 non-INFO registry entries** (it was 1505 and 83
before the shape and endpoint fixes).

### Diagram coordinates are Y-down

The canonical coordinate space for `Diagram` graphics (and the DEXPI-native XML/JSON
fixtures like `data/reference_pid.xml`) is **Y-down**, like SVG — `SvgRenderer.to_svg_y` is
deliberately an identity function. Proteus/XMpLant files use the opposite, mathematical
convention (origin bottom-left, Y-up), so the Proteus loader flips every drawing coordinate
at load time in `proteus_parser/drawing_normalization.py`: sheet-space `y → minY + maxY − y`,
shape-catalogue-local `y → −y`, arc angles `start', end' = −end, −start`. Rotations are
already stored negated by the position parser (`(360 − atan2(…)) % 360`) and need no
further change. Do not add a second flip in the renderer — that was the pre-May-2026
arrangement, and combined with the Y-down fixtures it mirrors DEXPI-native renders.

### Process models always contain a required-reference cycle

DEXPI Process (2.0 and 2.0.1) makes `Stream.source` / `Stream.target` and `Port.connectorReference`
*required* references **to each other**. Every process model therefore contains a cycle, and no
ordering composes every object with its references already available. This is a permanent property
of the format, not a quirk of a particular file, so `TreeReferenceLoader._extract_composition_chain`
must always tolerate cycles.

It does so by separating the two kinds of dependency that share one dict:

- **compositional** (parent → child, from `get_child_builders`) form a tree and can never cycle;
  they are honoured unconditionally.
- **required-reference** (from `_extend_dependencies_with_required_refs`) may cycle. When only
  these are left unsatisfied, one is cut: the object is built with `model_construct`, its
  unresolved references recorded in `ElementBuilder._deferred_required_refs` and filled in by
  `establish_references` — which is why that pass handles required references too, not just
  optional ones. `validate_assignment=True` on `PyDexpiBaseModel` means the late assignment is
  still validated.

Two invariants here are easy to break. The cut point must be chosen from an **insertion-ordered**
structure — a plain `set` makes the loaded model depend on hash ordering between runs. And the
`model_construct` escape must stay scoped to *absent* attributes (`_missing_attributes_only`); a
blanket `except ValidationError` would make whether an invalid object is rejected depend on where
the cycle happened to be cut.

No plant fixture caught this because `data/reference_pid.xml` and `data/C01V04-VER.EX01.xml` are
both `PlantModel`s, which have no such cycle. `tests/test_loaders/test_process_model_loading.py`
pins it on a synthetic three-object model that does not depend on the large examples.

### Reading DEXPI 2.0: convert the parsed tree, in one place, and report every step

pyDEXPI reads DEXPI 2.0 and writes only 2.0.1; there is no 2.0 export. A 2.0 document is converted
by `pydexpi/loaders/compat/dexpi_2_0_to_2_0_1.py` on its **parsed tree** -- the lxml tree, the
decoded JSON dict -- in `AbstractTreeReferenceSerializer.prepare_document`, the hook every document
load passes through: `load_from_string`/`_bytes`/`_stream`, `load`, so every `pydexpi.load_*`, the
CLI and the MCP load tools (`tests/test_loaders/test_compat/test_entry_points.py` holds each to
it). `JsonSerializer.dict_to_model`, which reads single values -- subtrees, not documents -- is never
converted; Proteus never comes here, its parser builds 2.0.1 directly. The loader runs the hook
after resetting its registry, so the conversion's entries are the load's own.

- **The version a document is.** XML: its `<Import>` URIs (`models/2.0.0/` is 2.0). JSON: the root
  `"dexpiVersion"`, and a document without one is 2.0, because no JSON pyDEXPI wrote before has
  one. A 2.0.1 document is built as parsed. An XML document declaring no version, or one pyDEXPI
  does not know, is read by its content: converted, with a WARNING that the version was inferred,
  when it holds a construct only 2.0 has; otherwise it reads the same either way and nothing is
  reported. That is also why a 2.0 document with nothing to convert -- the reference P&ID, every
  P&ID so far -- loads with no new entry, and no P&ID pin moved.
- **What changed is data.** The module's tables (`PROPERTY_RENAMES`, `ENUM_CLASS_RENAMES`,
  `OWNERSHIP_CHANGES`, `REMOVED_CONTAINERS`, `CHANGED_KINDS`) are what everything read from 2.0
  is migrated by; do not add a second list. Renames are INFO; `Capacity` is renamed on the
  `StoringEnergy` family only (`StoringMaterial` and `TransportingEnergy` keep theirs).
- **Strict refuses; lenient copies or drops, and says so.** An object two owner slots claim (2.0
  shares by reference, 2.0.1 composes in one owner), one no owner claims, a reference into a
  shared object, a *blocked* `State` reference (from a state that already composes a state type;
  2.0.1 holds one), a `MeasuredVariable` (a `QualifiedValue` in 2.0, an enumeration in 2.0.1) and
  a composed `Port.SubReference` (pyDEXPI's 2.0 classes composed sub-ports, its 2.0.1 classes
  refer to them) cannot be converted without copying or dropping data. Strict registers one CRITICAL entry
  listing all of it, whose exception is a `ConversionRefusedError` (a `ValueError`), and the
  serializer returns None; the public loaders raise it, the CLI prints it and exits 1, the MCP load
  tools answer `conversion_refused`. Lenient copies the shared object for each owner after the
  first (WARNING with the id mapping), keeps outside references on the original (WARNING), and
  drops the rest with an ERROR whose `ErrorRegistryEntry.content` holds the dropped object as
  serialized when dropped (renames applied, with what an earlier step placed in it) -- no drop is
  silent. A reference to a type the state already composes, under the 2.0 `phase` or the 2.0.1
  `phases`, is redundant rather than shared: dropped with an INFO. "No drop is silent" covers the
  conversion's own drops. A child the conversion *moves* into a parent leaves with that parent if
  the loader then rejects it for its own defects: a strict load of bpmn2dexpi refuses each of its
  12 `MaterialStateType`s over a string `Description` and so loses the 12 `Composition`s moved into
  them, with an INFO for each move (a lenient load keeps all 12). The parent's ERROR names what
  it takes along: the entry for an object the loader does not build -- its class unknown,
  its validation failed -- and the WARNING for a composition field its class does not have each
  end `Not loaded with it: the N object(s) composed under it -- ...`, the built objects below it
  by the id the document gives them (ten at most, then a count) and the id-less counted by class
  (`ElementBuilder._lost_with`). The cap is a real loss of detail on a large subtree: a strict
  load of the CO2 terminal refuses `TransportingFluids1` with 121 objects under it, names ten
  and counts 50 more that no other entry names (pinned in `test_process_model_loading.py`). Those objects were built before their parent and stay in the
  object registry, held by nothing. The walk stops at a child that was not built itself, whose own
  entry carries its list, and the number of entries does not change. The lenient drop says it
  too: when `_compose_without_unusable_values` takes a *built object* out of a composition, its
  `Loaded without them` entry ends with the same sentence for that object and what is under it
  (`_builders_of` maps the removed values back to their builders by identity). A lenient load of
  bpmn2dexpi drops 19 sub-steps from `subProcessSteps` of six steps that way; before, the entry
  named the field alone, and the dropped object's own entry read as if it had been loaded. A
  dropped data value has no builder and adds nothing. So an object the conversion
  reports as moved is in the model or named by an ERROR, which
  `test_nothing_the_conversion_moved_is_lost_unnamed` holds every process file to.
- **Repeated `<Data>` of a list field are one list.** DEXPI XML may give one data
  attribute in several sibling `<Data>` elements, one value each: bpmn2dexpi writes every value
  of its 12 fraction vectors in its own `<Data property="Values">`. For a list field
  `DexpiXmlDeserializationElement.get_data_attributes` reads them all, in document order
  (`_extract_all_attribute_elements`), so `uuid_MS_S1_MST_Composition` reads `[99.99, 0.01, 0, ...]`
  % where R2 read its last value, `0.0`. A single-valued field holds one value: the last is read,
  and `RepeatedDataReportingElement` / `ElementBuilder._report_repeated_data` register one ERROR
  per attribute with the unread elements as its `content`. Whether a field is a list is the
  generated class's say: `MaterialTemplate.PhaseLabel` is `list[str]` in 2.0.1, so its repeats in
  bpmn2dexpi and the corrected CO2 file are values, not a conflict. No corpus file repeats a
  single-valued field. This is not specific to 2.0, but the conversion is what lets bpmn2dexpi's
  vectors load at all.
- **`<ObjectReference>` in `<Components>` is a reference.** The DEXPI XML schema lets a
  `<Components property="X">` hold `<ObjectReference object="#id"/>`: an object named there, not
  composed. bpmn2dexpi writes `Port.SubReference` that way, 18 times, and pyDEXPI's classes make
  that property a reference (`PORT-SUBREFERENCE`), so `get_reference_attributes` reads such
  elements as references -- for any field: one that is not a reference is then reported by the
  reference pass rather than dropped silently. `get_composition_attributes` skips a `<Components>`
  that holds only `<ObjectReference>`s. Before R3 the 18 links were dropped silently while the
  field was a composition, then reported as invalid compositional attributes.
- **The copy** takes the whole owned subtree; every object with an id gets `<id>__<owner-id>`, made
  schema-safe and suffixed on a clash by `xml_serializer.schema_safe_id`, the rule the export's id
  mapping uses. References inside the copy follow it. Compositions are placed before state types,
  so a state type moved or copied takes its composition along. The same document converts to the
  same ids every time, and in XML and JSON alike.
- **A `Role` written by older pyDEXPI gets its class back.** JSON only, and the one step that
  repairs a pyDEXPI defect rather than a DEXPI change. `Role.Uri` was once the field `uri`
  and shadowed the class's URI (see the `ClassVar` trap), so the writer put the *attribute's*
  value where a role's class goes: `"uri": null`, or the `Uri` itself, repeated under `data`. The
  class is known from where the object sits -- `ConceptualModel.roles` is `list[Role]` and `Role`
  has no subclass -- so `SHADOWED_CLASS_KEYS` names that property, and an entry there whose class
  key *is* the attribute's value (null or absent when `data` has no `uri`, equal when it has) is
  given the `Role` URI, and its `data.uri` the field name `uri_`: INFO, in a strict load too,
  since nothing is lost. An entry naming anything else there is not what pyDEXPI wrote and is left
  for the loader to report. A document declaring `dexpiVersion` was written after that and never
  comes here. `tests/test_loaders/pre_517/` holds documents the old code wrote; never regenerate
  them. This is **not** a loader fallback ("the one class a property admits"): that would be
  leniency for every document, which ADR-0001 says to route through the two existing helpers.
- **An owner with no block to compose in.** JSON only. The conversion places what an owner
  claims in its `composition` block; if a string or a list stands there, `attach` used to replace
  it and report only the move. That is a drop the conversion makes, so it follows the rule above:
  strict refuses (a problem naming the owner, what was to be placed and the content), lenient
  drops it with an ERROR whose `content` is what stood there. `null` and an absent block hold
  nothing. Every *other* part that is not what the format expects is left exactly as it is for
  the loader (*Traps*, "Anything reached before the `ErrorRegistry`"), which reports it the same
  in a 2.0 and a 2.0.1 document; do not make the conversion refuse those too. That includes the
  copy: `rewrite_references` keeps a reference that is `null` (what `explicit=True` writes for
  an unset single reference; it raised an `IndexError`) and a target that is no string.

**The version marker.** `JsonSerializationElement.export_to_string` writes `"dexpiVersion":
"2.0.1"` first in every JSON *document*, on both `convert` routes; `get_dict` / `model_to_dict`,
which value records and `hashing.model_digest` read, never carry it, and `canonical_json_hash`
serializes with `declare_version=False`. Neither hash may depend on it: stored digests do
(`test_hashing.py` pins both). `pydexpi convert --fast` rewrites a document
without building a model, so it refuses a DEXPI 2.0 source, naming the version it found, rather
than declare 2.0.1 over 2.0 content.

### Real process files omit mandatory attributes; `strict=False` exists for them

`Identifier` is mandatory (1..1) on 144 generated classes (136 in DEXPI 2.0), including every
`ProcessStep`, `Port` and `Stream` — yet both independent process models in
`data/dexpi_process_examples/` omit it on 410 of the 523 objects whose class requires it (78 %) and
on 158 of 171 (92 %), every port among them; the eight classes 2.0.1 added to the list occur in
neither file. A strict load builds 146 objects from the CO2 terminal, against 959 with
`strict=False` (47 of its 109 process steps, no port and no stream). It refuses Tennessee Eastman
outright, whose ten orphan `Composition`s DEXPI 2.0.1 has no owner for (*Reading DEXPI 2.0*); a
lenient load builds 843 (124 strict and 839 lenient on the 2.0.1 classes before the conversion, 146
and 873 on the 2.0 ones). Neither lenient count is the whole file, which holds 987 and 876
`Object`s respectively: the 28 and 3 that no setting builds sit under class or attribute names the
generated model does not have, and Tennessee Eastman's other 30
are the ten orphans with their values, each reported with its content. Hence
`DexpiXmlSerializer(strict=False)` and
`load_xml_*(..., strict=False)` build the object with the attribute absent and record the omission
as an error. The same switch reaches every other way a model is loaded: `JsonSerializer(strict=)`
and `load_json_*` / `load_model(..., strict=False)` (JSON keeps the omission, so a model loaded
leniently and saved as JSON needs it again to be read back), the MCP load tools' `strict`, and
`--lenient` on every CLI command that loads a model. The default stays strict everywhere.

Leniency covers two things, and both are reported to the `ErrorRegistry` rather than silently
accepted:

- an **absent** mandatory attribute — the object is built without it;
- a **value the model cannot represent** — that value is dropped and the object is kept
  (`_compose_without_unusable_values`).

The second exists because one unusable value otherwise costs a whole object, which is a bad trade
for a document that is right about everything else: a `Description` serialised as a plain string
discards the component it describes, and a `QualifiedValue` whose value has no matching type is
discarded with its qualifiers. Removal is as narrow as the error allows — a failure reported
at `("ports", 3, ...)` drops item 3 and keeps the rest of the list, so one bad child does not take
its siblings with it.

One absent mandatory attribute is **derived** rather than left absent, because DEXPI's own
semantics fix its value: a delegated port's `ConnectorReference`. A port with a `SuperReference`
stands in for its super port inside a sub-step and takes part in the super port's connection
(never as its source or target), but the specification says nothing about the delegate's own
reference, and the CO2 terminal export leaves it out on every one of its 11 delegates. A lenient
load builds such a port through `_missing_attributes_only` like any other, and after the reference
pass `ElementBuilder.derive_absent_references` gives it the connection of the first port up its
`SuperReference` chain that has one, with **one WARNING per port** naming the super port and the
connection, in place of the two ERRORs an absent reference costs. A delegate none of whose super
ports has a connection keeps none, with an ERROR saying so (3 of CO2's 11); the file's other 33
ports without a connector are no delegates, so nothing can be derived and they stay reported. A
strict load derives nothing: the port is discarded like any object missing a mandatory attribute,
and the error says it is a delegate and what a lenient load would do. This is no third leniency
mechanism in ADR-0001's sense -- the object is still built by `_missing_attributes_only`; only the
absent value is supplied, from the model -- and it covers exactly this one reference.

What it is **not** is a general validation bypass. Under `strict=True` nothing is waived at all,
and even under `strict=False` an object that cannot be built once its unusable values are gone is
still rejected. Widening this further — accepting objects that fail for reasons no single
attribute explains — would make the loader's output stop meaning anything.

Validation reports every attribute such a load leaves absent through the MANDATORY,
object-scoped `pydexpi_mandatory_attribute_has_value`, one issue per object, so it flags
every lenient load, as it should: those objects *are* non-compliant. An absent attribute is set
to `None` past validation (in `model_fields_set`, not missing from `__dict__`), a value its type
refuses; `base_model_utils.absent_required_attributes` finds them, and code that writes such a
`None` past validation must not expect a report.

The generator reads `Identifier` right: the published DEXPI 2.0.1 model declares it 1..1 on
`Port`, `ProcessStep` and the others (`Process.py:698`, `:1085` at tag `V2.0.1`). Whether that
multiplicity is what DEXPI intends, given that no producer honours it, is a question for DEXPI.

### Graph-level properties

Exported graphs carry properties beyond nodes and edges, in `G.graph` — networkx's
graph-attribute dict, which `nx.write_graphml` serialises as `<data>` children of `<graph>` and
`nx.node_link_data` puts under a `"graph"` key.

- **Model provenance** (project, drawing, revision, originating system) is written once in
  `GraphLoader.parse_dexpi_to_graph` and extracted by
  `pydexpi.toolkits.model_provenance.get_model_provenance`. It has to live there: the graph walk
  starts at `conceptualModel`, so `EngineeringModel` attributes are out of reach, and every
  abstraction level deletes the `MetaData` node.
- **`graph_level`** is stamped on the graph *and on every node and every edge* by
  `graph_loader.stamp_graph_level`, called from `build_level` **after** abstraction so that
  synthesised nodes and edges are covered. The node/edge copies are what make the level
  filterable in a graph database, which has no graph object to query.

- **A node's `label` is its class name, so a DEXPI `label` attribute is `dexpiLabel`.** Every
  process step, stream and material carries a free-text DEXPI `label`, and `_add_nodes` writes the
  class name over the `label` key -- which `get_nodes_by_label` and the collapse rules read.
  (Neo4j's node `:LABEL` comes from `labels`, the class's inheritance chain, and falls back to
  `label` only when that is empty; an edge's `:TYPE` is the edge's own `label`.) The DEXPI attribute
  is moved to `graph_loader.DEXPI_LABEL_ATTRIBUTE` (`"dexpiLabel"`) first; until then it never
  reached GraphML or Neo4j. Import the constant rather than hard-coding the key.

- **Physical quantities are split, not flattened.** A quantity-typed DEXPI attribute `foo`
  becomes *two* node attributes: `foo`, the numeric value as a `float`, and `foo_unit`, the
  `PhysicalQuantityUnit` literal as a `str` — `upperLimitDesignPressure = 1.0` alongside
  `upperLimitDesignPressure_unit = "Bar"`. `graph_loader.UNIT_ATTRIBUTE_SUFFIX` is the single
  definition of the suffix; import it rather than hard-coding `"_unit"`. The split is what lets
  GraphML declare `attr.type="double"` and Neo4j store a number, so `WHERE c.upperLimitDesignPressure > 5`
  works; the old `"1.0 Bar"` string discarded that at the earliest possible point and nothing
  downstream parsed it back. No collision risk — no DEXPI data-attribute name ends in `_unit`.

  Three things this deliberately does **not** do. The value is **not normalised**: it is exactly
  what the model carries, in the model's unit, so a cross-record range query is only sound when
  `foo_unit` matches (canonical/SI values and quantity-kind validation are follow-ups).
  A `PhysicalQuantityVector` -- a `Composition`'s fractions, in `QualifiedValue.value` -- is
  split too, under its own name so that `value` stays a number wherever it is one:
  `values` holds the values as **one JSON array, in order** (position `i` is the template's
  `i`-th component; a graph attribute holds scalars only, and `Undefined` is `null`), and
  `values_unit` the unit literal (`graph_loader.vector_attribute_name`; a vector in another
  attribute `foo` would be `foo_values`). Until R3 the whole vector was a JSON blob under `value`,
  a `string` under the key that is a `double` everywhere else. And the unit here is the enum
  *literal* (`"Metre"`),
  whereas `table_export` and label materialization render the typeset symbol (`"m"`) from
  `toolkits/quantity_format.py`; the two vocabularies are separate and are not unified.

`graph_loader.GRAPH_LEVELS` is the single level→builder mapping. `GraphLoaderPipeline` and
`loaders.public.get_graph` / `get_graphs` all route through `build_level` — do not re-introduce a
second mapping. `graph_loader.GraphLevelName` is the `Literal` every `graph_level` argument is
annotated with, the CLI's `GraphLevel` enum lists the same names, and the MCP tools check against
`GRAPH_LEVELS` itself; tests keep the first two equal to the registry's keys.

**`process_flow` is a process model's level, built rather than collapsed** (P2b).
`complete`, `process` and `conceptual` abstract a P&ID -- `process` is the *P&ID's* process level,
not a `ProcessModel` view -- by collapsing copies of the raw graph. `process_flow`
(`build_process_flow_graph`) builds a new graph from the raw graph's typed nodes and
composition/reference edges instead. When it was written the collapses lost parallel edges
outright (fixed since, `_remove_parallel_edges` now takes only the redundant
`composition`/`reference` edges between the two endpoints, see *Graph collapses keep parallel engineering edges*). The lasting
reason is that the collapse rules encode a P&ID: a process port is no nozzle, a delegated port
stands in for another, and a step's place in the hierarchy is no piping containment. Do not
rebuild it from the collapse functions.

- **Nodes:** every `ProcessStep` at any depth, every `ProcessStepDetail` and every
  `InstrumentationActivity`, whether or not it owns ports, and every
  `InstrumentationSystemActivity` (below). A detail or activity that owns no port can end no
  connection, and it used to be no node: its id in `graph.graph["portlessElements"]` was all
  the graph had of it, so the CO2 export's four measurements, which own no port and only name the
  step or connection they measure, were in no node list an LLM or a graph database was given. The
  list stays, naming the same ids, for whoever reads it. `kind` names which of the four a node is,
  and `label` stays the concrete class. `parent` is the owning step (a sub-step's, a detail's) and
  has a matching hierarchy edge; an activity has `instrumentationSystemActivity` instead, because
  no step owns it, and that has a matching hierarchy edge too, from the system's node.
- **Edges:** one per `ProcessConnection`, from the owner of its `source` port to the owner of its
  `target` port, **keyed by the connection id** and carrying it again as `connectionId`; `label` is
  the connection class, so it is the Neo4j relationship type. A connection between two ports of one
  step is a self-loop. The other three kinds of edge are keyed by a composed string, each with a
  `.` in it: a hierarchy edge `"<attr_name>.<child id>"` (labelled `composition`; from a step to a
  sub-step or detail, or from an instrumentation system to an activity), a delegation
  edge `"delegation.<delegate port id>"`, a measures edge `"measures.<activity id>.<measured
  id>"`. The DEXPI XML schema's `id-pattern` admits no `.`, so in a schema-valid document none can
  replace a connection edge; an id from JSON may hold one, and `_add_new_edge` raises rather than
  let `add_edge` overwrite a taken key, which networkx does silently. `kind` tells the four apart
  (`ProcessConnection`, `hierarchy`, `delegation`, `measures`).
- **Ports collapse into the edge, with everything they say** (`_port_attributes`). `sourcePort` /
  `targetPort` are the ids; the port's data, what it composes and what it references follow under
  the same prefix and the attribute's name -- `...PortIdentifier`, `...PortNominalDirection`,
  `...PortMaterialTemplateReference`, `...PortPersistentIdentifiers` -- and its roles as names
  under `...PortRoles`. A port is no node, so what the edge leaves out is gone: the first version
  kept the id, the identifier and the roles, and dropped the direction of all 283 CO2 ports. Its
  `connectorReference` is not repeated, being the edge. The ends are the connection's own
  `source`/`target`; `Port.connectorReference` is not consulted.
- **A port that ends no edge is listed on its owner, in `unconnectedPorts`**
  (`UNCONNECTED_PORTS_ATTRIBUTE`, `_unconnected_port`): a JSON array of `{"port": id, ...}` with
  the port's data, what it composes, the ids it references and `roles`, under the port's own
  attribute names. So what a port says is on the graph in exactly one of two places, a
  connection's edge or this list (`delegatedPorts` and a delegation edge name delegates again, by
  id only), and a port is never a node unless no node owns it. "Folded into the edge" alone was
  true only of ports that end one: 48 of the
  corrected CO2 file's 283 end none (its 11 delegates and 37 others; 45 of 273 as delivered),
  and 34 of them occurred nowhere in the graph, `nominalDirection` and all. bpmn2dexpi has none.
  `test_every_port_of_a_real_document_is_an_edges_end_or_listed_on_its_owner` pins the split.
- **A delegation is an edge of its own kind, beside the attributes that carried it**
  (`_add_delegation_edges`). One per port with a `superReference`, from the node owning the super
  port to the node owning the delegate: `kind` and `label` are `delegation` (so that is its Neo4j
  relationship type), the key is `delegation.<delegate port id>`, and it carries `superPort`,
  `subPort` and `reciprocal`. Until then the link was attributes only, and joining a stream that
  ends at a step's port to the sub-step holding its delegate took a property match, which a Cypher
  path pattern and a graph algorithm do not make. What was decided, and why:
  - *Drawn from `superReference` alone.* It is what `process_hierarchy`'s invariant defines a link
    by, and it is single-valued: a delegate has exactly one edge, and its key is taken once.
    `reciprocal` says whether the super port lists the delegate back in `subReference` (9 of the
    corrected CO2 file's 11, 6 of the 8 the delivered one loads, all of bpmn2dexpi's 18 and the
    synthetic fixture's one). A `subReference` entry no `superReference` answers draws no edge:
    the CO2 file has one, `ShuttingOffFlowB1_XL1` listing a port of the step *above* it, and it
    stays where the listing port is written. The graph shows a link and judges none; the
    invariant's other clauses are `pydexpi_process_port_delegation_consistent`'s.
  - *From the super port's owner to the delegate's*, the way the port is handed down and the way
    the hierarchy edge between the two steps runs. That is fixed by structure and not read from
    `nominalDirection`, which the two ports give differently on 2 of CO2's links and on all 18 of
    bpmn2dexpi's. So it is not the direction of flow, which an outlet's delegation runs against:
    follow a flow by matching the edge's `superPort` (or `subPort`) against the `sourcePort` /
    `targetPort` of the connection edge it arrived by, and take the delegation edge whichever way
    that needs. `test_a_real_flow_is_followed_into_the_sub_step_in_one_hop` is that walk. The
    edge has no `attr_name`, unlike a hierarchy or measures edge: on a raw edge that names an
    attribute of the *source*, and `superReference` is the target's.
  - *The attribute form stays, unchanged:* `delegatedPorts` on the delegate's node, with
    `superPortOwner`; `...PortSuperReference` and the JSON array `...PortSubReference` on a
    connection's edge, which exist only where a connection ends at the port (3 of the CO2 file's
    super ports end none); and, for a delegate that ends no connection, its entry in
    `unconnectedPorts`. Nothing that read them reads anything else now.
  - *A super port no node owns becomes a `Port` node*, as a connection's unowned end does; no
    corpus file has one.

  The corpus has both patterns of delegate, and the edge is there for both: none of the corrected
  CO2 file's 11 ends a connection (each only takes part in its super port's), and every one of
  bpmn2dexpi's 18 ends a connection *inside* its step, another one than its super port ends
  outside it.
- **A measurement is a node joined to what it measures** (`_add_measures_edges`): that is
  the decision on port-less activities, rather than the id list alone. `MeasuringProcessVariable`
  is the only generated class whose references join two elements of this graph
  (`processStepReference`, `processStepDetailReference`, `connectionReference`), so the relation is
  named for it: `kind` and `label` `measures`, from the activity, with `attr_name` the reference
  it is drawn from. A step or a detail is one edge, keyed `measures.<activity id>.<measured id>`.
  A connection is an edge, and an edge cannot end at an edge, so the activity has one edge to each
  of the two nodes the connection runs between, keyed `...<connection id>.source` / `.target` and
  carrying `measuredConnection` and `connectionEnd`: the measurement is adjacent to the stream at
  both of its ends, and a reader that drops attributes still has the stream's id in the key. Two
  edges to two steps do read as "measures both steps" to a consumer that ignores `attr_name`, which
  is the price of not inventing a node for the stream. `measuredProperty` names the property of
  the measured element that holds the value `measuredVariableReference` points at (`pressure`,
  `level`), where that element composes it: a `QualifiedValue` is flattened onto its owner, so its
  id resolves to nothing else in the graph. All five measurements of the corpus name a value their
  measured element composes. A reference to what is no part of the graph (a step that was not
  loaded, an unplaced connection) draws no edge, and the reference ids stay node attributes either
  way, as on an activity that owns ports. An activity naming nothing has no measures edge; its one
  edge is its place under its system, and until that was a node it was an isolated one.
- **An instrumentation system is a node over its activities**
  (`INSTRUMENTATION_SYSTEM_KIND`). An `InstrumentationSystemActivity` is a control loop: it composes
  its activities in `instrumentationActivities`, and only the `ProcessModel` composes it. It was
  once no node. Each activity named it by id in `instrumentationSystemActivity`, and that id
  was all the graph had: the synthetic fixture's `PIC-101` and its label were in no export, and
  "which measurements belong to one loop" (the CO2 export's `PSH` owns `PSHB30` and `PSHL33VA001`)
  was a property match, the kind of join an edge replaced for delegation. What was
  decided, and why:
  - *A node of a kind of its own, not its data flattened onto its activities.* Flattened, the data
    would be repeated on every activity of the loop, a system that composes none would have nowhere
    to go, and the join would still be a property match. The node holds what any node holds: the
    raw graph's attributes (`identifier`, `dexpiLabel`, `description`), what it composes
    (`persistentIdentifiers`) and what it references (`performedRoles` as names,
    `referencedNotes`).
  - *One hierarchy edge to each activity it composes*, shaped as a step's is: `kind` `hierarchy`,
    `label` `composition`, `attr_name` `instrumentationActivities`, keyed
    `instrumentationActivities.<activity id>`. It is the same relation, composition, so it is the
    same kind, and `attr_name` tells the three apart. A consumer that reads every hierarchy edge
    as "a step contains" has to check it (`REAL_DOCUMENTS` pins the split per file).
    `instrumentationActivities` is therefore structure (`_STRUCTURAL_COMPOSITIONS`) and is not
    flattened onto the system, which would repeat one activity's data on the loop or write all of
    them as one `instrumentationActivities_items` blob.
  - *The attribute stays, unchanged, and an activity still has no `parent`:* `parent` names a
    process step. Nothing that read `instrumentationSystemActivity` reads anything else now, and
    the edge and the attribute never disagree, being drawn from one mapping.
  - *Nothing owns a system*, so it has no owner attribute and no edge in, and one that composes no
    activity is an isolated node (no corpus file has one). It is not in `portlessElements`: that
    list names the details and activities that own no port, whose classes let them own one, and a
    system's class has none (`_LISTED_WHEN_PORTLESS`), so listing every system would say nothing.
  - *One edge per activity.* The raw graph keys nodes by id, so two activities of one id under two
    systems are one node, owned by the system that comes first, as the attribute always had it;
    the key is then taken once in the whole graph, and the id is in `sharedIds`. A composed
    object the raw graph could give no class is no node and gets no edge: `add_edge` would invent
    it.

  The CO2 export gives its three systems an id and nothing else (no `Identifier`), so there the node holds a class and a caption and its worth is the structure; the
  synthetic fixture is the file where it carries data.
- **The counts are pinned per file, by kind** (`REAL_DOCUMENTS`, `DELEGATION`,
  `CO2_MEASUREMENTS` and `CO2_LOOPS` in `test_process_flow_graph.py`), nodes / edges: the
  synthetic fixture 7 / 9, the CO2 export 123 / 245 as delivered and 119 / 251 corrected,
  Tennessee Eastman 40 / 43, bpmn2dexpi 60 / 126. Before delegation and measures
  edges they were 6 / 6, 116 / 227,
  112 / 230, 40 / 43 and 60 / 108: the four CO2 measurements as nodes, one edge per delegate
  (1, 8, 11, 0, 18) and the measures edges (1, 6, 6, 0, 0). Before system nodes they were 6 / 8,
  120 / 241, 116 / 247, 40 / 43 and 60 / 126: a node per system (1, 3, 3, 0, 0) and a hierarchy
  edge per activity under one (1, 4, 4, 0, 0). A consumer that counted every edge as a
  connection, or every edge that is not `hierarchy`, has to filter on
  `kind == "ProcessConnection"` now.
- **Composed data is flattened one level onto its owner:** a property holding one
  `QualifiedValue` gives `massFlow` / `massFlow_unit` plus its qualifiers (`massFlow_scope`, ...),
  a vector `massFlow_values` / `massFlow_values_unit`; a property holding several is one JSON array
  under `massFlow_items` and has no `massFlow` at all, because a scalar standing for one of them
  would hide the others. References are ids (role names for `performedRoles`), a JSON array for a
  list-valued field even when it holds one.
- **Defective documents keep their connections visible.** An end whose port nothing owns becomes a
  node of kind `Port` (the CO2 export's unloaded `TransportingFluidsInPiping` steps leave seven); a
  connection with no source or target port is listed in `graph.graph["unplacedConnections"]`
  rather than dropped. A `PlantModel` has no steps, so its `process_flow` graph is empty.
- **An id several composed objects share is flattened onto no owner**, and listed in
  `graph.graph["sharedIds"]`. The raw graph keys nodes by DEXPI id, so such objects are one node
  holding whichever was written last: the raw Tennessee Eastman export gives 35 `QualifiedValue`s 4
  ids, and flattening them put a duty of 65.7 DegreeCelsius on a step whose model says -2140.6 kW.
  An object has one owner in a model, so a node with two incoming `composition` edges is the sign.

**Edge keys reach Neo4j as `edgeKey`**, at every level, where the key is a string: the exporter
iterates `edges(keys=True, data=True)`. Before P2b it dropped keys, so parallel edges were rows
that said nothing about which was which. **Only at `process_flow` does the key name an object**
(the connection; that level's hierarchy, delegation and measures edges have composed keys, whose
parts are in the edge's attributes and need no parsing. A composed key is taken once in the whole
graph as long as no id contains a `.`: `measures.<activity>.<measured>` joins two ids with one, so
activity `M` on step `A.B` and activity `M.A` on step `B` both get `measures.M.A.B`, on two
different node pairs, and nothing raises because a repeat is only refused between one pair. The
DEXPI XML id pattern has no `.`, so only a JSON-loaded or hand-built model can do it; read the
ends and the attributes, never the key, to identify such an edge).
At the P&ID levels it is whatever the collapse keyed the edge by: at `process`
the collapsed object's id, and at `conceptual` also the id of a *nozzle* an edge was stitched
through -- 13 of the reference P&ID's 37 keyed edges, 12 of its 25 pipes among them, with the pipe
in `collapsed_node_id` and the nozzle in `stitched_from`. So it tells parallel rows apart there
and must not be joined on; `test_neo4j_export.py` pins the stitched case. networkx's integer
counter, the key of every plain edge, is no identity and is not written -- written, it made
`edgeKey` a Long on some rows and a String on others. The P&ID rows otherwise did not change
(every name and value is held to the edge's own data), and the raw and `complete` levels, whose
keys are all integers, not at all. GraphML already writes a key as the edge `id` and node-link
JSON as `key`. The LLM-context export's `topology` mode drops every data attribute, so it writes
the edge `id` itself, at `process_flow` only: two streams between one pair of steps were one line
twice, and at a P&ID level `id="Nozzle1"` on a pipe would read as the pipe's name.

The Neo4j exporter namespaces node identity: `:ID = "[<id_namespace>:]<graph_level>:<dexpi id>"`,
with the raw id kept as `sourceId`. Level namespacing is unconditional and reads the level from
the exporter's own argument, never from `graph.graph` — a fallback to the bare id would silently
reintroduce the cross-level collision. The optional `id_namespace` separates *independent models*
in one database; it is caller-owned — pyDEXPI never generates application-level identity. `:` is
reserved as the composite separator and rejected in both the namespace and DEXPI ids at export
time.

Provenance reaches Neo4j only on request: `create_graph_metadata_node=True` appends **one**
synthetic `_DexpiGraph` row carrying every `graph.graph` entry, rather than stamping ~25 constant
fields onto all 212 node rows x 3 levels. Its `:ID` is composed the same way as any other,
so it does not collide across levels, and it carries a `displayName` so the "every node row has a
caption" invariant holds. If the model already contains an object with the id `_DexpiGraph` the
export raises — two rows with one `:ID` would corrupt the import.

The APOC recipe writes the composite `:ID` to a **`nodeId`** property, never to `sourceId`:
`docs/mkdocs/neo4j_export.md` once merged it into `sourceId`, which overwrote the raw DEXPI id
that joins an object across levels.

`exports/export_identity.py` is where that composition lives — `namespaced` and
`validate_id_namespace`, called by *both* the Neo4j exporter and, on request, the GraphML one, so
the two cannot describe the same object with two different identifiers. A second copy of the
rule is a second thing to keep in step; do not write one.

GraphML ids stay **bare by default**: `export_graphml(..., namespace_ids=True)` (and
`pydexpi export-graph --namespace-ids`) opts in, relabels a *copy* of the graph and keeps the raw id
as a `sourceId` node attribute. Passing `id_namespace` without the flag raises rather than silently
writing bare ids. The namespacing cannot move into `graph_loader`: `namespaced` rejects a DEXPI id
containing `:`, so a graph whose node keys were already composite would make every later Neo4j
export of that graph raise.

### Physical quantity units

`PhysicalQuantity.unit` is annotated with `PhysicalQuantityUnit`, which is an **empty** base
`StrEnum` — every member lives on one of its 41 subclasses. Pydantic therefore degrades the
field to an `is_instance_of` check, and without the unit hook no JSON payload could satisfy it: a
quantity could be read but never written from JSON, not even by validating pydantic's own
`model_dump(mode="json")`.

**Unit literals are not unique.** 15 of the 131 collide across subclass enums — `Bar`,
`Pascal`, `Kilopascal`, `Megapascal`, `Millibar`, `PoundForcePerInchSquared`
(`PressureAbsoluteUnit` / `PressureGaugeUnit`), `Inch`, `Micrometre`, `Millimetre`
(`LengthUnit` / `ParticleSizeUnit`), four density literals and two frequency literals. In
`data/reference_pid`, 17 of 51 quantities are `PressureGaugeUnit.Bar`, so this is the common
case. **The class-qualified `"PressureGaugeUnit.Bar"` is the canonical spelling** — the same
one DEXPI XML `DataReference` elements already carry. Nothing may guess between gauge and
absolute pressure; an ambiguous bare literal raises and names the candidates.

- `pydexpi/pydexpi_classes/unit_resolution.py` is the single resolver. It accepts a real
  member, `{"__enum__", "name"}` (what `JsonSerializer` writes), `"<Enum>.<Value>"` and
  `"<Enum>.<MEMBER>"`, and a bare literal when unambiguous. It imports nothing from pyDEXPI
  because `pydexpi_classes.py` calls it — keep it that way, or the import turns circular.
- The hook is a `model_validator` + `model_serializer` pair on **`PyDexpiDataTypeBaseModel`**,
  in the hand-written `pydexpi_classes/_base.py`, which the generated classes import and derive
  from. It has to be on the base model: the annotation is baked into ~526 model fields at import
  time, so nothing attached afterwards can change it, and the base model is the one place that
  covers `PhysicalQuantity` and `PhysicalQuantityVector` at once. It finds the generated
  `PhysicalQuantityUnit` on first use (`_unit_base`), because `_base.py` cannot import the module
  that imports it. The builder never generates `_base.py`, so a regeneration cannot drop
  it; `test_unit_resolution.py::test_regeneration_guard` still pins it.
- `model_dump(mode="json")` emits the **qualified** unit, so the dump round-trips through
  `model_validate`. `model_dump()` (python mode) still yields the live member, which is what
  `graph_loader`, `neo4j_export`, `table_export` and `table_locale.unit_symbol` read. Model
  hashing is unaffected: `canonical_json_hash` goes through `JsonSerializer`, not `model_dump`.
- `pydexpi/toolkits/quantity_units.py` carries `QUANTITY_UNIT_ENUMS`, the map from all 82
  quantity-typed attribute names to the unit enum holding their legal units. It is **derived** from
  the generated binding metadata (`json_schema_extra["unit_type"]`, the unit enumeration DEXPI 2.0.1
  binds each attribute to), not curated: the hand-kept table it replaced disagreed with the
  specification on nine attributes (seven particle sizes are `LengthUnit`, not `ParticleSizeUnit`;
  `FilterUnit`'s two allowable solids concentrations are `RatioUnit`, not `MassConcentrationUnit`).
  `resolve_unit_for_attribute` narrows a bare literal to the attribute's dimension. **Discovery does
  not advertise `legal_units`**: MCP `describe_dexpi_class` lists a property's units from its
  binding (`qualified_values.binding_of(...).unit_type` and the enums below it), exactly what the
  binding admits, because the widening below would offer an absolute pressure where the binding
  admits only a gauge one. The map is a **convenience, never a constraint**: a qualified spelling is always
  resolved against the full hierarchy, so the map cannot reject a unit the model permits. **One
  override is explicit**, `_UNIT_ENUM_WIDENING`: DEXPI binds each pressure to one leaf
  (`upperLimitDesignPressure` to `PressureGaugeUnit`, `differentialPressure` to
  `PressureAbsoluteUnit`), and the map widens both leaves to their shared `PressureUnit` parent,
  because the leaves share all six literals and narrowing would turn a bare `"Bar"` into a guess.
  `spec_unit_bindings()` gives the bindings before widening. The Proteus parser is the one reader
  that consults them for a bare literal, because a Proteus file has no other spelling: `Units="Bar"`
  on `differentialPressure` is read as `PressureAbsoluteUnit.Bar` and on `upperLimitDesignPressure`
  as `PressureGaugeUnit.Bar`, each recorded at INFO (`GenericAttributeParser._assumed_unit`).
  `QualifiedValue.value` carries no binding of its own (its property does) and maps to the root.
  Tests enforce that the map covers every quantity attribute the generated classes declare and that
  no name is bound to two enums.

Note that whole-model `model_dump` / `model_validate` is still not a DEXPI serialization:
pydantic has no discriminator on the class hierarchy, so a round trip degrades every subclass
to its annotated base (`PlantModel` → `ConceptualModel`). Use the loaders. Per-object round
trips, which is what a JSON API does, are exact.

### A quantity value is checked against its property's binding, by one validator

`QualifiedValue.value` is the union of every binding DEXPI uses (`QV-VALUE-UNION`, see *Traps*), so
the class cannot say whether a vector, a scalar, a Double or an Integer belongs, nor which unit
enumeration. The owning field can: `json_schema_extra["value_types"]` (with `"unit_type"` for a
quantity) on every property holding `QualifiedValue`s, and `"unit_type"` on every data attribute
typed `PhysicalQuantity`. `pydexpi/toolkits/qualified_values.py` is **the one validator** that
reads them -- `binding_of`, `check_value`, `check_fractions`, `resolve_unit_for_binding`,
`coerce_value`. Anything that builds or checks a quantity against its property goes through it.
Do not check a binding anywhere else.

- **Shape and unit** (`check_value`): the value's kind is one the binding admits, and a quantity's
  unit is a member of the bound enumeration or below it. A unit that is missing, or no
  `PhysicalQuantityUnit` member at all, is **not** this check's: pydantic rejects it when the value
  is built, and a lenient load reports it. No rule reports it -- VAL-007 was closed
  unmerged -- and if one is added, it and this check must never report one defect. Integer and
  Double are distinct kinds (`<Integer>` vs `<Double>`): a Double where only an Integer is bound is
  reported, but an Integer where a Double is bound is not -- it is a lossless whole-number Double,
  and JSON written by other tools carries one as `5`. A data attribute typed `PhysicalQuantity`
  holding anything but a `PhysicalQuantity` or `Undefined` (only `model_construct` gets one there)
  is a shape problem.
- **Units are never inferred** (`resolve_unit_for_binding`): a qualified spelling is resolved
  against the whole hierarchy and then checked against the binding; a bare literal only within the
  *bound* enumeration. That narrows a pressure, which `quantity_units` deliberately does not: there
  the map is a convenience, here the binding is the constraint, so a gauge-bound property's bare
  `"Bar"` can only be `PressureGaugeUnit.Bar`.
- **Fractions** (`check_fractions`, `Composition.massFractions` / `.moleFractions` only): every
  known value finite and in `[0, full scale]`, summing to the full scale, both within
  `FRACTION_SUM_RTOL = 1e-6` of the full scale, the scale from the `RatioUnit` literal
  (`FRACTION_FULL_SCALE`: 1, 100, 1e3, 1e6, 1e9). An `Undefined` value is a fraction not known:
  the known ones must then only not exceed the full scale. Nothing is ever normalised or
  relabelled; a vector summing to another literal's full scale is reported naming it.

Two rules report it on loaded models, both object-scoped and applied to the *owner*, because a
`QualifiedValue` does not know which property holds it. **`pydexpi_qualified_value_binding`**
(MANDATORY: the binding is the specification's type) checks shape and unit, never fractions; it
finds nothing in any P&ID of the corpus (the 35 training cases, the reference P&ID, xvisual), none
in CO2 or bpmn2dexpi, and three `PressureGaugeUnit.Kilopascal` process-step pressures in Tennessee
Eastman, which DEXPI binds to `PressureAbsoluteUnit`. **`pydexpi_composition_fractions`**
(RECOMMENDED: that fractions add up is physics, not a DEXPI statement) finds Tennessee Eastman's
`Percent` vector summing to 1, and six of bpmn2dexpi's twelve vectors, rounded to three decimals,
summing to 100.001 or 99.999 % -- a thousand times the tolerance, and reported as such rather than
waved through by a looser one.

### Ordered lists are compared by position, everywhere

A list attribute is ordered when reordering it changes what the model says, and
`pydexpi/toolkits/list_order.py` is the single definition (`pydexpi.diff.ordering` re-exports it;
the serializers import it and must not import the diff):

- **DEXPI declares it** -- `is_ordered` in the generated metadata (`is_spec_ordered`): the drawing's
  geometry and z-order (`RepresentationGroup.groups`, inherited by `Diagram`, a type group's
  `elements`, `points`, `innerPoints`, `primitives`, `fragments`), `PhysicalQuantityVector.values`,
  and `ListOfMaterialComponents.component` by the `COMPONENT-ORDER` deviation. A fraction vector is
  read against that component list position by position, so both orders are data.
- **pyDEXPI reads it so** (`ORDERED_BY_CONVENTION`): a `PipingNetworkSegment`'s `items` and
  `connections`, its flow order. `Diagram.groups` and `RepresentationGroup.groups` were listed here
  until 2.0.1 declared them ordered.

Every other list is a multiset. What each comparison does with that, since R3:

| | ordered by DEXPI | ordered by pyDEXPI | unordered |
| --- | --- | --- | --- |
| `==` (pydantic; data types per `_base`) | by position | by position | by position (data types: multiset) |
| `id_diff` | by position, always | with `track_order` | multiset |
| diff JSON (`AttributeChange.ordered`) | in order | in order | references sorted |
| Git projection (format 2) | in order | in order | sorted |
| `canonical_json_*`, MCP `compare_models` | in order | in order | sorted |
| `model_digest` | exact | exact | exact |

`pydexpi diff --exit-code`'s *status* tracks order whatever `--order` says (from a diff of its own,
so what is printed is still the diff asked for), and so agrees with `compare_models` on every
ordered list; an unordered list's order is a difference to `model_digest` alone. Data-type
equality reads the same metadata in `_base._data_type_fields` (it cannot import the toolkit), which
leaves `MultiLanguageString.singleLanguageStrings` the one unordered data-type list;
`test_list_order.py` pins that the two agree.

The canonical JSON changed with this: it sorted every list -- an ordered composition by id, a data
list by `str(hash(x))`, which ordered floats by their hash and data types by a hash salted per
process -- and now keeps ordered lists and sorts unordered data by a key of class and `repr`.
Measured on the corpus models (the 35 TrainingTestCases, the reference P&ID in XML and JSON, both
xvisual files, bpmn2dexpi, and both files each of CO2 and Tennessee Eastman: 44 models), each
loaded leniently and saved once as JSON so ids are fixed: the canonical bytes changed for about a
third of them, and under different `PYTHONHASHSEED`s the old form differed for about a quarter and
the new one for none.
Nothing stored is affected -- `canonical_json_hash` is salted and never persisted.

### Numbers that are not finite: carried exactly

A DEXPI `Double` is an `xsd:double`, whose values include `NaN`, `INF` and `-INF`, and the
specification says nothing against them. So a loaded model may hold one and pyDEXPI keeps it, and
**everything that carries a model value carries one exactly**. No validation rule reports a scalar;
a fraction vector holding one is reported by `pydexpi_composition_fractions` (RECOMMENDED), and
`qualified_values.coerce_value` never *builds* such a value from input. The geometry toolkits
answer a number a document holds in three ways, `pydexpi/toolkits/finite_geometry.py`:

- **A function that measures raises `NonFiniteGeometryError`**, naming the object and the
  attribute: the extents of `diagram_toolkit` (`usage_extent`, `symbol_extent`, `shape_extent`,
  `ellipse_half_extent`, `ellipse_arc_extent`, `annotation_centre`) and the outlines of
  `process_drawing` (`usage_outlines`). It is an `ArithmeticError` and **not a `ValueError`**: a
  caller that turns a toolkit's `ValueError` into a message in the toolkit's words would lose what
  this one carries. A caller that reads such a number itself asks a `require_finite*` helper.
- **A function that classifies answers "none".** Every comparison with a NaN is false, so a
  classification read off one falls through to whichever case comes last. A leg that is no
  finite vector has no axis, a port of a symbol that cannot be measured has no side of its own,
  and an arrow or a line holding such a number is read as on no line.
- **What reports does not fail.** `process_drawing.containment_problems` leaves out a block it
  cannot measure -- `validate` ended in a bare `ValueError` for a process block turned by an
  infinity -- and MCP `describe_item` answers `bounds: null` and `side: null`
  (`process_discovery._measured`). A reply that reports the number itself -- a port's `position`
  -- still writes the float, which `json.dumps` spells as a bare token, which is not valid JSON.
- `find_reference_point` returns the point as the model holds it. A caller that computes about it
  asks `reference_usage` and checks.
- **`x * x`, not `x ** 2`.** A power of a float raises `OverflowError` where the product is an
  infinity, which a finite segment 1e200 long reaches.

A *decision* made on a NaN that writes finite numbers -- a comparison that is false either way --
is invisible afterwards. That is why the measuring functions raise instead of returning a box of
NaNs, and why a new one must too.

**The wire form carries one, as a string.** `value_codec.encode_value` writes a float that is not
finite as `"NaN"`, `"Infinity"` or `"-Infinity"` (`json_serializer.non_finite_token`), at any
depth; its object serializer is `JsonSerializer(non_finite="strings")`, so no second walk over
a serialized object is needed. Everything it returns is strict JSON, which matters because a record of a
value is serialized three ways and they disagreed: `model_dump_json` wrote `null`,
`model_dump(mode="json")` `None` when nested and the float at the top, `json.dumps` a bare `NaN`.
`value_codec.spell_non_finite` spells such a float in a value that is already wire form.

- **Read back by type, like an enum's value or a timestamp.** No decoder exists and none is
  needed: a `float` field reads the token as the number, a `str` field as text. That is sound
  only while no generated class has a field taking both a string and a float;
  `test_value_codec.py` holds a regeneration to it, and reads every token through each of the 24
  fields a float can sit in.
- **Wire equality is the equality to use.** A NaN is not equal to itself, so comparing live values
  told a model from its own reload. `diff.engine.same_value` compares two *unequal* data values in
  their wire form, where two NaNs are equal. Do not "fix" `PyDexpiDataTypeBaseModel.__eq__`
  instead: it would need `__hash__` changed with it.
- **Trap for tests: `math.nan` is one object.** Python containers compare identity first, pydantic
  keeps the float object it is given, and `json.loads` returns one module-level NaN for every
  `NaN` it reads -- so two models built from `math.nan`, or loaded from JSON, hold the *same*
  NaN and compare equal for the wrong reason. A document loaded from XML, an unpickled copy and
  `float("nan")` give distinct objects, which is where the defects showed. A test about NaN
  equality takes its model through XML or builds each NaN afresh.

**The serializers.** DEXPI XML writes `NaN` / `INF` / `-INF` (`xml_serializer._xsd_double`);
Python's `nan` / `inf`, which it wrote before, is rejected by the DEXPI schema, and both
spellings are read.

**A JSON document spells one as the string too (decided).** `JsonSerializer` and
`JsonSerializationElement` default to `non_finite="strings"`, so every JSON pyDEXPI writes --
`save`, `export_to_bytes`/`_stream`, both `convert` routes, MCP `export_json` and `save_model`,
and `model_to_dict` of a default serializer -- is JSON a strict parser reads, and documents and
diffs share one spelling. Python's bare `NaN` / `Infinity`, the default until then, is not JSON:
`JSON.parse` refuses the whole document over one, and Starlette's `JSONResponse` refuses to send
it. What the decision weighed, and what keeps it safe:

- **No digest moved.** `hashing._exact_serializer` and `hashing._json_loader` are pinned to
  `non_finite="constants"` by name, so `model_digest` -- a stored digest -- hashes the same bytes
  as before for every model, one holding such a number included. Never let either follow
  `JsonSerializer`'s default, and never give `_exact_serializer` another spelling;
  `test_non_finite_numbers.py` pins a literal digest computed before strings spelled such numbers,
  and the two settings.
- **Older files load, and newer files load in older pyDEXPI.** Either spelling is read as the
  same model, to the same digest, strict or lenient: the token is read by the float field it sits
  in, which pydantic did before the option existed. `"constants"` stays available for a consumer
  that needs the old bytes.
- **Only documents holding such a number changed**, the ones a strict reader could not open; any
  other document is byte for byte what it was.
- **The cost**: a reader that parses pyDEXPI JSON leniently *without* pyDEXPI (Python's `json`)
  gets `"NaN"` where it got a float, and code that fingerprinted `model_to_dict` of a default
  serializer itself gets another value for such a model. `model_digest` is the fingerprint to
  store.

**The JSON element reads a token by its field, because one reader builds no model.**
`FormatConverter` (`convert --fast`) has only what `JsonDeserializationElement` returns, and a
string was a string: it wrote `<String>NaN</String>` where the validated route writes
`<Double>NaN</Double>`, a value losing its type on this route. `get_data_attributes` now returns the float for
one of the three tokens in a field that holds numbers -- `json_serializer.number_fields(cls)`: the
annotation admits `float` and neither `str` nor `Any` -- and leaves it a string anywhere else
(`tagName = "NaN"`). That is the one decoder, and it decodes only what `non_finite_token` writes;
`"nan"`, `"inf"` and `"1e999"` are still validation's to read. A regeneration that adds a field
taking both a string and a float fails `test_value_codec.py`, and `number_fields` then leaves
that field alone rather than guess. A `DateTime` on the same route still comes out as a `<String>`; the
same place is where it would be read.

### Display names and tags

`pydexpi.toolkits.display_name.get_display_name` is the single source of truth for the
human-readable caption shown in graph exports, search labels (`SearchMatch.label`,
`ObjectDescription.display_name`), validation messages, and the CLI. It uses the type-aware
`DISPLAY_NAME_RESOLVERS` and `GENERIC_TAG_ATTRIBUTES`, then `CAPTION_FALLBACK_ATTRIBUTES`
(`deviceTypeName`, a device type such as "Electric" that many objects share, and a process object's
free-text `label`, so caption hints but never tags), then a non-generated id.

A DEXPI *process* object is tagged by its `identifier`: the last ten `DISPLAY_NAME_RESOLVERS`
entries are the ten process base classes that declare it (`ProcessStep`, `Port`,
`ProcessConnection`, `ProcessStepDetail`, `MaterialTemplate`, `MaterialState`, `MaterialStateType`,
`MaterialComponent`, `InstrumentationActivity`, `InstrumentationSystemActivity`). No P&ID class
derives from any of them, so no plant object's tag or caption moved -- 0 of 6,352 objects across the
39 P&ID files under `data/` -- and `test_display_name.py` fails if a regeneration adds an
`identifier` elsewhere. Process identifiers are **not unique** in real files: the bpmn2dexpi export
numbers its `Stream`s and its `MaterialState`s from "1" alike, and the CO2 terminal's `pXylene`
component carries the identifier `oXylene`. `get_by_tag` therefore raises `AmbiguousTagError` on
such a tag, which is the honest answer -- `find_by_tag` returns every match. Do not make the index
pick one.

`DISPLAY_NAME_RESOLVERS`, `GENERIC_TAG_ATTRIBUTES` and `CAPTION_FALLBACK_ATTRIBUTES` also define the
Git projection's tag and the caption attributes its structural key leaves out
(`versioning/projection.py`), so extending them changes the projection of those classes: the process
resolvers added each process object's `identifier` to its projection header, and re-keyed a process
object with a `make_id`-shaped id under `id_policy="source"`.

A human-facing message names an object by its display name, never by its bare id: the ids of the
objects an issue is *about* belong in a structured field (`SearchMatch.object_id`,
`ValidationIssue.affected_component_ids`), where a program reads them. An object the message
only *refers to* (the node a pipe points at, the item a segment should end in) is not in that
list, so for it the message is the only pointer: name it with
`display_name.referenced_object_name`, which appends the id when the object has no tag and its
caption does not already show the id (`"Piping Node id_3f2a..."`). Do not add such ids to
`affected_component_ids` instead; that list identifies the issue, and consumers fingerprint it.
Messages outside validation name the objects they mention with it too, which is why it lives in
the toolkit rather than the private validation module; `validation.rules._naming`
re-exports it for the rules that import it from there.

An instrumentation function has two tags, and both are meant: `get_tag` resolves it by its
number (`"4712.02"`), which is what the query index and the diff match on, while
`display_name.instrument_tag` composes the loop tag a P&ID prints (`"PICSA-4712.02"`: category and
function letters, a hyphen, the number). Lists shown to a person -- `summarize_model`, the table
export -- use `instrument_tag`, because the number alone repeats within a loop. Do not
concatenate the attributes by hand again; the old concatenation raised on a missing part.

Tag lookups also index `instrument_tag` as an alias, without changing `get_tag` or diff
matching. Bare numbers still return both loops and their instruments; `find_by_tag` and
`get_by_tag` accept `type=` (concrete or DEXPI parent class name, also in MCP) to narrow before
checking uniqueness. A printed tag such as `PI-4712.01` works through the resolver too.
Neither a type filter nor a printed tag may silently choose between duplicates. When the
printed tag equals the bare number, index the object only once.

`display_name.get_tag` is the same resolution without the caption's fallbacks (the device type,
a process object's `label`, and the object id): use it where a *tag* is wanted rather than a
caption. The diff's `tag` field, the query index's canonical `by_tag` keys (with the printed
instrument aliases above) and `SearchMatch.tag_name` all come from it. Whether an id is one `make_id` minted
is `base_model_utils.is_generated_id`; do not add another copy of that regex.

A material component is the one process class whose `identifier` is optional, and a component
may be identified by a ChEBI identifier or an IUPAC name alone. So its resolver rows go on after `identifier`: `iUPAC_identifier`, then `chEBI_identifier`, for a
`PureMaterialComponent`, and `projectReference` for a `CustomMaterialComponent` -- the
attributes `process_materials` tells two components apart by, which a test holds the rows to.
They are rows of `DISPLAY_NAME_RESOLVERS`, not caption fallbacks, on purpose: what identifies a
component is its tag, so `referenced_object_name` appends no generated id and the query index
finds it by `"CHEBI:15377"`; a `label`, which two components may share, stays a caption beside
which the id still stands. Before, a message listing such components named them as
`Pure Material Component id_d589...`. Every corpus
component has an identifier, so none changed its name. Give another class a second identifying
attribute the same way, as a row; do not name it in the message that needs it.

One older, narrower tag extractor remains: `pydexpi.diff.engine.TAG_ATTRIBUTE_ORDER`, which
`TagEquality` *matches* on (changing it changes which objects a tag diff pairs up, so it is not
simply swapped for `get_tag`). `query.index._tag_of` was consolidated onto `get_tag`:
no generated class carries more than one of its three attributes (`tagName`, `subTagName`,
`segmentNumber`), and every class that carries one resolves that same attribute first in
`get_tag`, so the index only gained keys (valves, lines, instrument functions, off-page
connectors) and stopped indexing blank tags. Do not add another implementation; consolidate on
`display_name`.

Labels for the two other things a UI shows next to an object live beside it, in
`pydexpi/toolkits/display_labels.py`, and are exported from `pydexpi` like `get_display_name`:

- `enum_value_label(member)`: a unit is its `quantity_format.unit_symbol(...,
  qualify_pressure_reference=True)` (`"°C"`, `"m³/h"`, `"barg"`); any other member is its value
  in sentence case (`FailClose` → `"Fail close"`), with acronyms kept (`"Non-GMP relevant
  function"`), the generator's `_PER_` / `_COMMA_` decoded and standard designations stripped of
  `Object` / `Artefact` (`"NPS 1 1/2"`, `"EN 1333 PN 2.5"`), plus the curated
  `ENUM_VALUE_LABEL_OVERRIDES`. It caches on (enum class, member name), never on the member:
  `StrEnum` members of different enums with the same value compare equal, and a member-keyed
  cache would hand `PressureAbsoluteUnit.BAR` the `"barg"` of `PressureGaugeUnit.BAR`.
- `attribute_label(name)`: the curated `ATTRIBUTE_LABEL_OVERRIDES` (acronyms such as
  `caseUID` → `"Case UID"`, and `pipingComponentName` → `"Component name"`), else
  `humanize_attribute_name(name)`. Tests pin every override to a real enum member or attribute,
  and check that every generated enum value and attribute name reads as a sentence.

The table export is not a third implementation: its object captions ("Equipment type",
"Valve type", "Piping component") come from `display_name.humanize_class_name`. Its *column
headers* are sentence-cased attribute names from `table_export.format_string`, which delegates
to `display_labels.humanize_attribute_name`: one implementation of the casing. Those headers
double as the keys of the translation tables in `pydexpi/exports/table_locale.py`, the single
home for export translations (en/de/nl/zh), which is why `format_string` does **not** apply
`ATTRIBUTE_LABEL_OVERRIDES`: `"Piping component name"` is a translation key, and an override
there would silently drop its translations. Unit symbols and float formatting live one layer
down, in `pydexpi/toolkits/quantity_format.py`, so that model-level code can render a quantity
without importing `pydexpi.exports` (whose `__init__` pulls in pandas, openpyxl and networkx);
`table_locale` re-exports them unchanged, so the export side keeps its import path. Do not add
parallel translation or unit tables; if `humanize_attribute_name`'s casing ever changes, the
locale keys must change in lockstep (a test enforces same-key-set across languages).

`unit_symbol` takes the enum *member*, so it can tell `PressureGaugeUnit.BAR` from
`PressureAbsoluteUnit.BAR` even though they share the value string the table is keyed on.
`qualify_pressure_reference=True` spells the reference out (`"barg"` / `"bara"`); it is off by
default because the table export renders the bare symbol, and on for label materialization
because P&ID labels spell it out — the DEXPI reference drawing writes `"60 barg"`.

Styled Excel layout (title block, header styling, print setup) lives in
`pydexpi/exports/table_style.py`; the title block is fed by
`model_provenance.get_model_provenance`, the same source the graph exports use.

### Drawn labels and the attributes behind them

A drawn tag is not the conceptual attribute. It is a diagram `Text` graphical primitive whose
`text: str` was *materialized* when the model was imported or created; the link back to the data
is `Text.template`, a `TextTemplate` whose fragments are `LiteralText` and
`AttributeRepresentation(object, attributeName, type)`. Changing `tagName` alone therefore leaves
every renderer and export correctly drawing the old string.

`pydexpi.toolkits.label_toolkit` is the single home for template rendering
(`render_text_template`, `find_dependent_texts`) — do not materialize a label anywhere else.

**Re-rendering is gated on fidelity.** Re-rendering replaces the *whole* label, so a label may only
be re-rendered if rendering its template against the model it was drawn from reproduces what the
label already says. This is not defensive padding: the DEXPI reference drawing contains labels
whose `TextStringFormatSpecification` is genuinely lossy — `"66KL21-80"` is templated as
`PipingComponentName + "-"`, with no fragment for the trailing `80` — and rebuilding those would
silently delete characters. 128 of the drawing's 137 templated labels render faithfully; the other
9 are left alone. Anything that lowers that ratio is a renderer regression, and
`tests/test_toolkits/test_label_toolkit.py::TestReferenceModel` guards it.

Proteus off-page references keep their nested text in a representation group under the
connector. A format naming that reference templates the text on its data attributes
when the template reproduces its text; pipe and signal references share this parser.

Template-less labels (the Proteus parser emits fragments carrying no attribute reference at all)
are reached through a structural fallback: a `Text` inside a `Label` group of the
`RepresentationGroup` that represents the object, whose current text is exactly the attribute's
rendered value. That is the same equality gate with a one-fragment template synthesized on the
spot — a label saying anything more than the bare value is left untouched rather than guessed at.

**What a renderable fragment names.** `build_text_template` / `attribute_fragment` template a
`Text` on an object's own attributes. A fragment names a **data** attribute --
never a composition, a reference or the id, whose set value renders `None`; `Units` /
`ValueAndUnits` only on a field whose every value type is a physical quantity, decided on the
field's *type* (read through `typing.get_type_hints`: some `model_fields` annotations are
unresolved `ForwardRef`s); and `attributeName` is stored in its DEXPI spelling
(`base_model_utils.dexpi_attribute_name`, the rule the XML export writes properties with).
Anything that reads every fragment in the drawing must tolerate one holding no object: the XML
loader leaves `object` None, with an ERROR, when a template's `Object` reference does not resolve,
even under `strict=True`. Such a fragment renders `None`.

**A fragment's decimals and empty text live in `attributeName`.** DEXPI's
`AttributeRepresentation` has no field for a number format or for what an unset value shows,
and the generated classes take none, so the options are written after the DEXPI spelling:
`NominalCapacityVolume|decimals=2|empty=TBD` (`label_toolkit.AttributeFormat`,
`format_attribute_name` / `split_attribute_name`). It is a string in XML and JSON, so it
round-trips with no loader or export change; a plain fragment has no `|`, so nothing imported
reads differently. Read a fragment's attribute through `split_attribute_name` or
`bare_attribute_name`, never by matching `attributeName` raw: `resolve_attribute_field` and the
dependent-text search already do, and a name whose options do not parse renders None, so it is
left alone, never guessed at. A pyDEXPI subclass of `AttributeRepresentation` was the
alternative; it needs a class every loader and the XML export would have to know, and DEXPI XML
could not carry its fields.

### Annotation groups are not symbol geometry

A DEXPI drawing has no `Table` type. What reads as a table on the sheet is a **`Label`** — a
`RepresentationTypeGroup` subclass whose `elements` are a grid of `PolyLine` cell rulings plus the
`Text` primitives the section above is about. All 36 `*Label` classes derive from `diagram.Label`;
`Static` and `Symbol` do not, so one `isinstance` check separates annotation from symbol geometry.

The trap is that a label is nested **under the item it annotates** while being drawn wherever the
draftsman put it. In `data/reference_pid.xml`, `PlateHeatExchanger1`'s group holds its symbol
(`Static`, `ShapeUsage` at `(140.0, 143.5)`) *and* its `EquipmentBarLabel` — the equipment data
table, 13 polylines and 22 texts in the sheet's table band at `y 239..262`. Anything that treats
the exchanger's group as its symbol's geometry would take in the whole table.

`diagram_toolkit.is_annotation_group` / `ANNOTATION_GROUP_TYPES` is the single definition, and
`SHEET_PLACED_LABEL_TYPES` (`EquipmentBarLabel`, and a nested `Border`) the labels whose place is
the sheet's rather than their symbol's. `drawing_extent` measures what a drawing draws apart from
its labels; `annotation_extent` / `annotation_centre` measure a label itself.

**A symbol's footprint is what it draws, so an arc counts its sweep.** Every extent of a
drawn symbol -- `shape_extent`, `usage_extent`, `symbol_extent`, `object_extents`, and through them
the side a port is on -- measures an `EllipseArc` by `diagram_toolkit.ellipse_arc_extent`: its two
ends and the parameters inside the sweep where x or y is extreme, found in the ellipse's own frame
so that it is exact under any rotation (`swept_arc_box`). An arc whose angles name one direction
is its whole ellipse, as `process_drawing` traces its outline. Before, an arc counted its whole
ellipse: Tank1's dished heads on the reference P&ID are arcs of an ellipse 2.1 times as wide as its
walls, so its footprint was x 162.125..225.875 by y 52.25..145.75 where the tank is drawn at
179..209 by 73.5..124.5, so anything reading the extent as occupied area took in space beside the
shell that is clearly free. Over every drawing under `data/` six footprints change, each a
vessel with dished heads: Tank1 on both reference P&IDs and `Tank-1` in the Proteus-loaded
`C01V04` as above, `ProcessColumn-1` in `C02V03` (0.042 wide to 0.022) and `E_1` in both xvisual
files (by 0.03 and 0.17 in y; their heads lie on the box already, the ellipse only overreached it).
The Proteus parser's escape check measures by the same helper in its Y-up frame (it fell back to
the *unrotated* ellipse for a rotated arc). `ellipse_half_extent` stays the box of the whole
ellipse.

There is also no fallback reference point. `find_reference_point` returns `None` for any group
with no `ShapeUsage` -- 99 of the 185 representation groups in `data/reference_pid.xml`, including
a top-level `PipingNetworkSystem` -- rather than the sheet corner `(0, 0)`. Do not reinstate a
fallback; there is no meaningful point to use.

### Attribution of generated files

`pydexpi/attribution.py` is the single source of truth for "which system produced this file".
Do not hard-code the name, vendor, version or URL anywhere else, and do not read
`pyproject.toml` for the version — `get_version()` reads the *installed* distribution metadata,
which is the honest answer and keeps the deliberate repo/PyPI version gap out of the way.

The package version is pyDEXPI's own and is not the DEXPI version: package version **2.1.0** is the
first version whose classes implement DEXPI **2.0.1** (`pydexpi.DEXPI_SPEC_VERSION`), and version
2.0.0 implemented DEXPI 2.0. There is no DEXPI 2.1.0. Neither 2.0.0 nor 2.1.0 is on PyPI: both are
versions of this development repository only, which is the repo/PyPI gap named above (the newest
PyPI release is 1.2.0, which implements DEXPI 1.3). The generator string, and
`originatingSystemVersion` when pyDEXPI stamps it (the field was unset and the system is not
rebranded), carry the package version; a document's `<Import>`s and `dexpiVersion` carry DEXPI's.

Do not infer the DEXPI version from the package version, though. Development checkouts between
the regeneration from DEXPI 2.0.1 and the bump to 2.1.0 reported 2.0.0 with the 2.0.1
classes, and an editable install that has not been reinstalled since still does. So a file can
say `Generated with pyDEXPI 2.0.0` and be DEXPI 2.0.1, as `data/dexpi_2_0_1/synthetic_process.xml`
does. `DEXPI_SPEC_VERSION` says which DEXPI the running classes implement, and a document's
`<Import>`s or `dexpiVersion` say which DEXPI the file is.

**Two carriers, and they must not be mixed.**

- The **typed DEXPI fields** — `EngineeringModel.originatingSystemName` / `…VendorName` /
  `…Version` — carry the brand and nothing else. They are standardised and queryable (a Neo4j
  property, an Excel title-block row, a GraphML graph attribute), so appending anything like
  `" (powered by …)"` there breaks grouping and filtering. `stamp_originating_system` writes
  them.
- The **free-text generator string** — `generator_string()` / `generator_comment()` — carries
  the credit and the URL. It feeds the XML header comment, the SVG `<metadata>`, the PDF
  `Producer`/`Creator`, the Excel workbook description, and the `generator` graph property.

**Never overwrite.** Only fields that are `None` are filled. `None` is the *only* unset value:
an explicit `Undefined` is a statement by the source document that the value is knowingly
unknown, which is data. This is what stops a load/save round-trip laundering a vendor's
`"P&ID Toolbox"` into `"pyDEXPI"`, and it is pinned by a test.

**Serialization must not mutate the caller's model.** `stamp_exported_model` copies first, and
only copies when there is something to stamp. It is applied once, in
`tree_ref_base/utility_base.py::export_to_string` — the funnel that `export_to_bytes`,
`export_to_stream` and `save` all pass through, for both XML and JSON. Do not add a second
stamping site.

`generator` is deliberately **not** produced by `get_model_provenance`: that function reports
facts about the *model*, whereas the generator describes the *file being written*. The two
answer different questions and a vendor export shows both at once —
`generator="pyDEXPI 2.1.0"` beside `originatingSystemName="P&ID Toolbox"`. The key name lives in
`model_provenance.GENERATOR_KEY`; the writers (`graph_loader.parse_dexpi_to_graph`,
`table_export`) set it themselves.

Rebranding is configured **only** through the environment (`PYDEXPI_SYSTEM_NAME`,
`…_VENDOR`, `…_VERSION`, `…_URL`, `PYDEXPI_POWERED_BY`, `PYDEXPI_EXPORT_DATETIME`), read lazily
on every call so tests can `monkeypatch.setenv` and a long-running host can rebrand at runtime.
There is no global mutable state and no `set_attribution()` — do not add one without need.

Two gaps are deliberate, not oversights: **Neo4j CSV** has nowhere to put a graph-level property
and a per-node column would repeat one string on every row; **PNG** has no metadata
pass-through in `resvg` without a new dependency. `--fast` conversion still gets the XML comment
but no field stamp, because that route is documented as preserving the document as-is.

`exportDateTime` is opt-in for a reason: stamping the current time makes every export
byte-different from the last, defeating reproducible output and `pydexpi/hashing.py`.

### Objects drawn as one assembly, stored as two

A valve and the `ControlledActuator` mounted on it are one thing on the sheet and two things in the
model. The `ActuatingSystem`'s group sits at the **top level** of the diagram while the valve's is
**three levels down**, under its `PipingNetworkSystem` and `PipingNetworkSegment`. Nothing joins
them but a shared position, and no `ConnectorLine` links them. Because the valve is nested, its
enclosing groups are drawings in their own right: the segment's group draws the valve without
ever naming it.

**Co-location is the invariant, and it is the model's own claim.** In `data/reference_pid.xml` the
valve and its actuator carry *identical* `ShapeUsage.position` -- `(323.5, 98.0)` for
`GlobeValve1`/`ControlledActuator1`. The actuator appears to sit on top of the valve purely through
shape geometry and rotation, so the two share one point and there is no offset between them to
keep.

`pydexpi/toolkits/companions.py` is the single home for these relations:

- **An explicit table, never "everything that references this object".** A valve is also referenced
  by its piping connections, its segment and its `ActuatingFunction`; counting those would take in
  half the drawing. `COMPANION_RELATIONS` lists only relations naming a *physical assembly*.
- **Relations are symmetric.** DEXPI records the pairing one-directionally --
  `ActuatingSystem.operatedValveReference.valve` points at the valve and the valve points back at
  nothing -- so the valve-to-system direction is a scan over `PlantModel.actuatingSystems`
  (`model_toolkit.get_objects_referencing` is the general form). Both directions must resolve.
- **Drop companion groups that nest with the primary.** `ControlledActuator`'s group sits *inside*
  the `ActuatingSystem`'s, so addressing the actuator and returning the system would count the
  actuator twice. `groups_overlap` is the guard.
- **Symmetric for belonging, directional for existence.** `companions` answers "what belongs with
  this" and reads the same from either member; `dependants` answers "what cannot exist without
  this" and only reads valve -> system: the actuator has nowhere to be without its valve, but a
  valve is a piping component in its own right and exists without its actuator.
- **Do not recurse.** Companions-of-companions cycle (valve -> system -> valve). One flat pass;
  what keeps a non-transitive relation symmetric is *completing the assembly*: from a system,
  return the valve **and** any other system on that valve.

**A client asks; it does not rebuild.** `companions.get_move_companions(model)` returns `{target_id:
[companion ids]}` for every object that has anything belonging with it. It is a loop over
`get_companion_groups` on purpose, and takes the `group_of` lookup from `build_group_index`, which
walks once with the same first-group-wins order as `get_representation_group_of_object` and keys by
identity: calling `get_companion_groups` with its default lookup in a loop is **quadratic**.

### A child the parent cannot hold must not take the parent down

`@redirect_errors_to_registry` turns any exception in a pass into a registry entry and skips the
element -- including everything it contains. So a composition step that can fail for one child
(e.g. `add_by_inferring_type` when the parent class has no field for it) must not raise out of the
parent's pass: a COMOS motor of unknown class under a `Pump` used to drop the pump and its
nozzles, with only a registry line to show for it. Catch exactly the recoverable case
(`NoSuitableFieldError`, not `ValueError`), keep the child (EquipmentParser's
`detached_subequipment`, placed at plant level by `PlantModelParser`), and register a warning
naming both ids. `test_no_equipment_is_silently_dropped` holds the corpus to this: every input
`Equipment/@ID` is reachable in the returned model or has a diagnostic saying it was omitted.

### Vendor dialects hook `ProteusLoader._load_parsed`, not `load_xmlstring`

`pydexpi/loaders/plantengineer_proteus_serializer/` adapts the stock Proteus parser to
PlantEngineer's dialect (its own `ComponentClass` names, shapes with a valueless
`SymbolRegistrationNumber`, no implicit segment-connection inference). Any future vendor dialect
should follow its shape: subclass `ProteusLoader` and `ParserFactory`, and change nothing under
`pydexpi/loaders/proteus_serializer/`.

**The one method to hook is `_load_parsed`.** `ProteusLoader` looks like it has four entry
points, but only `load_xmlstring` takes a string: `load_xml_file` and `load_xml_from_stream`
both delegate to `load_xml_as_bytes`, which calls `_load_parsed` directly. A loader that
overrides `load_xmlstring` therefore preprocesses nothing on the file path — the normal way an
export is loaded — and does so *silently*, since the stock parser accepts the un-normalized
document and just builds a wrong model. One dialect loader shipped that way until its
entry-point test caught it. Cover every entry point, not just the string one.

**Routing is by `OriginatingSystem`, in `loaders/public.py`.** `_detect_xml_dialect` sends a
Proteus document whose `PlantInformation/@OriginatingSystem` is `"PlantEngineer"` to
`PlantEngineerProteusSerializer`, so `load_xml_file` and friends pick the dialect up without the
caller naming it. A future dialect adds a value there, not a second detection pass. Isolated-tee
removal stays opt-in: it deletes model content, so routing does not do it.

Preprocess the **parsed tree**, not XML text. `_load_parsed` takes the caller's `parse` callable,
so a subclass wraps it and mutates the root in between, leaving the base class's registry reset
and well-formedness error handling intact. Text-level rewriting would force byte input through a
decode/mutate/re-encode cycle that strands the document's own encoding declaration against the
new bytes. The transform modules keep both forms — `*_in_tree` for the loader, a string wrapper
for tests and ad-hoc use.

### The MCP server

For AI engineering inventory, recommend `get_complete_piping_inventory`: it includes
all valve families and off-page connectors without inclusion flags. The legacy
`get_piping_component_list` retains its narrower defaults for compatibility. Inventory
completeness describes the loaded model, not the source document or the physical plant.

`pydexpi/mcp_server/` lives in this repository because it is coupled to the generated
classes: `tools/schema.py` introspects them. So a class change that breaks `tests/test_mcp_server/`
is a real break, not a flaky neighbour — fix the server in the same PR.

**An installed extension adds to the server, found by entry point.** `create_server` finds
extensions through the entry-point group `pydexpi.mcp_extensions` (`extensions.discover_extensions`:
sorted by name, a failing import skipped with a warning) and registers them after its own tools.
The server never imports an extension by name. A per-model state an extension keeps goes in
`ModelEntry.extras` under a key of its own; a reply field an extension computes is a provider
registered with `extensions.register_item_fields` for its place in the reply (`ITEM_FIELD_KINDS`),
per server, so `create_server(extensions=())` shows none. The provider also gives the passage of
`describe_item`'s description that documents its fields, which replaces the server's own
(`discovery.DESCRIBE_ITEM_PASSAGES`), so the description names no field the reply does not give.
Registered last, an extension's tools would be listed last; it places them with
`extensions.place_tools_after`, and `create_server` then rebuilds the SDK's tool registry once
(`arrange_tools`, the one reach into `_tool_manager._tools`). `test_extensions.py` holds the server
without extensions to exactly its own tools and no prompt. Installing or removing an extension, or
changing its entry points, needs a reinstall before a local run sees the change.

Three rules keep it an optional extra rather than a dependency:

- **The SDK is imported only inside `pydexpi.mcp_server`**, and only `server.py` imports it, behind
  a guard naming the extra -- or, when an SDK outside `server.SDK_REQUIREMENT` (`mcp>=2.3,<3`, the
  extra's pin) is installed, the version it needs. `import pydexpi` must never load `mcp`;
  `test_library_imports_do_not_pull_in_the_sdk` checks that out of process. The server is
  `mcp.server.mcpserver.MCPServer` (1.x's `FastMCP`); 2.3 is the floor because it is the first
  release whose `MCPServer` takes `middleware=`.
- **Importing `server.py` builds nothing.** `create_server()` is a factory; `main()` is the only
  caller that runs one. Tests build their own, isolated servers.
- **Each test module calls `pytest.importorskip("mcp")` itself**, before importing the server --
  not in `conftest.py` -- so a run without the extra collects and skips cleanly.

**Test what a client sees through the protocol**. Most MCP test modules call tool functions
directly through the SDK-private `_tool_manager`, which is quick but skips the input schema,
argument validation and result wrapping a real client goes through. `test_protocol.py` drives the
SDK's `mcp.client.Client` over an in-process server: `Client(server)` speaks the 2026-07-28
protocol, as a 2.x client does by default, and `Client(server, mode="legacy")` the `initialize`
handshake (the round trip runs in both). It checks every tool's input schema and that every tool
is annotated `-> str` (`MCPServer` would otherwise `str()` an unexpected result into the reply
without an error), and round-trips the tools an agent uses most. Protocol fields are snake_case
in 2.x (`is_error`, `input_schema`, `output_schema`, `uri_template`). A result that fails to serialise is only caught for a tool some test calls, so
call a new tool through the protocol at least once. Async tests use anyio's pytest plugin, which
ships with the SDK -- no pytest-asyncio.

**Discovery answers with the toolkits' own code**. `describe_item` reports a node as
`free` through `piping_toolkit.node_holders` -- never through raw `get_objects_referencing`, which
also counts a node's own drawing. A discovery field that restates toolkit or rule logic must call
that logic, so a reply and a rule can never disagree. Report order and geometry as they are: `describe_segment` lists pipes in `connections` order
and says so, `describe_run` lists a line's items through `piping_toolkit.run_items` and says flow
order, and a node's `positions` lists every drawn position rather than choosing one. The same holds
for a process model: `describe_item` on a step, port, connection or material state
(`tools/process_discovery.py`) reads ports, owners and connection ends through `process_toolkit`
and component order through `process_materials.state_component_order` -- the walks and the pairing
check the material rules use -- so a vector reported `fits: true` is one the rules accept.

**A reply bounds its lists and counts the rest**. A client is often an LLM, and a list one
model can make hundreds long fills its context in a few calls. `loading_issues` lists the first 20
messages beside every level's count. A list of validation issues is bounded per rule, not
overall: a lenient process load fails `pydexpi_mandatory_attribute_has_value` on 416 objects of the
CO2 terminal, and an overall cap would hide one dangling reference behind them. A list of issues or messages a new
reply carries is bounded like these, and the tool's docstring -- the one text a client reads -- says
so.

**Network transports depend on two rules; keep both**. They isolate clients from each
other and the server's files from its clients -- they do not authenticate anyone, and
`docs/mkdocs/mcp.md` says what else they do not do. Every client connection
has its own `SessionState` -- tools hold a `ConnectionSessions`, which hands each call the state
of the client making it -- so never keep model state anywhere else, such as a module global or a
tool closure. And every path a client names goes
through the server's `FileAccess` policy (`access.py`): unrestricted over stdio, confined to
`--file-root` when given (checked after resolving `..` and symlinks), and disabled on a network
transport without one. A new tool that reads or writes a file must call `file_access.resolve`.

**What a connection is, on SDK 2.x**. `get_context()` is gone, and the `ServerSession` a
request carries is a new proxy per request, so neither can key a session (keying on it, as 1.x
code did, gives every call an empty state). The per-connection `Connection` has no public accessor
in 2.3, and the 2026-07-28 protocol era has none at all over HTTP: each request gets a
`Connection` of its own. So `create_server(per_connection=...)` decides:

- **Off (stdio, and tests that call tool functions directly):** one `SessionState`. A stdio server
  serves the one client that started it, in either era -- the SDK's own advice.
- **On (`main()` for `sse` and `streamable-http`):** `server._RequestMiddleware` names each
  request's connection through `server.connection_of` -- the session's private `_connection`, and
  its `outbound` channel, which every request of one client stream shares in both eras -- and
  `ConnectionSessions.serving` hands it to the tools through a `ContextVar` (which
  `anyio.to_thread.run_sync` copies into the worker thread a sync tool runs on). States are keyed
  weakly by it, so an expired or closed session's models are freed. A request on no stream (the
  2026-07-28 era over HTTP) is refused with -32022 naming the handshake versions, which a client in
  `mode="auto"` falls back to. When the SDK exposes the connection publicly, read it from there.
  `test_transports.py` pins both eras; per-connection tests connect through
  `mcp.client._memory.InMemoryTransport` (SDK-private, like `_tool_manager`), because
  `Client(server)` dispatches in process with no stream.

**Tool calls run one at a time**. The 2.x SDK runs a sync tool on a worker thread, so an
agent's parallel tool calls would use one model on several threads at once. The same middleware
serialises `tools/call` and `resources/read` server-wide, as 1.x's single event loop did;
`test_tool_calls_run_one_at_a_time` fails without it. Making it per session would need pyDEXPI's
caches to be thread-safe first.

### Error handling

- **Loaders** use `pydexpi.loaders.error_registry.ErrorRegistry` to collect non-fatal
  issues. `InternalParserError` is re-raised immediately; other levels are accumulated and
  can be retrieved with `get_errors()`. A tree-reference load that returns `None` always holds
  one CRITICAL entry: the refused conversion's, the one for a JSON document that is no
  object, or `Nothing was loaded: the root object ... could not be built`, registered last by
  `TreeReferenceLoader.load` for DEXPI XML and JSON alike. The public loaders turn `None` into a
  `ValueError` quoting the first ERROR and CRITICAL messages, since they discard the registry.
- **Validation** uses `ValidationEngine` + `ValidationIssue`.
- **Programming errors** (wrong types, invariants violated) should raise an exception rather
  than be logged and ignored.

### Validation rules

Add one validation rule per module under `pydexpi/validation/rules/`. A rule class should
implement the `ValidationRule` protocol:

```python
class MyRule:
    id = "pydexpi_my_rule"
    name = "My rule"
    description = "..."
    level_of_recommendation = LevelOfRecommendation.MANDATORY
    source = "..."
    applies_to = SomePyDexpiClass
    scope = RuleScope.OBJECT

    def validate(self, obj: SomePyDexpiClass) -> list[ValidationIssue]: ...
```

Register it in `pydexpi/validation/rules/__init__.py`.

**`scope` is not optional for a rule in this repository, even though the protocol tolerates its
absence.** It says whether `validate(obj)` is meaningful for `obj` alone (`RuleScope.OBJECT`) or
needs the whole composition tree (`RuleScope.MODEL`), and only `ValidationEngine.validate_objects`
reads it — `validate(model)` runs every rule regardless. A rule that omits it is treated as
`MODEL` and reported in `ScopedValidationResult.unchecked_rules` forever, which is the right
default for a rule written outside this repository and a silent bug for one written inside it.
`tests/test_validation/test_default_validator.py` fails if a built-in rule does not declare one in
its own class body.

**Do not infer scope from `applies_to`.** It looks like `applies_to = EngineeringModel` identifies
the whole-model rules and it does not: `EngineeringModelNotEmpty` targets `EngineeringModel` and
reads only `obj.conceptualModel` / `obj.diagram`, so it is object-local. The genuinely model-scoped
rules are `ModelCompositionTreeUnique` (needs one `seen` set across the tree),
`ModelReferencesInCompositionTree` (builds a model-wide instance index), `InstrumentInAtMostOneLoop`
(counts each instrument's loop memberships) -- all three MANDATORY, so a scoped run is never a
clean bill of health and `ValidationSummary.is_complete` is False for one -- and, RECOMMENDED,
`PipingNodeSingleConnection` (counts connection endpoints per node across every system),
`TeeNodesConnected` (what holds a tee's node is any connection or segment end, and what
frees one is a change to the branch, never to the tee) and the five process rules that are
not MANDATORY: `ProcessConnectionPortsAgree`, `ProcessStreamDirection` and `ProcessPortRoleNames`
read a port or a role a change to another object changes alone, and
`ProcessSharedStateComponentOrder` and `ProcessFractionVectorLength` need every stream that pairs a
state with a template; `ProcessFractionsReadAgainstTemplate` asks whether any does, which is
the same whole-model question. `ProcessStepDrawnInsideParent` is model-scoped for the same
reason as the node rule, and applies to the `EngineeringModel` because it reads the drawing against
the conceptual model: the first rule that looks at geometry. The loop rule is the converse trap: it
targets `PlantModel` and reads only its own loops, since DEXPI composes them nowhere else, yet it is
MODEL. The bound is on the instruments the loops hold, and the change that breaks it is to a loop's
member list, never to the `PlantModel`, so a scoped run would never reach it while reporting it
checked. Like the node rule, a bound on what is
*referenced* from elsewhere is model-scoped however cheap it is to read. Conversely,
`MandatoryAttributeHasValue` targets every `PyDexpiBaseModel` and is OBJECT.

**MANDATORY means DEXPI compliance.** A rule is MANDATORY only when DEXPI itself requires it -- a
UML multiplicity, a normative statement. A pyDEXPI convention is RECOMMENDED and says so
in `source`: `PipingNodeSingleConnection` is, because DEXPI bounds a node's `sourceNode` and
`targetNode` references separately and says nothing about one of each. The loop rule is MANDATORY
because the published 2.0.1 model states its bound (`ProcessInstrumentationFunctions`,
`oppositeUpper="1"`, in [pyDEXPI-builder](https://github.com/process-intelligence-research/pyDEXPI-builder)'s
`data/dexpi_xmi_files/2.0.1/Plant.xml`), and the mandatory-attribute rule because a required field
is a 1..1 multiplicity of the model -- though not every 1..1 is a required field yet: the twelve
`Undefined | X` properties are optional, so the rule does not see them.

**The two segment rules split along that line.** `pydexpi_segment_connectivity` is
MANDATORY for what DEXPI 2.0.1 defines: `PipingNetworkSegment.SourceItem` / `SourceNode` and
`TargetItem` / `TargetNode` are where the segment starts and ends, so they must be where its items
and connections do. It reads that through `piping_toolkit.segment_ends`, which needs no linear
run: a segment that forks or is listed out of flow order still has its ends checked, and a fork's
declared end must be one of its ends. An element touching nothing else in a segment that holds
more (a stray pipe, an orphan item) is no start or end, and an omitted (`None`) end means an open
end, so it disagrees with an end pipe that names an item.
`pydexpi_segment_linear_order` is RECOMMENDED, and its
`source` names the Proteus segment convention: one linear run, lists in flow order, a `PipeTee` or
`PropertyBreak` only at an end. None of that is DEXPI -- 2.0.1 made the opposite multiplicities of
`PipingConnection.SourceItem` / `TargetItem` unlimited, `Items` and `Connections` were never
ordered, and the text puts no tee at a boundary. Linearity is read through `segment_chain`, the
one walk of a run, so the rule and every walk agree on what one run is.

### Extensions: entry points, and nothing named

The CLI and the MCP server discover plug-ins by entry points and run on their own without them:
an MCP server extension (`pydexpi.mcp_extensions`, *The MCP server*); CLI commands
(`pydexpi.cli_plugins`, a `register(app)` that may also place its commands in `--help` by
rearranging `app.registered_commands`); and what `diff --patch` prints with
(`pydexpi.patch_writers`; without one it exits 2). `cli.discover_plugins` skips an entry point
that fails to import, with a warning, and `cli.build_app()` builds the app afresh, which is how
the tests run it without plug-ins (`tests/test_cli/test_plugins.py`). The discovery code is an
interface installed packages build on: change it deliberately, and never name a particular
extension package here.

A model that is tedious to build by hand is a saved document for a test, under
`tests/fixtures/built/` and read with `tests.fixtures.load_fixture`; the files are kept
byte-stable and are not edited by hand.

### Architecture decisions

Decisions that shape the library for years live in
[`docs/mkdocs/adr/`](docs/mkdocs/adr/README.md) rather than in issue threads, so the *reasoning*
survives the decision. Read the relevant record before reopening one of these questions.

**ADR-0001** records why Pydantic is still the parse target even though roughly a quarter of
`tree_ref_base/loader.py` exists to evade validation, and names the triggers for revisiting. The
practical consequence for day-to-day work: express new loader leniency through the existing
`_missing_attributes_only` / `_compose_without_unusable_values` helpers. Needing a *third*
mechanism is a signal to revisit the ADR, not to invent one.

**ADR-0002** separates the semantic diff (`DiffResult`), the exact-state digest
(`hashing.model_digest`) and the Git projection (review text), and fixes the one-way bridges
between them. In practice:

- Never take a snapshot diff for a history: 8 → 10 → 12 → 8 is an empty diff and three changes.
- Never parse Git text back into a model change. Load both revisions and diff the models.
- Say which equality a test means. *Semantic* equality is "`id_diff` reports no changes";
  *exact serialized state* is `hashing.model_digest`, which is order-sensitive and stable across
  processes. `canonical_json_hash` is neither, so do not persist it.
- Values in diffs, and in any other record of a value, share one JSON wire form,
  `pydexpi.loaders.value_codec`. Do not add a second encoder; `hashing.model_digest` is the
  exact-state fingerprint to store. The wire form is
  strict JSON: a NaN or an infinity a model holds is the string `"NaN"`, `"Infinity"` or
  `"-Infinity"` (*Numbers that are not finite*).
- Whether an id can be trusted depends on where the model came from, not on its shape: XML loads
  re-mint every `make_id`-shaped id, while models kept as JSON keep them. See
  [`docs/mkdocs/versioning.md`](docs/mkdocs/versioning.md).

## Traps

- **`PyDexpiBaseModel.id` default factory.** `make_id()` mints a fresh UUID for every object
  that has no explicit `id`. This is not reproducible across loads and can leak into
  exports if the exporter does not suppress generated ids.
- **A model's ids are not the ids the DEXPI XML export writes.** The schema's `id-pattern` is
  `[A-Za-z_][A-Za-z_0-9]*`, and a Proteus file names its objects `Tank-1`, which the parser
  keeps for traceability. `xml_serializer.schema_safe_ids` maps each id onto one the schema
  accepts as the document is written — `Tank-1` becomes `Tank_1` — and every `#id` reference
  with it; the model is untouched. An id the schema already accepts is written unchanged, so
  documents that were valid are byte-identical to before. A round trip through DEXPI XML
  therefore returns the mapped spelling, and it cannot do otherwise: the schema gives `Object`
  only `name`, `id` and `type`, and `name` has the same pattern, so there is nowhere to carry
  the original. JSON has no such constraint and keeps the source spelling.
- **`isinstance` against `get_equipment_internal_classes()` matches a TaggedColumnSection and
  a VentLine.** The list holds `ColumnSection` and `Vent`. `TaggedColumnSection` derives from the
  first *and* from `TaggedPlantItem`: a top-level item in `taggedPlantItems`. `VentLine` derives
  from the second *and* from `PipingComponent`: an item of a piping segment. Neither is an
  internal. Ask `equipment_toolkit.is_equipment_internal`, which tests membership of the
  list rather than `issubclass` -- the list is every such class of `Plant.ProcessEquipment`, so a
  subclass outside it is something else -- wherever "is this an internal" decides what happens to
  an object.
  Where an internal goes is `equipment_toolkit.slot_for(owner class, internal class)`, read from
  resolved annotations -- each of the 1,054 pairs that fit at all (1,050 under DEXPI 2.0) fits
  exactly one attribute -- never from the loader's `add_by_inferring_type`, which mutates and
  tries reference fields too.
- **`ClassVar` vs Pydantic field collisions.** Generated classes use `uri: ClassVar[str]` for
  the DEXPI schema URI, and JSON loading, `FormatConverter` and hashing resolve classes by it. A
  field of the same name removes it from the class: DEXPI's `Role.Uri` did, so `Role.uri`
  raised and no `Role` survived JSON. The generator now gives a DEXPI attribute whose field name
  would be reserved (`uri`, `id`, a public pydantic attribute) a trailing underscore -- `Role.uri_`
  -- and records the DEXPI name in `json_schema_extra["dexpi_name"]` (in pyDEXPI-builder).
  `base_model_utils.dexpi_attribute_names` reads it, and the XML serializer uses it both ways, so
  documents still say `property="Uri"` and stay schema-valid; JSON writes the field name, `uri_`.
  Do not add a hand-kept rename table beside it. `tests/test_pydexpi_classes/test_generated_names.py`
  fails if a regeneration brings a clash back, or renames another attribute without anyone noticing.
  JSON written *while* the clash existed names no class for a `Role`; the DEXPI 2.0 conversion
  reads it (*Reading DEXPI 2.0*). And `get_dexpi_class_from_uri(None)` raises like any
  unknown URI: it used to answer `AreaUnit`, the first exported name that declares none, which
  is where "Unknown DEXPI class: AreaUnit" for an object without a class came from.
- **`extra="forbid"`.** `PyDexpiBaseModel` forbids extra attributes. Do not attach ad-hoc
  fields to model instances.
- **A pickle is not a cross-version format, and `PickleSerializer.load` refuses one written by
  other classes.** Unpickling restores each object's `__dict__` without validation, so a
  model pickled under the DEXPI 2.0 classes came back under 2.0.1 without an error and with
  fields its class no longer has (`ProcessModel.compositions`, `MaterialState.phase`) or lacks
  (`MeasuringProcessVariable.informationPorts`), and failed later, with an `AttributeError` from
  whatever read the missing field. The 2.0 -> 2.0.1 conversion runs on XML and JSON only.
  `loaders/pickle_stamp.py` is the one place that decides whether a pickle is these classes', and
  raises `IncompatiblePickleError` (a `ValueError`) when it is not:
    - `save` appends a **stamp**: the DEXPI version, the pyDEXPI version and a signature of
      every model class and enumeration the pickle holds, collected by a `Pickler` whose
      `reducer_override` sees each object. `load` reads it **before unpickling** and refuses
      another DEXPI version, whatever the classes look like, or a class that is gone or whose
      signature changed. The signature is the field names with their attribute category:
      `Port.subReference` kept its name and went from composition to reference. It leaves the
      field's type out on purpose, whose spelling differs between Python versions, so a type
      that changes alone is not detected. A class the pickle does not hold may change freely.
    - The stamp follows the pickle's STOP opcode, which no pickle reader looks past, so the file
      stays a plain pickle of the model: `pickle.load` and an earlier pyDEXPI read it unchanged.
      Do not move the stamp in front, which would hand every other reader a dict.
    - A pickle **without a stamp** is checked once unpickled: each object's `__dict__` keys
      against its class's `model_fields`. A lenient load passes, because
      `_missing_attributes_only` sets an absent attribute to `None` rather than leaving it out
      (`test_pickle_stamp.py` holds the three lenient process files to it); an object built with a
      bare `model_construct` and never completed would not, and reading it would raise anyway, so
      the error names both causes ("written by other classes, or holds objects built without
      validation"). A value a `functools.cached_property` of the class left in `__dict__` is not a
      field and is not counted (`_cached_names`). A
      stamped pickle of matching classes skips this check and comes back as it was saved.
      The two rules differ on purpose: an unstamped pickle whose objects fit today's classes
      loads, so every DEXPI 2.0 *plant* pickle written before the stamp existed still does
      (2.0.1 changed process classes only), while the same content stamped `2.0` is refused.
    - An unpickle that fails for want of a class (`RESTORE_ERRORS`) is re-raised as the same
      error with its cause; a truncated file stays the `EOFError` or `UnpicklingError` it is, and
      "unsupported pickle protocol" stays a `ValueError`: that is about the Python, not the classes.

  None of this is a security measure: unpickling runs code the file names, and the stamp is what
  the file says about itself. `tests/test_loaders/pre_2_0_1/` holds two real pickles of the 2.0
  classes; never regenerate them. Regenerate any other committed pickle when the classes change.
- **XML is lxml, everywhere.** Production code uses `lxml` and nothing else — neither
  `xml.etree` nor `defusedxml`, which was dropped as a dependency once the last read path moved
  over. Read documents through `pydexpi.loaders.xml_parsing`, the one place the hardened parser
  (`resolve_entities=False`, `no_network=True`) is configured; deriving *where* an error came
  from is a separate concern in `pydexpi.loaders.source_location`. Three differences from the
  standard library bite:
    - Iterating an element yields comments, processing instructions and — because entities are
      left unexpanded — entity nodes. Walk children with `iterchildren(tag=etree.Element)`, which
      filters all three.
    - `etree.tostring(..., encoding="unicode")` refuses to emit an XML declaration. Prepend it.
    - `append` *moves* an element between parents rather than sharing it.

  The one deliberate exception is `load_xml_schema`: an XSD is trusted content that ships with
  pyDEXPI, and the DEXPI one declares an internal DTD whose entities must expand, so it is read
  with a parser that permits entity resolution and only bans the network.
- **`in` against a list of DEXPI objects is deep equality, not identity.**
  `PyDexpiBaseModel.__hash__` is the `id` and type, but its `__eq__` is pydantic's field-by-field
  comparison, recursive through references as well as compositions (made cycle-safe in
  `_base.py`, see below). `obj in some_list` therefore runs a deep
  comparison per element, and using that as the visit test inside a traversal is quadratic on top:
  it cost `get_all_instances_in_model` **0.56 s** on `data/reference_pid.xml` (1,612 instances)
  against **0.003 s** for an `id()` set — on a walk 25+ call sites depend on, and which is 99% of
  `validate(model)`. Test membership over model objects with `{id(o) for o in ...}` or
  `any(x is obj for x in ...)`, and hoist the set out of the loop rather than rescanning per
  element. `model_toolkit.remove_references_to_objects` is the reference implementation.

  Identity is not a behaviour change in practice: `id` defaults to a fresh uuid and pydantic's
  `__eq__` compares it, so distinct objects are never field-equal. The exception is a same-id
  *copy* -- a stray `deepcopy` -- which is field-equal and is not the object: a reference to it
  points outside the model. Neither model-wide rule uses `==` (on a process model the old `set()`
  lookups compared such a copy field by field and recursed round the cycle), and the two key on
  different things because they ask different questions. `ModelReferencesInCompositionTree` keys on
  `id()`: a reference resolves to *that* object, so one to a copy is the missing reference it is.
  `ModelCompositionTreeUnique` keys on the DEXPI **id string**, alone and not with the class,
  falling back to `id()` only for an object without one: an XML `xs:ID` is unique across the whole
  document, and an object composed twice and two objects sharing an id both write one id twice,
  which the schema rejects. Keying it on `id()` reported neither the copy nor the four ids the raw
  `TennesseeEastman-vpd-enriched.xml` shares across 55 objects.

  Caching the *per-class* attribute introspection behind `get_data_attributes` and friends looks
  like the same kind of win and is **not** one: measured across every instance in the reference
  model it saves 1 ms. Don't.
- **Two base hierarchies, not one.** `PyDexpiDataTypeBaseModel` (`PhysicalQuantity`,
  `MultiLanguageString`, `Undefined`, …) is a sibling of `PyDexpiBaseModel`, not a subclass, so
  an `isinstance(value, PyDexpiBaseModel)` check silently skips every data type. That is what
  made encoding a value raise for any data type value, `MultiLanguageString` included, until
  that was fixed; check both when you branch on model type.

  Their equality differs too. A data type is a value: equal when it is the same class and every
  field is equal, lists **in order** (a `PhysicalQuantityVector`'s values are ordered in DEXPI),
  and an enum member only to a member of the same enum, so `PressureGaugeUnit.BAR` is not
  `PressureAbsoluteUnit.BAR` although the two `StrEnum`s are `==`. The one unordered list is
  `MultiLanguageString.singleLanguageStrings`, a set of language variants, compared as a multiset
  -- the one data-type list the generated metadata does not mark `is_ordered`, which is what
  `_base._data_type_fields` reads. `__hash__` follows the same rules, so equal values hash equal.
  Equality used to be "the hashes are equal", and CPython hashes `-1` and `-2` alike, so `id_diff`
  saw no change from -1 to -2 °C; never compare data types by hash again.
- **`PyDexpiBaseModel.__eq__` cuts reference cycles too.** Pydantic's `==` follows references,
  so comparing two objects on the `Stream`↔`Port` cycle -- `stream == copy.deepcopy(stream)`, or
  two process models -- recursed until `RecursionError`. The override is co-inductive: a pair met
  again while it is still being compared further up counts as equal *for that comparison*, so
  the fields decide where the pair was first met and a difference anywhere on the cycle still
  makes the result false. The guard is per thread and held across the nested comparison, like
  `__repr__`'s. It makes `==` terminate, not cheap: test membership by identity all the same.
- **`PyDexpiBaseModel.__repr__` cuts reference cycles, and lives in `pydexpi_classes/_base.py`.**
  Pydantic's repr walks nested models unconditionally, so on the mandatory `Stream`↔`Port` cycle
  it recursed until `RecursionError` — printing *any* object on the cycle, in a debugger, a log
  line or a failing assertion's message, crashed. The override re-enters an object as
  `ClassName(id='…', ...)` instead of descending again, guarded per thread and held across the
  whole nested render (the recursion happens while the caller reprs the values, not in the frame
  that returns them). It cuts genuine cycles only: an object merely referenced twice still
  renders in full.

  It sits in the hand-written `_base.py` alongside `make_id` and the base models, which the
  generator imports and never writes. `tests/test_pydexpi_classes/test_base_models.py`
  pins the behaviour, and fails if the generated file ever defines the base models again.
- **`PyDexpiBaseModel.__deepcopy__` keeps one object per object, and lives in `_base.py`.** Pydantic registers a deep copy in `memo` only after copying its fields, so a reference
  back to an object still being copied — a `MeasuringLineFunction` referencing the
  `ProcessInstrumentationFunction` it is composed under — made a second, detached copy. 18
  of the 35 TrainingTestCases and the reference P&ID were affected, and every deep copy of a
  model held references that pointed outside it. JSON output never showed it,
  because references are written as ids. The override registers the copy before recursing. Like
  `__repr__` it is hand-written in `_base.py`; `test_base_models.py::TestDeepCopyKeepsIdentity`
  pins it. Tests that check object identity should assert it directly (no reference outside
  the model, no instance replaced) — hash and digest comparisons cannot see a split graph.
- **`QualifiedValue.value` is a union, and which member a property allows is on the property.** It
  is typed `float | int | PhysicalQuantity | PhysicalQuantityVector | Undefined` and required (the
  `QV-VALUE-UNION` deviation): a `Composition`'s fractions are vectors, a process
  file may say `<Undefined/>`, and `Compressing.numberOfStages` is an integer. Before the 2.0.1
  regeneration it was `float | PhysicalQuantity`, so every vector and every `Undefined` cost the
  value (and, under strict, its whole `QualifiedValue`) -- the fractions of all 11 `Composition`s of
  the Semantum export and all 12 of the bpmn2dexpi one, whose compositions themselves loaded. Read through the 2.0 conversion they load now, in
  `RatioUnit`, the bpmn2dexpi ones with all 8 values since R3 reads repeated `<Data>` as one list.
  The class alone no longer says which shape and unit a given property takes; the owning
  composition's `value_types` and `unit_type` do, and `toolkits/qualified_values.py` enforces them
  (see *A quantity value is checked against its property's binding*). `PhysicalQuantityVector` is
  still a *sibling* of `PhysicalQuantity`, not a subclass, so a check for "a quantity" has to name
  both. An `int` value is no longer coerced to `float`, and the graph loader keeps it an `int`:
  an Integer binding is the specification's, so GraphML declares `value` as `long` there beside
  `double` -- two numeric keys, which every reader handles, where the vector's JSON string under
  `value` was the mix to avoid (it is `values` now). No corpus file has an Integer-bound value.
- **Anything reached before the `ErrorRegistry` must not raise.** The loader is deliberately
  tolerant — `_get_dexpi_type` reports an unknown class, `_get_composition_attributes` reports an
  unknown field — but `DexpiXmlDeserializationElement._is_list_field` runs from
  `ElementBuilder.__init__`, *before* any of it, while the element tree is still being built. It
  used to raise `AttributeError`/`KeyError` there, so one typo anywhere aborted a whole document
  and made all that tolerant code unreachable. It now defaults to `True` for an unknown
  class or field. Keep new lookups on that path equally forgiving.

  **JSON is the format where this bites hardest, because decoded JSON is untyped.** A
  document can give a string where an object's `composition` block goes, a number in a list of
  objects, an object where a reference names its target, a list for an id, or no `uri`. What
  `ElementBuilder.__init__` reads of a `JsonDeserializationElement` -- id, class, compositions,
  references -- is therefore read without raising: each method reads what is as the format
  expects and leaves the rest out, and the optional `StructureReportingElement` protocol
  (`get_unread_structure`, `get_class_problem`) names what it left out, which `ElementBuilder`
  registers as one ERROR per part **with the part as `content`**. (`get_data_attributes` is read
  inside `compose`'s `try` and still raises for an enumeration pyDEXPI does not have, which is
  why that costs an object every data attribute.) So:

    - forgiving is not silent. A new place where the element skips something adds it to
      `get_unread_structure`; `FormatConverter`, which has no registry, raises for any such part
      so that `convert --fast` falls back to the route that reports it;
    - an element that names no class answers `get_dexpi_class()` with `""`, never with a name
      that might resolve, and the entry says what stands where the class goes;
    - an id that is no string still reaches validation, which refuses it like any value the class
      cannot hold (strict drops the object, lenient builds it with a generated id), so the loader
      keys its own lookups on `str` ids only;
    - `strict` does not change any of this: it decides about absent attributes and values the
      model cannot represent, not about a part that is not what the format expects. The one
      refusal is the conversion's, for a block it would itself have to drop (*Reading DEXPI 2.0*);
    - **the reference pass is the other place nothing tolerant surrounds.** It assigns what it
      resolved, the assignment is validated, and a list for a single reference, one id for a list
      or the id of an object of another class raised a bare `ValidationError` after every object
      was built -- from DEXPI XML too. `ElementBuilder._assign_reference` reports it and leaves
      the attribute as it was.

  `test_malformed_structure.py` sweeps every value of three documents through every kind of JSON
  value: 844 of those 2,784 loads raised before. Text that is not JSON at all still raises
  `json.JSONDecodeError`, as malformed XML raises: there is no document to report on.

  One thing this does **not** cover: the DEXPI XML element has the same kind of
  gap. A single reference with no target or several still raises a `ValueError` from
  `_package_return_type`, and an element the format does not expect -- a `<Components>` without
  `property`, an unknown value element -- is skipped without an entry.

  A document read in part must not look like a whole one, so every route says what the loader
  recorded: the MCP load tools return `loading_issues` with every load, and `cli._load_model`
  writes its one-line count to stderr for a strict load too whenever an entry is at ERROR or
  CRITICAL, where it wrote it only under `--lenient`. The exit code stays 0 and stdout
  stays the command's own output. A new command that loads a model goes through `_load_model`.

  The conversion's `remove_if_empty` deletes a model-level container it emptied only when it
  holds nothing (`null` or `[]`). A truthiness test there deleted `0`, `false` and `""` without
  an entry, which is a value the loader reports in a 2.0.1 document.
- **GraphML data values must be scalars.** `nx.write_graphml` raises `TypeError` on `None`,
  `dict`, `list` *and* `datetime`. Anything added to `G.graph` or to a node/edge attribute must be
  coerced to `str` / `int` / `float` / `bool` first, and absent values **omitted** rather than set
  to `None`. `toolkits.scalar_coercion.coerce_for_graph` is the one place that decides this, and
  `graph_loader._add_nodes`, `neo4j_export._coerce_value` and `model_provenance._collect` all defer
  to it. Returning `None` from it means *omit the key*, which is how `Undefined` stops
  becoming the string `"{}"`. Do not add a second implementation; extend the table and its test in
  `tests/test_toolkits/test_scalar_coercion.py`, which is the decision table written out.

  Two things it deliberately does not do. A `PhysicalQuantity` is **split** before it gets there —
  `graph_loader._quantity_attributes` makes `foo` and `foo_unit`, because one scalar cannot carry
  both and a range query needs the number. And structured values are dumped with
  `default=coerce_for_graph`, **not** `model_dump(mode="json")`: that renders
  `PhysicalQuantity.unit` as `"PressureGaugeUnit.Bar"` rather than `"Bar"`, because `unit` is
  annotated with the *memberless* `PhysicalQuantityUnit` base (a known quirk), so
  pydantic cannot match the member and falls back.

  The one place a type still differs by export path is the Neo4j CSV, on purpose: records carry a
  real `bool`, and `_csv_value` renders it lowercase `true`/`false` because `neo4j-admin import`
  reads the file as text.

  `graphml_export.normalize_graphml_attributes` is the check at the write boundary, called from
  `export_graphml_bytes` and from the CLI's own `nx.write_graphml`. It is deliberately **not** a
  fourth coercion: it normalises an `Enum` to its `.value` — the one conversion that cannot change
  meaning — and raises `GraphMLAttributeError` (a `TypeError`, so existing handlers still catch
  it) naming the element and attribute for everything else. It compares **exact types**, against
  `GraphMLWriter().xml_type` rather than a hard-coded tuple, because that is what the writer
  dispatches on: `isinstance` would pass a `str` subclass that then kills the document, and a
  hard-coded `(str, int, float, bool)` would refuse the numpy scalars networkx handles fine. `str()`-ing a `dict` or a `datetime`
  there would export cleanly and say something the model does not. In the enum case the
  exact-type dispatch in networkx means a `StrEnum` passed as the documented `graph_level: str`
  cost the whole document, so `stamp_graph_level` stores `.value` too.

  Note that one `attr.name` may legitimately carry different `attr.type`s across nodes — networkx
  keys `<key>` declarations on `(name, type, scope)` and simply emits two of them, which
  `nx.read_graphml` reads back correctly but downstream tools handle inconsistently. That is the
  reason `Undefined` is now **omitted** rather than encoded as the string `"{}"`: it used to land
  under the same attribute name that otherwise holds a `double`.
- **Attribute merges can split a value/unit pair.** `collapse_node_to_node` and
  `collapse_node_to_node_by_label` merge two nodes' attribute dicts with target-wins precedence.
  Because `QualifiedValue.value` may be a bare number or a `PhysicalQuantity`, the same name can be
  a bare number on one side and a split pair on the other, so a plain `{**source, **target}` would
  leave the winner's *number* standing next to the loser's *unit* — silently wrong, and queryable in
  Neo4j. `graph_loader._merge_node_attributes` enforces the rule: whoever supplies `<name>` supplies
  `<name>_unit` too, or neither does. `_collapsed_edge_attributes` and
  `remove_nodes_by_label(stitch=True)` copy a single node's dict wholesale and need no guard.
- **Text-mode writes translate line endings.** Python's text mode defaults to
  `newline=None`, which rewrites every `\n` to `os.linesep` — `\r\n` on Windows — so the
  file on disk is not the string that was written. Without `newline=""`, `save()` and
  `export_to_bytes()` disagree for one model on one machine and the output is
  platform-dependent — the cross-platform half of the reproducibility problem whose
  cross-*run* half is that a load mints fresh ids; both have to hold before "the same model always produces the same
  bytes" is true.

  The **document** paths pass `newline=""` and must keep doing so:
  `AbstractTreeReferenceSerializer.save` and `cli._convert_without_model`, which is why that
  one cannot use `Path.write_text`. (`load` is not affected any more: it reads bytes, so it and
  `load_from_bytes(path.read_bytes())` hand the parser the same input by construction.) Fixed and
  pinned by `tests/test_loaders/test_file_io.py`; note that its save-side assertions can
  only *fail* on a CRLF platform, so the `windows-latest` leg of the CI matrix is what makes
  them load-bearing -- and that leg runs only on a manual run (see *CI* under Commands), so
  trigger one for any change to how files are written.

  The **export** writers still take the default and are unfixed: `table_export`, `svg_export`,
  `neo4j_export`, `llm_context_export`, the graph branch of `cli.py`, and the two `syndata`
  writers. Same defect, wider blast radius (the CSV writers additionally want `newline=""` for
  `csv` module reasons), so it is a separate change rather than something to fold in here.
- **Warnings.** Do not introduce *new* warnings in the test suite. `filterwarnings = ["error"]`
  is the whole setting — **there are no `ignore:` exemptions**, and a new one needs a strong
  justification. The two that used to be there covered a piping-construction warning on
  correct external-connector calls; the check was narrowed instead, and the suite now runs
  fully strict. Verified across the full suite: 1633 passed, 9 skipped, 46 xfailed.

### Sample data and the corpus sweep

The documents under `data/` are covered by a parametrised load sweep in
`tests/test_roundtrip/test_corpus.py`. Dropping a new sample into a directory already listed in
`_CORPUS_ROOTS` extends coverage for free; adding a new *directory* takes a line there, which is
deliberate — it is a statement that the directory holds loadable DEXPI documents. The sweep is
non-recursive per root, so a directory's subfolders are not swept in by accident. `test_corpus_covers_every_root` pins at least one sample per root,
by its path below `data/` (also the test id, since two roots hold a `reference_pid.xml`), so a
moved file fails loudly instead of silently shrinking the sweep.

**There are two reference P&IDs, and both are needed.** `data/reference_pid.xml` (with its JSON)
is DEXPI **2.0**'s and `data/dexpi_2_0_1/reference_pid.xml` is the DEXPI **2.0.1** release's own
(`src/documentation/_static/reference_pid.xml` at tag `V2.0.1`), vendored byte-identical, marked
`-text`, with its hash pinned. The 2.0 one is the real-world input of the 2.0 -> 2.0.1 conversion
and what hundreds of tests are written against; replacing it would move their pins for reasons
unrelated to 2.0.1, so it stays as it is. The 2.0.1 one is the native document: it must load
strictly with an empty registry, validate without an issue and round-trip exactly, with no
conversion. `tests/test_roundtrip/test_reference_pid_2_0_1.py` pins all of that and, object by
object, everything that tells the two apart: the same 1,612 objects and 298 document ids, the 19
nozzles 2.0.1 types (17 `ProcessNozzle`, an `InstrumentNozzle`, an `AccessNozzle`), the release's
`ExportDateTime` (which a pyDEXPI export keeps, never overwriting), and eight real
`SymbolRegistrationNumber`s where the 2.0 copy has a placeholder. A change that moves one of
those is a 2.0.1 effect to explain in the same commit, not a pin to relax.

**The suite is written against the 2.0 one and runs on the native one in two ways.**
Because the two agree on every id, tag and coordinate, a test written against one runs on the
other unchanged, unless it names what differs. Running everything twice would double the suite's
time, so:

- **The differences, per input.** A test whose expectation names a nozzle's class, its caption
  ("Nozzle (N1)" against "Process Nozzle (N1)") or the release's `ExportDateTime` takes the
  `reference_pid` fixture (`ReferencePid.nozzle_class`, `.nozzle_caption`, `.version`) and is
  marked `tests.conftest.on_both_reference_pids`, which serves `loaded_example_dexpi` from each
  document in turn. The sensitive cases were found by running the suite with the native file
  copied over the 2.0 one; write `"Nozzle"`
  into a new expectation and the switch below is what finds it.
- **The whole suite, on demand.** `PYDEXPI_TEST_REFERENCE_PID=2.0.1` makes the native document what
  `loaded_example_dexpi`, `reference_pid_xml` and `tests.conftest.REFERENCE_PID_XML` serve, and the
  suite passes with it set as it does without. `PYDEXPI_TEST_REFERENCE_PID=2.0.1 pytest
  tests/test_docs` runs the skill's recipes on it, which CI does in its manual run. Take the file
  from those, not from `DATA_DIR / "reference_pid.xml"`, which is for a test about the 2.0 document
  itself (its bytes, its JSON twin, its `<Import>`s). The skill's example scripts run on both
  documents in every run.

The native document has the one `DateTime` value of the two, and that is how this was found: the
direct converter (`pydexpi convert --fast`) writes it back to XML as a `<String>`, which
`test_format_converter.py` pins with a strict `xfail` beside a test that nothing else is lost.

`data/reference_pid.xml` and `data/reference_pid.json` are the same P&ID in two formats and must
stay in step. They are DEXPI's reference P&ID from the DEXPI Specification 2.0 (CC BY 4.0; the
attribution, pyDEXPI's one content change to it and its otherwise XML-equivalent spelling are in
`NOTICE`), so the XML is a DEXPI 2.0 document: it declares the 2.0.0 model URIs, and the JSON
carries no `dexpiVersion` marker, so it is read as 2.0 too. The JSON is
generated from the XML (`JsonSerializer().save(model, "data", "reference_pid")`), and nothing
enforces that automatically — it had already drifted to an older
snapshot missing 47 graphical objects while the conceptual model still matched, so every check
that only looked at equipment and piping saw two identical files. Regenerate the JSON whenever
the XML changes;
`test_format_roundtrip.py::test_committed_reference_files_describe_the_same_document` is what
catches you if you forget. That test compares an object-type census, not `id_diff`: a load mints a
fresh `uuid4` per unidentified object, so two loads of one file already disagree by id.

`data/dexpi_2_0_1/synthetic_process.xml` and `.json` are the only native DEXPI 2.0.1 *process*
model: every real one in `data/` is a 2.0 document. They are **generated**, by
`data/dexpi_2_0_1/make_synthetic_process.py` with the generated classes and explicit ids, and hold
one of each 2.0.1 process construct the real files lack -- a `ProcessStepDetail` and an
`InstrumentationActivity` owning ports, a delegated port pair, roles owned by
`ProcessModel.roles`, a template with an ordered three-component list, a `MaterialState` composing
two phases and a state with percent fraction vectors, and `PortNodePosition` anchors. It also sets
every property the specification declares `Undefined | X` with multiplicity 1..1
(`REQUIRED_UNDEFINABLE`, twelve in the whole specification), several to an explicit `Undefined`:
the generated classes make those optional, so neither construction nor `validate()` notices one
left out, and only the fixture's own test checks them. Edit the
script and rerun it rather than editing the files:
`tests/test_roundtrip/test_synthetic_process_2_0_1.py` fails when the committed files and
`build_model()` disagree (`id_diff` and `model_digest`). Its strict load registers one WARNING
per cut of the required `Port` <-> `ProcessConnection` cycle, and nothing else; those are the
format's, not the fixture's (*Process models always contain a required-reference cycle*).

`data/exports/xvisual/pump_example.xml` is a third-party vendor export and is the only sample
exercising what a non-DEXPI-authored Proteus file looks like. It used to drop nearly all plant
content; since that was fixed its equipment, piping components and shapes load, and what is
still missing is missing from the file (no `Connection`, `CenterLine` or valve) -- see
`tests/test_roundtrip/test_xvisual_import.py`.

### The skill's workflow recipes execute in CI

`tests/test_docs/test_skill_workflows.py` collects every fenced Python block from
`.claude/skills/pydexpi/workflows.md` and executes each in a fresh namespace against the reference
P&ID, and holds every module a recipe imports, skipped ones too, to being installed. File aliases and exports live under the
test's temporary directory. A fragment requiring a caller's symbol resolver opts out on its first
line with `# recipe-test: skip - <reason>`; any other block, including a new one, executes
automatically. Do not opt out a self-contained command recipe to hide drift; fix the recipe and its
setup. Corpus cases must assert their counts per file, independently of test order and xdist
workers. Do not aggregate parametrized results in module globals: a shared counter passes only
when one worker happens to run all the relevant cases.

### Test paths must not depend on the working directory

`tests/conftest.py` defines `REPO_ROOT` / `DATA_DIR`, anchored on `Path(__file__)`, and exposes
them as the session fixtures `repo_root`, `data_dir`, `reference_pid_xml`, `dexpi_xsd` and
`training_test_cases_dir`. Reach for a fixture rather than writing `"data/reference_pid.xml"`,
which only resolves when pytest happens to be invoked from the repository root.
`reference_pid_xml` and the constant `REFERENCE_PID_XML` are the reference P&ID the session
serves, which `PYDEXPI_TEST_REFERENCE_PID=2.0.1` makes the DEXPI 2.0.1 release's (*Sample data and
the corpus sweep*).

Module-level constants consumed at import time (a `parametrize` argument, say) cannot take a
fixture, so those anchor locally with `Path(__file__).resolve().parents[N]` —
`tests/test_docs/test_skill_examples.py` and `tests/test_loaders/test_training_test_cases.py`
are the pattern. A subprocess that resolves its own relative paths, such as `mkdocs build`,
needs `cwd=REPO_ROOT` passed explicitly.

The check is simply that `cd tests && pytest .` produces the same result as `pytest tests` from
the root. It did not always.

### Keeping the suite fast

CI runs the suite under coverage, in parallel, on Python 3.14. On 3.13, where it ran
before, coverage could only trace, at about 2.5 times the cost of the same tests unmeasured; at
one point the test job took 23-40 minutes against about 9 for a plain local run, and one run was
cancelled at 99% of the then 45-minute `timeout-minutes`. On 3.14 coverage measures through
`sys.monitoring`, branches included, for almost nothing: on a slice of the suite, 50.5 s traced,
23.7 s monitored, 20.2 s unmeasured, with the two cores agreeing on every line and on all but 14 of
9,022 branches. `scripts/test` runs the suite on every CPU with `pytest-xdist`, and pytest-cov
combines the workers into one report; `PYTEST_WORKERS=0` runs it in one process. The time goes
where whole models are copied, walked and digested over and over -- the corpus sweeps above all --
so that is what the suite does cheaply. Keep to it in new tests:

- **The garbage collector runs less often.** `tests/conftest.py` raises CPython's first
  collection threshold to `GC_THRESHOLD` for the session. At the default, a collection started
  every few hundred microseconds while models were copied and walked a heap holding every
  collected test; that was about a third of the slowest modules' time. Nothing may depend on *when* a
  cycle is freed: a test that needs a collection calls `gc.collect()`, as `test_transports` does.
- **Repeated copies come from a snapshot.** `tests.conftest.copies_of(model)` pickles a model once
  and returns a function that unpickles a fresh copy per call: about half the cost of
  `copy.deepcopy`, and the same object graph (`test_base_models.TestPickledCopiesKeepIdentity`).
  `loaded_example_dexpi` is served that way. A loop that starts from one base per iteration --
  each end of a corpus sweep -- takes its copies from `copies_of`, and a sweep over a file copies
  one load rather than loading the file again per item.
- **Coverage taxes pure Python, not C.** Under coverage's tracer a pure-Python loop costs many
  times what it costs locally, while C code barely notices it, which is why an unpickle beats
  `copy.deepcopy` there. Before CPython 3.13, `json.dumps` with `indent` falls back to its
  pure-Python encoder: under coverage on 3.12 that made a `canonical_json_equality` of the
  reference P&ID take over a second, more than ten times its compact cost, until
  `pydexpi/hashing.py` serialized compactly. 3.13 encodes indented output in C, so CI's leg never
  paid that, which is the general caution: measure a slow module under
  `--cov --cov-report= --cov-fail-under=0` as well as without, and on the interpreter CI runs,
  before projecting what a change saves there.

`python -m pytest <module> --durations=30` shows where a module's time goes. None of this
removes a case, and nothing is behind a marker.

### xfail markers

Every `xfail` carries `strict=True` and a reason saying what defect it stands for. Strict is the
point: when the defect is fixed the marker becomes an unexpected pass, the build fails, and it
says "delete me". An `xfail` that names no defect is a permanent excuse — do not add one.

An `xfail` is also the wrong tool for a limitation that is not a defect. A *document* that does
not contain something is not a bug awaiting a fix; pin the measurement with a plain passing
assertion and explain it, as `tests/test_roundtrip/test_xvisual_import.py` does for the topology
and the valve table `pump_example.xml` has no `Connection`, `CenterLine` or valve to supply.
Those were `xfail`s until the import was fixed and it became clear the remaining
gaps belonged to the file.

## Releasing

Development happens here, in the private repository, and `.github/workflows/publish.yml` copies
`main` to the public repository's `master` as one commit, by hand (`workflow_dispatch`): no history
of this repository is published. The workflow prepares that commit, builds and checks the
distributions from it, and only then pushes, uploads to PyPI and creates the GitHub release, whose
notes are the version's section of `CHANGELOG.md`. Add that section first.

Everything in the tree goes public except `.github/workflows/` and `dependabot.yml`, so write
accordingly: do not cite issue numbers or commits of this repository, or anything else a public
reader cannot look up. The one workflow copied is `docs.yml`, which deploys the documentation from
the public repository to GitHub Pages when a release is published. It needs `PUBLIC_REPO_PAT` to
hold contents and workflows write access to the public repository.

The public API is the `__all__` of the modules in `docs/mkdocs/public-api.md`, which also states
the deprecation policy.

## Updating this file

If a convention changes, update `AGENTS.md` in the same PR. If the change resolves a known
issue, remove or retarget the note so the file stays
accurate.

If the change is to a *public API* rather than a convention, the skill under
`.claude/skills/pydexpi/` is what needs updating — its examples are executed by
`tests/test_docs/test_skill_examples.py`, so a breaking change turns that test red rather than
letting the documentation drift silently.
