import math, os, pytest
pytest.importorskip('cadquery')
from shipbrain import piperoute

LEGS = [{'dir': 'east', 'length': 1000}, {'dir': 'north', 'length': 800}, {'dir': 'up', 'length': 600}]


def test_volume_matches_analytic_and_cadcore(tmp_path):
    r = piperoute.route(legs=LEGS, od=100, bend='SR' if False else 200, out=str(tmp_path / 'p.step'))
    # centre-line radius 200 mm -> 2 bends; analytic solid rod volume
    cl = 1000 + 800 + 600 - 2 * (2 * 200 - math.pi / 2 * 200)
    assert r['centreline_length_mm'] == pytest.approx(cl, abs=0.2)
    assert r['volume_mm3'] == pytest.approx(math.pi * 50 ** 2 * cl, rel=1e-4)
    assert r['volume_mm3'] == pytest.approx(17501172.7, rel=1e-4)   # independent kernel (cadcore) result
    assert r['valid'] and os.path.exists(r['file'])


def test_errors():
    with pytest.raises(ValueError, match='too short|long but'):
        piperoute.route(legs=[{'dir': 'east', 'length': 1000}, {'dir': 'up', 'length': 200}, {'dir': 'north', 'length': 1000}], od=100, bend=200)
    with pytest.raises(ValueError, match='unknown direction'):
        piperoute.route(legs=[{'dir': 'sideways', 'length': 100}], od=50)
    with pytest.raises(ValueError, match='turns back'):
        piperoute.route(legs=[{'dir': 'east', 'length': 2000}, {'dir': 'west', 'length': 2000}], od=50)


def test_hollow_mass_and_flow_input():
    r = piperoute.route(legs=[{'dir': 'east', 'length': 3000}], od=168.3, wall=7.1)
    area = math.pi / 4 * (168.3 ** 2 - 154.1 ** 2)
    assert r['mass_kg'] == pytest.approx(area * 3000 * 1e-9 * 7850, rel=1e-3)
    seg = r['pipe_flow_input']['segments'][0]
    assert seg['d_mm'] == 154.1 and seg['length_m'] == 3.0 and seg['fittings'] == {}


def test_bends_become_fittings():
    r = piperoute.route(legs=LEGS, od=100, wall=5)
    assert r['pipe_flow_input']['segments'][0]['fittings'] == {'long_radius_90_deg': 2}
    assert r['pipe_flow_input']['segments'][0]['rise_m'] == 0.6
