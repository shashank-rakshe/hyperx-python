"""Export a model to Neo4j-compatible CSV, at a chosen graph abstraction level.

`export_neo4j_csv` writes two files -- nodes and relationships -- carrying the `:ID`,
`:LABEL`, `:START_ID`, `:END_ID` and `:TYPE` headers that Neo4j's importers expect. The same
pattern applies to the other exporters: pick a `graph_level`, call the `export_*` wrapper, or
call the `export_*_strings` / `export_*_bytes` variant if you want the payload in memory.

`:ID` is `[<id_namespace>:]<graph_level>:<sourceId>` -- namespaced by abstraction level
(`process:CentrifugalPump1`) so several levels can be loaded into one database, and optionally
by a caller-supplied `--id-namespace` (`dexpi-model-123:process:CentrifugalPump1`) so several
independent models can too. The raw DEXPI id travels alongside as `sourceId`, the level as
`graph_level`, and the namespace (when given) as `id_namespace`. pyDEXPI never generates the
namespace -- the caller owns it.

Run:
    python .claude/skills/pydexpi/examples/export_neo4j.py [MODEL] [--out DIR] [--level LEVEL]
        [--id-namespace NS]

MODEL defaults to data/reference_pid.xml. --out defaults to a fresh temporary directory.
"""

import argparse
import tempfile
from pathlib import Path

from pydexpi import load_xml_file
from pydexpi.exports import export_neo4j_csv, get_neo4j_records
from pydexpi.loaders.graph_loader import GRAPH_LEVELS, UNIT_ATTRIBUTE_SUFFIX

DEFAULT_MODEL = Path("data/reference_pid.xml")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", nargs="?", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--out", type=Path, default=None, help="Output directory.")
    parser.add_argument(
        "--level",
        default="process",
        # Every level the exporters take, from the one registry that defines them.
        choices=list(GRAPH_LEVELS),
        help="Graph abstraction level. For a P&ID: complete keeps everything, process collapses "
        "piping nodes, conceptual also drops equipment internals and nozzles. For a process "
        "model (a block flow diagram): process_flow, its steps and one relationship per "
        "connection, keyed by the connection's id, with a delegated port and what a measurement "
        "measures as relationships of their own.",
    )
    parser.add_argument(
        "--id-namespace",
        default=None,
        help="Caller-owned model namespace prefixed to every :ID, so several independent "
        "models can share one database. Omit for a single model.",
    )
    args = parser.parse_args()

    out_dir = args.out or Path(tempfile.mkdtemp(prefix="pydexpi-neo4j-"))

    model = load_xml_file(args.model)

    # get_neo4j_records gives the same data as dicts, without touching the filesystem -- useful
    # when you are feeding a driver rather than the bulk importer.
    records = get_neo4j_records(model, graph_level=args.level, id_namespace=args.id_namespace)
    print(f"Level {args.level}: {len(records.nodes)} nodes, {len(records.relationships)} edges")
    if not records.nodes:
        # A level is a view of one kind of model: a P&ID has no process steps, so its
        # process_flow graph is empty, and a process model has no P&ID levels to speak of.
        print(f"  Nothing at this level: {args.model} is not the kind of model it views.")
        return

    # Node identity is namespaced by level (and, when given, by --id-namespace),
    # so several levels -- and several models -- can share one database.
    first = records.nodes[0]
    print(f"  :ID={first[':ID']}  sourceId={first['sourceId']}  level={first['graph_level']}")
    if args.id_namespace:
        print(f"  id_namespace={first['id_namespace']}")

    # A PhysicalQuantity is split into two properties: the value as a real number, and its
    # unit under <attr>_unit. The value keeps its Python type here, so a driver writing these
    # records gets a numeric Neo4j property that range predicates can use.
    quantity = next(
        (
            (rec, key)
            for rec in records.nodes
            for key in rec
            if f"{key}{UNIT_ATTRIBUTE_SUFFIX}" in rec
        ),
        None,
    )
    if quantity is not None:
        rec, key = quantity
        value = rec[key]
        unit_key = f"{key}{UNIT_ATTRIBUTE_SUFFIX}"
        print(f"  {key}={value!r} ({type(value).__name__})  {unit_key}={rec[unit_key]!r}")

    # At process_flow a relationship's type says what it is: a connection's class (Stream,
    # InformationFlow, ...), "composition" for a sub-step or detail under its step and for an
    # activity under the control loop that composes it, "delegation" from a step to the sub-step
    # one of its ports is handed down to, and "measures" from a measurement to what it measures.
    # Every one has a key of its own in edgeKey.
    if args.level == "process_flow":
        by_type: dict[str, int] = {}
        for rel in records.relationships:
            by_type[rel[":TYPE"]] = by_type.get(rel[":TYPE"], 0) + 1
        print("  relationships: " + ", ".join(f"{n} {t}" for t, n in sorted(by_type.items())))
        for rel in records.relationships:
            if rel[":TYPE"] == "delegation":
                print(
                    f"  {rel[':START_ID']} hands port {rel['superPort']} down to "
                    f"{rel[':END_ID']} as {rel['subPort']}  (edgeKey={rel['edgeKey']})"
                )

    paths = export_neo4j_csv(
        model, out_dir, graph_level=args.level, prefix="plant_", id_namespace=args.id_namespace
    )
    for kind, path in paths.items():
        # The header is wide -- every scalar attribute across every node type becomes a
        # column, and a physical quantity contributes two: the value and its unit.
        columns = path.read_text(encoding="utf-8").splitlines()[0].split(",")
        print(f"\n{kind}: {path}")
        print(f"  {len(columns)} columns, starting {','.join(columns[:4])}")

    # Plain Cypher LOAD CSV does not understand :ID / :LABEL / :TYPE headers. Import these with
    # `neo4j-admin database import`, or with LOAD CSV plus APOC for dynamic labels. The module
    # docstring in pydexpi/exports/neo4j_export.py spells out both routes. Note that the CSV
    # stringifies every value, so quantities load as text on both routes -- cast them in Cypher
    # (toFloat) or use get_neo4j_records with a driver to keep the numeric type.
    print(
        f"\nImport with:  neo4j-admin database import full \\\n"
        f"    --nodes={paths['nodes']} --relationships={paths['relationships']} <dbname>"
    )


if __name__ == "__main__":
    main()
