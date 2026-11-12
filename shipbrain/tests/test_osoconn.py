import glob, os, shutil, pytest
if not (shutil.which('cmake') and shutil.which('g++')):
    pytest.skip('cmake / g++ not installed', allow_module_level=True)
from shipbrain import osoconn as O

EX = os.path.join(O.CLA, 'examples')


def load_cin(path):
    P, units, method = {}, 'NEWTON_MM', 'LRFD'
    for ln in open(path):
        w = ln.split()
        if len(w) < 2 or ln.startswith('*'):
            continue
        if w[0] == 'UNITS':
            units = w[1]
        elif w[0] == 'METHOD':
            method = w[1]
        elif w[0] not in ('CONNECTION_CODE', 'CONNECTION_ID'):
            P[w[0]] = w[1]
    return P, units, method


@pytest.mark.parametrize('kind,code,folder,n', [('shear_clip_angle', 'SC001AM10', 'SC001', 1), ('moment_end_plate', 'MC001AM10', 'MC001', 1),
                                                ('vertical_brace', 'VB001AM10', 'VB001', 1), ('horizontal_brace', 'HB001AM10', 'HB001', 1)])
def test_upstream_examples_reproduce(tmp_path, kind, code, folder, n):
    cin = os.path.join(EX, folder, code, f'{folder}_{n}.cin')
    P, units, method = load_cin(cin)
    r = O.run(kind, P, method=method, units=units, workdir=str(tmp_path))
    up = O.parse_output(open(cin[:-4] + '.cou').read())
    assert r['ok'] == up['ok']
    assert r['max_ratio'] == pytest.approx(up['max_ratio'], abs=1e-3)
    assert len(r['checks']) == len(up['checks']) > 10
    assert r['governing']['ratio'] == pytest.approx(max(c['ratio'] for c in up['checks']), abs=2e-3)


def test_metric_moment_connection_and_errors(tmp_path):
    P = {'SHEAR_FORCE': 150000, 'COLUMN_AXIAL_FORCE': 600000, 'MODULUS_OF_ELASTICITY': 200000, 'STEEL_GRADE_OF_PLATE': 'A36',
         'STEEL_GRADE_OF_BEAM': 'A36', 'STEEL_GRADE_OF_COLUMN': 'A36', 'WELD_ELECTRODE': 'E70', 'BOLT_GRADE': 'A325', 'PLATE_WIDTH': 300,
         'PLATE_HEIGHT': 550, 'PLATE_THICKNESS': 25, 'CONFIGURATION': '4_BOLTS', 'BEAM_SECTION': 'W360X44', 'COLUMN_SECTION': 'W410X149',
         'BOLT_DIAMETER': 'M30', 'BOLT_GAGE': 140, 'INNER_BOLT_TO_FLANGE': 45, 'OUTER_BOLT_TO_FLANGE': 45, 'WEB_WELD': 6,
         'FLANGE_WELD_REINFORCEMENT': 4, 'COLUMN_STIFFENER': 'YES', 'DOUBLER_PLATE': 'NO', 'COLUMN_STIFFENER_THICKNESS': 25,
         'COLUMN_STIFFENER_WIDTH': 100, 'COLUMN_STIFFENER_CLIP': 25, 'COLUMN_STIFFENER_TO_FLANGE_WELD': 12,
         'COLUMN_STIFFENER_TO_WEB_WELD': 6, 'DISTANCE_TO_COLUMN_TOP': 75}
    r = O.run('moment_end_plate', P, workdir=str(tmp_path))
    assert r['ok'] is False and 1.0 < r['max_ratio'] < 1.2 and r['governing']['check'] == 'plate thickness'
    P['PLATE_THICKNESS'] = 32
    assert O.run('moment_end_plate', P, workdir=str(tmp_path), name='thick')['max_ratio'] < 1.04
    with pytest.raises(ValueError, match='Expecting values'):
        O.run('moment_end_plate', dict(P, BOLT_DIAMETER='M99'), workdir=str(tmp_path))
    with pytest.raises(ValueError, match='unknown input'):
        O.run('shear_clip_angle', {'FOO': 1}, workdir=str(tmp_path))
    with pytest.raises(ValueError, match='Invalid section|Missing input parameter'):
        O.run('shear_clip_angle', {'SHEAR_FORCE': 1000, 'BOLT_DIAMETER': 'M22'}, workdir=str(tmp_path))


def test_aisc_sections_feed_the_connection_builder():
    from shipbrain import connections as K
    s = O.aisc_section('W14X30')
    assert s['h'] == pytest.approx(13.8 * 25.4) and s['tw'] == pytest.approx(0.27 * 25.4)
    assert K.section('W310X74') == {'name': 'W310X74', 'h': 310.0, 'b': 205.0, 'tw': 9.4, 'tf': 16.3}
    c = K.build('end_plate', beam='W360X44', column='W410X149')
    assert c.clashes == [] and c.info['beam'] == 'W360X44'
