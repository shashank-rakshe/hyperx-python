"""Tests for the GraphML→CIR converter (datasets.preparers.graphml_cir), per ADR-0012."""

from __future__ import annotations

import cir
from cir import DrawingSet, EntityType
from datasets.preparers.graphml_cir import graphml_to_cir

# Faithful to real PID2Graph: two bbox encodings with DIFFERENT key orders —
# d1..d4 (double) = [xmin, xmax, ymin, ymax]; d5..d8 (long) = [xmin, ymin, xmax, ymax].
_GRAPHML = """<?xml version='1.0' encoding='utf-8'?>
<graphml xmlns="http://graphml.graphdrawing.org/xmlns">
  <key id="d0" for="node" attr.name="label" attr.type="string"/>
  <key id="d1" for="node" attr.name="xmin" attr.type="double"/>
  <key id="d2" for="node" attr.name="xmax" attr.type="double"/>
  <key id="d3" for="node" attr.name="ymin" attr.type="double"/>
  <key id="d4" for="node" attr.name="ymax" attr.type="double"/>
  <key id="d5" for="node" attr.name="xmin" attr.type="long"/>
  <key id="d6" for="node" attr.name="ymin" attr.type="long"/>
  <key id="d7" for="node" attr.name="xmax" attr.type="long"/>
  <key id="d8" for="node" attr.name="ymax" attr.type="long"/>
  <key id="d9" for="edge" attr.name="edge_label" attr.type="string"/>
  <graph edgedefault="undirected">
    <node id="valve1"><data key="d0">valve</data><data key="d1">10</data>
      <data key="d2">30</data><data key="d3">20</data><data key="d4">40</data></node>
    <node id="conn1"><data key="d0">connector</data><data key="d5">50</data>
      <data key="d6">60</data><data key="d7">54</data><data key="d8">64</data></node>
    <node id="bg1"><data key="d0">background</data><data key="d1">0</data>
      <data key="d2">5</data><data key="d3">0</data><data key="d4">5</data></node>
    <edge source="valve1" target="conn1"><data key="d9">solid</data></edge>
    <edge source="valve1" target="bg1"><data key="d9">solid</data></edge>
  </graph>
</graphml>
"""


def _fixture(tmp_path):
    from PIL import Image

    gp = tmp_path / "7.graphml"
    gp.write_text(_GRAPHML)
    Image.new("RGB", (100, 100), "white").save(tmp_path / "7.png")
    return gp, tmp_path / "7.png"


def test_graphml_to_cir_nodes_edges_roles_and_norm(tmp_path) -> None:
    gp, img = _fixture(tmp_path)
    ds = graphml_to_cir(gp, img, slug="pid2graph", slice_name="complete/open100", real=True)

    ents = {e.id: e for e in ds.iter_entities()}
    assert set(ents) == {"valve1", "conn1"}  # background dropped
    assert ents["valve1"].entity_type is EntityType.SYMBOL
    assert ents["conn1"].entity_type is EntityType.GRAPH_NODE
    assert ents["conn1"].attributes["node_role"] == "connector"

    # double set d1..d4=[xmin,xmax,ymin,ymax]: (10,30,20,40) -> box (10,20,30,40) on 100x100
    #   -> normalized center (0.2, 0.3)
    box = ents["valve1"].geometry.bounds()
    assert abs(box.center.x - 0.20) < 1e-9 and abs(box.center.y - 0.30) < 1e-9
    # long set d5..d8=[xmin,ymin,xmax,ymax]: (50,60,54,64) -> center (52,62) -> (0.52, 0.62)
    cbox = ents["conn1"].geometry.bounds()
    assert abs(cbox.center.x - 0.52) < 1e-9 and abs(cbox.center.y - 0.62) < 1e-9

    conns = [c for s in ds.sheets for v in s.views for c in v.connections]
    assert len(conns) == 1  # the edge to the dropped background node is dropped
    assert conns[0].connection_type == "solid" and conns[0].directed is False
    assert ds.metadata["slice"] == "complete/open100" and ds.metadata["real"] is True
    assert ds.data_lane.value == "research" and ds.license_provenance.value == "CC-BY-SA"


def test_graphml_cir_roundtrips_on_disk(tmp_path) -> None:
    gp, img = _fixture(tmp_path)
    ds = graphml_to_cir(gp, img, slug="pid2graph", slice_name="complete/open100", real=True)
    path = tmp_path / "out.cir"
    cir.save(ds, str(path))
    restored = cir.load(DrawingSet, str(path))
    assert restored == ds
