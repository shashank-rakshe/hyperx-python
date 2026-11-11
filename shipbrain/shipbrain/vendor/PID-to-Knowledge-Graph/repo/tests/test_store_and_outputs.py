import json
import subprocess
import sys

import duckdb

from conftest import FIXTURES, SCRIPTS
from pidkg.store import write_duckdb
from pidkg.summary import write_summary


def test_duckdb_views_and_macros(mini_kg, tmp_path):
    db = tmp_path / "graph.duckdb"
    write_duckdb(mini_kg, db)
    con = duckdb.connect(str(db), read_only=True)
    down = {r[0] for r in con.execute("SELECT id FROM downstream('TK-100') WHERE type='Equipment'").fetchall()}
    assert {"P-101", "TK-200"} <= down
    up = {r[0] for r in con.execute("SELECT id FROM upstream('TK-200') WHERE type='Equipment'").fetchall()}
    assert {"P-101", "TK-100"} <= up
    loops = dict(con.execute("SELECT loop, loop_type FROM loops").fetchall())
    assert loops["F-101"] == "control"
    flow = con.execute("SELECT tag, measures_label FROM instruments WHERE tag = 'LT-200'").fetchone()
    assert flow == ("LT-200", "TK-100")
    assert con.execute("SELECT count(*) FROM equipment_flow").fetchone()[0] >= 4


def test_graph_traversal(mini_graph):
    ups = [n for n, _ in mini_graph.walk("FV-101", "up")]
    assert "P-101" in ups and "TK-100" in ups
    path = mini_graph.path("TK-100", "TK-200")
    assert path[0] == "TK-100" and path[-1] == "TK-200"
    assert mini_graph.find("fic 101") == "FIC-101"


def test_summary_mentions_key_facts(mini_kg):
    md = write_summary(mini_kg)
    assert "**P-101** (Transfer pump) → **TK-200** (Product tank)" in md
    assert "Cascade slave of L-200" in md
    assert "in-line on 3\"-PW-002" in md


def test_cli_end_to_end(tmp_path):
    out = tmp_path / "kg"
    r = subprocess.run([sys.executable, str(SCRIPTS / "build_kg.py"), str(FIXTURES / "mini_plant"),
                        "--out", str(out), "--plant-name", "Mini"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    for f in ("graph.json", "graph.duckdb", "summary.md", "qa_report.md"):
        assert (out / f).exists()
    q = subprocess.run([sys.executable, str(SCRIPTS / "kg_query.py"), str(out), "downstream", "TK-100",
                        "--equipment", "--json"], capture_output=True, text=True)
    assert q.returncode == 0, q.stderr
    labels = {i["label"] for i in json.loads(q.stdout)["items"]}
    assert "TK-200" in labels
    for fmt in ("graphml", "neo4j"):
        e = subprocess.run([sys.executable, str(SCRIPTS / "export.py"), str(out), fmt],
                           capture_output=True, text=True)
        assert e.returncode == 0, e.stderr
    assert (out / "graph.graphml").exists()
    assert (out / "neo4j" / "import.cypher").exists()


def test_committed_schemas_are_current():
    from pidkg.models import KnowledgeGraph, PageExtraction

    schema_dir = SCRIPTS.parent / "references" / "schema"
    for name, model in (("extraction.schema.json", PageExtraction), ("graph.schema.json", KnowledgeGraph)):
        committed = json.loads((schema_dir / name).read_text(encoding="utf-8"))
        committed.pop("$schema", None)
        assert committed == model.model_json_schema(by_alias=True), \
            f"{name} is stale: run build_kg.py --write-schemas"
