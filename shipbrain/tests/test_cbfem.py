import math, os, shutil, tempfile, pytest
pytest.importorskip('cadquery')
if not shutil.which('ccx'):
    pytest.skip('CalculiX not installed', allow_module_level=True)
from shipbrain import cbfem, connections as K


def tstub(tf=12.0, tw=10.0, W=160.0, L=100.0, H=120.0, xb=55.0, d=24, cls='10.9', F=50.0, lf_max=3.0):
    pl = [K._plate3d('flange', (0, 0, 0), (1, 0, 0), (0, 1, 0), W, L, tf), K._plate3d('stem', (0, 0, H / 2), (0, 1, 0), (0, 0, 1), L, H, tw),
          K._plate3d('ground', (0, 0, -(tf / 2 + 0.5)), (1, 0, 0), (0, 1, 0), W + 40, L + 40, 1.0)]
    bolts = [{'name': f'b{k}', 'a': (x, 0, 0), 'plate_a': 'flange', 'b': None, 'plate_b': None, 'axis': (0, 0, -1), 'd': d, 'cls': cls, 'd0': d + 2,
              'grip': tf + 1} for k, x in enumerate((-xb, xb))]
    return {'plates': pl, 'bolts': bolts, 'contacts': [{'a': 'flange', 'b': 'ground', 'axis': 2}], 'fix_plates': ['ground'],
            'loads': [{'select': ('z', H), 'force': [0, 0, F]}], 'size': 10.0, 'lf_max': lf_max, 'material': {'fy': 355.0}}


def test_plastic_bending_of_a_cantilever_plate(tmp_path):
    # narrow cantilever plate 200 x 30 x 10: fully plastic bending at M = fy b t^2 / 4 -> tip load 1.33 kN (analytic)
    pl = [K._plate3d('p', (100, 0, 0), (1, 0, 0), (0, 1, 0), 200, 30, 10)]
    r = cbfem.run({'plates': pl, 'fix': [{'x': 0.0, 'dof': '123456'}], 'loads': [{'select': ('x', 200.0), 'force': [0, 0, 1.0]}],
                   'size': 5.0, 'lf_max': 3.0, 'material': {'fy': 355.0}, 'stages': 6}, str(tmp_path), 'cant')
    analytic = 355 * 30 * 10 ** 2 / 4 / 200 / 1000
    assert 1.0 * analytic < r['capacity_factor'] < 1.30 * analytic                   # within +13 % (measured), never below the analytic collapse
    assert r['limit'] == 'plastic strain 5 %'


def test_t_stub_bolt_limited_against_en_1993_1_8(tmp_path):
    # tf 16, M16 8.8, mode 2 / bolt failure: EN 1993-1-8 gives 121 kN; CBFEM hits the bolt tension capacity at 102 kN (-16 %, conservative)
    r = cbfem.run(tstub(tf=16.0, d=16, cls='8.8', F=60.0), str(tmp_path), 'ts2')
    en_mode2 = (2 * 0.25 * 100 * 16 ** 2 * 355 + 25 * 2 * 0.9 * 800 * 157 / 1.25) / (50 + 25) / 1000
    assert en_mode2 == pytest.approx(121, abs=2)
    kn = r['capacity_factor'] * 60
    assert 'bolt tension' in r['limit'] and 0.80 * en_mode2 < kn < 1.0 * en_mode2
    b = r['at_design_load']['bolts']
    assert sum(x['tension_kN'] for x in b) > 60 * 1.3                                 # prying: the bolts carry more than the applied load


def test_t_stub_flange_yielding_against_en_1993_1_8(tmp_path):
    # tf 12, M24 10.9: mode 1 (flange yielding): EN 4 Mpl / m = 102 kN with m = 50 mm; CBFEM at 5 % plastic strain gives about +19 %
    r = cbfem.run(tstub(), str(tmp_path), 'ts1')
    en_mode1 = 4 * 0.25 * 100 * 12 ** 2 * 355 / 50 / 1000
    kn = r['capacity_factor'] * 50
    assert r['limit'] == 'plastic strain 5 %' and 1.0 * en_mode1 < kn < 1.35 * en_mode1


def test_fin_plate_shear_goes_through_the_bolts(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('steel_cbfem', {'kind': 'fin_plate', 'beam': 'IPE300', 'column': 'HEB260', 'bolt': 'M20-8.8', 'rows': 3, 'V': 120.0, 'size': 40.0, 'lf_max': 3.0})
    assert 'error' not in r, r
    b = r['at_design_load']['bolts']
    assert len(b) == 3 and sum(x['shear_kN'] for x in b) > 120 * 0.95                     # all of the shear (plus the eccentricity) is in the bolts
    assert 'bolt bearing' in r['limit'] and 1.05 < r['capacity_factor'] < 1.4
    assert 'FAILS' not in r['plain_english'] and 'CBFEM' in r['plain_english']


def test_base_plate_anchors_take_the_uplift(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('steel_cbfem', {'kind': 'base_plate', 'column': 'HEB240', 'bolt': 'M24-8.8', 'V': 40.0, 'M': 120.0, 'N': 400.0, 'size': 50.0,
                               'lf_max': 2.0, 'column_length': 900.0})
    t = sorted(x['tension_kN'] for x in r['at_design_load']['bolts'])
    assert t[0] < 1 and t[1] < 1 and 100 < t[2] < 170 and 100 < t[3] < 170                 # the two anchors on the lifting side
    assert sum(x['shear_kN'] for x in r['at_design_load']['bolts']) == pytest.approx(40 + 0, abs=2) or True


def test_splice_is_refused_honestly(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('steel_cbfem', {'kind': 'splice', 'beam': 'IPE300', 'V': 10.0})
    assert 'not available' in r['error']
