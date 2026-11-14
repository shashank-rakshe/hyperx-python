import os, shutil
import pytest
from shipbrain import cadmpeg, engines, installs

HERE = os.path.dirname(os.path.abspath(__file__))
FC = os.path.join(HERE, 'data', 'cc0_geometry_topology.FCStd')     # cadmpeg corpus specimen, CC0-1.0


def test_routing_hint_and_formats():
    assert cadmpeg.is_native('a.SLDPRT') and cadmpeg.is_native('b.CATPart') and not cadmpeg.is_native('c.step')
    assert 'cad' in engines.classify('convert my solidworks sldprt to step')
    assert 'cadmpeg' in installs.SOFTWARE


def test_missing_program_says_how_to_install(monkeypatch):
    monkeypatch.setattr(cadmpeg, 'exe', lambda: None)
    with pytest.raises(RuntimeError, match='cadmpeg is not installed'):
        cadmpeg.inspect(FC)


@pytest.mark.skipif(cadmpeg.exe() is None, reason='needs the cadmpeg program')
def test_freecad_to_step_measure_diff(tmp_path):
    src = str(tmp_path / 'part.FCStd')
    shutil.copy(FC, src)
    assert 'L5' in cadmpeg.inspect(src)['plain_english']
    r = cadmpeg.to_step(src)
    assert os.path.exists(r['file']) and r['geometry_transferred'] is True and 'Check: OK' in r['plain_english']
    m = cadmpeg.measure(src, density=7850)
    assert abs(sum(b.get('volume_mm3') or 0 for b in m['bodies'] if b.get('kind') == 'solid') - 14656.2) < 1
    from shipbrain.cadplates import import_cad                       # native files go straight into the CAD tools
    assert import_cad(src).isValid()
