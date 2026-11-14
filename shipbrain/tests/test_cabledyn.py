import math
import pytest
from shipbrain import cabledyn


def test_chain_properties_match_cabledyn_example():
    c = cabledyn.chain(140, 'R3')                  # CableDyn's examples/wd0050_chain.dat: 0.252 m, 390 kg/m, 1.674e9 N
    assert abs(c['diam_m'] - 0.252) < 1e-9 and abs(c['mass_kg_m'] - 390.0) < 0.1 and abs(c['EA_N'] - 1.674e9) / 1.674e9 < 1e-3
    assert abs(c['MBL_N'] / 1e3 - 14336) < 1                                  # 0.0223 d^2 (44 - 0.08 d) kN
    with pytest.raises(ValueError):
        cabledyn.chain(84, 'R9')


def test_too_short_line_refused(tmp_path):
    with pytest.raises(ValueError, match='shorter than the straight distance'):
        cabledyn.mooring(200, 400, 390, d_mm=84, workdir=str(tmp_path))


@pytest.mark.skipif(cabledyn.driver() is None, reason='needs the CableDyn driver')
def test_catenary_against_hand_formula(tmp_path):
    r = cabledyn.mooring(100, 600, 520, d_mm=76, workdir=str(tmp_path), name='m')
    lt = r['line']
    w = lt['mass_kg_m'] * 9.80665 - 1025 * math.pi / 4 * lt['diam_m'] ** 2 * 9.80665   # submerged weight N/m
    T, a = r['fairlead_tension_kN'] * 1e3, math.radians(r['fairlead_inclination_deg'])
    H = T * math.cos(a)
    s = math.sqrt(100 ** 2 + 2 * 100 * H / w)                                     # inextensible catenary, suspended length
    assert abs(s - r['touchdown_arc_m']) < 0.08 * s
    assert r['ok'] and r['grounded_length_m'] > 0 and 'API RP 2SK' in r['plain_english']
