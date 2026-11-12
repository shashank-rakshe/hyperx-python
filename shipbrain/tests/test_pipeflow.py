import math
import pytest
from shipbrain import pipeflow as pf


def _colebrook(Re, eD):
    f = 0.02
    for _ in range(100):
        f = (-2 * math.log10(eD / 3.7 + 2.51 / (Re * math.sqrt(f)))) ** -2
    return f


def test_single_pipe_matches_hand_darcy_colebrook():
    r = pf.line(3.6, [{'d_mm': 50, 'length_m': 20}], 'seawater')
    rho, nu = 1024.8, 1.054e-6
    v = 0.001 / (math.pi * 0.05 ** 2 / 4)
    f = _colebrook(v * 0.05 / nu, 0.045e-3 / 0.05)                 # carbon steel 0.045 mm
    assert abs(r['pressure_drop_Pa'] - f * 20 / 0.05 * rho * v * v / 2) < 1.0


def test_elevation_laminar_and_parallel():
    r = pf.line(3.6, [{'d_mm': 50, 'length_m': 20, 'rise_m': 8}], 'seawater')
    assert abs(r['segments'][0]['elevation_Pa'] - 1024.8 * 9.80665 * 8) < 1.0
    r = pf.line(3.6, [{'d_mm': 50, 'length_m': 20}], 'lube oil')     # 100 cSt: Re 255, laminar
    v = 0.001 / (math.pi * 0.05 ** 2 / 4)
    assert abs(r['segments'][0]['friction_factor'] - 64 / (v * 0.05 / 100e-6)) < 1e-4 and 'laminar' in r['plain_english']
    r = pf.line(60, [{'d_mm': 125, 'length_m': 10}], 'seawater', branches=[[{'d_mm': 80, 'length_m': 6}], [{'d_mm': 80, 'length_m': 6}]])
    vb = [s['velocity_m_s'] for s in r['segments'] if s['name'].startswith('B')]
    assert len(vb) == 2 and abs(vb[0] - vb[1]) < 1e-3 and abs(vb[0] - 30 / 3600 / (math.pi * 0.08 ** 2 / 4)) < 2e-3


def test_fittings_counted_and_checked():
    plain = pf.line(3.6, [{'d_mm': 50, 'length_m': 20}], 'fresh water')['pressure_drop_Pa']
    glob = pf.line(3.6, [{'d_mm': 50, 'length_m': 20, 'fittings': {'globe_valve': 1}}], 'fresh water')['pressure_drop_Pa']
    v = 0.001 / (math.pi * 0.05 ** 2 / 4)
    assert abs((glob - plain) - 10.0 * 998.2 * v * v / 2) < 1.0      # globe valve K = 10
    with pytest.raises(ValueError, match='unknown fitting'):
        pf.line(3.6, [{'d_mm': 50, 'length_m': 20, 'fittings': {'butterfly': 1}}])
    with pytest.raises(ValueError, match='unknown fluid'):
        pf.line(3.6, [{'d_mm': 50, 'length_m': 20}], 'mercury')
