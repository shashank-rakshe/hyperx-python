import os, re
import pytest
from shipbrain import moose


def test_navier_matches_moose_reference():
    # MOOSE's clamped_plate_flat.i quotes 2.998535904e-03 m (16 terms) for this plate
    assert abs(moose.navier(50, 50, 1, 1e9, 0.3, 10.816, terms=4) - 2.998535904e-3) / 2.998535904e-3 < 2e-5


def test_mesh_and_input_written(tmp_path):
    nodes, quads = moose.plate_mesh(2000, 800, 20, 8)
    msh = moose.write_msh(nodes, quads, str(tmp_path / 'p.msh'))
    text = open(msh).read()
    assert '$MeshFormat\n2.2 0 8' in text and '2 1 "shell"' in text and text.count('\n') > len(nodes) + len(quads)
    inp = moose.plate_input(msh, 12, 206000, 0.3, 0.05, {'e1': ((0, 0), (2000, 0))}, 2000, 800, out=str(tmp_path / 'p.i'))
    s = open(inp).read()
    assert "top_right = '2000.002 0.002 0.002'" in s                       # full precision, not rounded to 2000
    for obj in ('ADStressDivergenceShell', 'ADComputeIncrementalShellStrain', 'BoundingBoxNodeSetGenerator', 'NodalExtremeValue'):
        assert obj in s
    assert s.count('[') == s.count(']')


def test_missing_moose_says_how(monkeypatch, tmp_path):
    monkeypatch.setattr(moose, 'exe', lambda: None)
    with pytest.raises(RuntimeError, match='docker pull idaholab/moose'):
        moose.run(str(tmp_path / 'x.i'))
