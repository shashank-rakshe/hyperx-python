import numpy as np
from shipbrain import elemquality as eq
from shipbrain.femodel import FEModel


def test_perfect_square_and_triangle():
    q = eq.element([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]])
    assert q['aspect'] == 1 and q['skew'] < 1e-9 and q['warpage'] == 0 and abs(q['jacobian'] - 1) < 1e-9 and q['taper'] < 1e-9
    t = eq.element([[0, 0, 0], [1, 0, 0], [0.5, 3 ** 0.5 / 2, 0]])
    assert abs(t['tria_min_angle'] - 60) < 1e-6 and t['skew'] < 1e-6


def test_bad_elements_are_caught():
    warped = eq.element([[0, 0, 0], [1, 0, 0], [1, 1, 0.3], [0, 1, 0]])
    assert warped['warpage'] > 10
    collapsed = eq.element([[0, 0, 0], [1, 0, 0], [2, 0, 0], [0, 1, 0]])      # a 180 deg corner
    assert collapsed['jacobian'] <= 0.0 and collapsed['quad_max_angle'] > 179


def _model(tmp_path):
    m = FEModel()
    for i in range(3):
        for j in range(3):
            m.nodes[i * 3 + j + 1] = np.array([j * 100.0, i * 100.0, 0.0])
    m.nodes[5] = np.array([100.0, 100.0, 40.0])                               # one warped node
    k = 1
    for i in range(2):
        for j in range(2):
            a = i * 3 + j + 1
            m.elems[k] = {'type': 'quad', 'nodes': [a, a + 1, a + 4, a + 3], 'pid': 1, 'group': '1'}
            k += 1
    m.props[1] = {'kind': 'shell', 'mid': 1, 't': 10.0}
    m.mats[1] = {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9}
    m.spc = {1: '123456'}
    m.loads = [{'type': 'pressure', 'elems': [1, 2], 'p': 0.01}]
    return m


def test_quality_criteria_and_sets(tmp_path):
    m = _model(tmp_path)
    q = eq.quality(m)
    assert q['checks']['warpage']['n_fail'] == 4 and q['failed_elements'] == 4
    q2 = eq.quality(m, criteria={'warpage': [30, 40]})
    assert q2['checks']['warpage']['n_fail'] == 0
    p = str(tmp_path / 'm.inp')
    m.write(p)
    r = eq.check_file(p)
    assert r['failed_sets_file'].endswith('_failed.inp') and 'FAIL_WARPAGE' in open(r['failed_sets_file']).read()


def test_model_check_and_fem_roundtrip(tmp_path):
    m = _model(tmp_path)
    assert eq.model_check(m)['errors'] == 0
    m.props[1]['t'] = 0.0
    m.elems[5] = dict(m.elems[1])
    mc = eq.model_check(m)
    assert mc['errors'] == 2 and 'thickness' in mc['plain_english'] and 'duplicate' in mc['plain_english']
    m = _model(tmp_path)
    p = str(tmp_path / 'm.fem')
    m.write(p)
    text = open(p).read()
    assert 'CEND' not in text and 'SOL 101' not in text and 'CQUAD4' in text
    back = FEModel.read(p)
    assert len(back.elems) == 4 and back.props[1]['t'] == 10.0 and back.spc and back.loads
