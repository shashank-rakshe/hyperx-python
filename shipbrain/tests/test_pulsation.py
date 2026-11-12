import math, pytest
pytest.importorskip('h5py')
pytest.importorskip('ordered_set')
from shipbrain import pulsation as PU

C_AIR = 343.395034


def test_closed_and_open_air_column(tmp_path):
    r = PU.analyse(legs=[{'dir': 'east', 'length': 2000}], od_mm=100, wall_mm=8, fluid='air', analyses=('acoustic',), modes=6,
                   element_mm=10, workdir=str(tmp_path), name='cc')
    f = r['acoustic_natural_frequencies_hz']
    assert f[0] == pytest.approx(C_AIR / 4, abs=0.01)                                    # n c / 2L, L = 2 m
    assert f[2] == pytest.approx(3 * C_AIR / 4, rel=5e-4)
    r = PU.analyse(legs=[{'dir': 'east', 'length': 2000}], od_mm=100, wall_mm=8, fluid='air', analyses=('acoustic',), modes=6,
                   element_mm=10, open_ends=[-1], workdir=str(tmp_path), name='oc')
    assert r['acoustic_natural_frequencies_hz'][0] == pytest.approx(C_AIR / 8, abs=0.01)   # (2n - 1) c / 4L, output rounded to 0.01 Hz


def test_water_column_with_wall_flexibility(tmp_path):
    r = PU.analyse(legs=[{'dir': 'east', 'length': 2000}], od_mm=100, wall_mm=8, fluid='water', analyses=('acoustic',), modes=6,
                   element_mm=10, open_ends=[-1], workdir=str(tmp_path), name='w')
    c0 = 1482.3
    ce = c0 / math.sqrt(1 + 0.084 * 998.2 * c0 ** 2 / (210e9 * 0.008))                  # Lin & Morgan / Korteweg
    assert r['speed_of_sound_in_pipe_m_s'] == pytest.approx(ce, abs=0.1)
    assert r['acoustic_natural_frequencies_hz'][0] == pytest.approx(ce / 8, abs=0.01)
    assert 'wall flexes' in r['plain_english']


def test_corners_connect_the_fluid_column(tmp_path):
    r = PU.analyse(legs=[{'dir': 'east', 'length': 1500}, {'dir': 'north', 'length': 1000}, {'dir': 'up', 'length': 500}], od_mm=100,
                   wall_mm=8, fluid='air', analyses=('acoustic',), modes=4, element_mm=10, workdir=str(tmp_path), name='L')
    assert r['acoustic_natural_frequencies_hz'][:3] == pytest.approx([n * C_AIR / 6 for n in (1, 2, 3)], rel=5e-4)


def test_simply_supported_pipe_against_exact_timoshenko(tmp_path):
    r = PU.analyse(legs=[{'dir': 'east', 'length': 4000}], od_mm=100, wall_mm=8, fluid='air', analyses=('structural',), modes=6,
                   element_mm=20, supports=[{'at': 0, 'type': 'pinned'}, {'at': -1, 'type': 'pinned'}], workdir=str(tmp_path), name='s')
    D, t, L, E, rho, nu, kap = 0.100, 0.008, 4.0, 210e9, 7850.0, 0.3, 0.53
    G = E / (2 * (1 + nu))
    A = math.pi / 4 * (D ** 2 - (D - 2 * t) ** 2); I = math.pi / 64 * (D ** 4 - (D - 2 * t) ** 4)
    mf = 1.204263 * math.pi / 4 * (D - 2 * t) ** 2
    exact = []
    for n in (1, 2, 3):
        k = n * math.pi / L
        a = rho * rho * I / (kap * G) * (1 + mf / (rho * A))
        b = (rho * A + mf) + rho * I * k ** 2 + E * I * k ** 2 * (rho * A + mf) / (kap * G * A)
        exact.append(math.sqrt((b - math.sqrt(b * b - 4 * a * E * I * k ** 4)) / (2 * a)) / (2 * math.pi))
    f = r['structural_natural_frequencies_hz']
    assert [f[0], f[2], f[4]] == pytest.approx(exact, rel=2e-3)                          # bending modes come in pairs (two planes)


def test_resonance_check_and_inputs(tmp_path):
    r = PU.analyse(legs=[{'dir': 'east', 'length': 1500}, {'dir': 'north', 'length': 1000}], od_mm=100, wall_mm=8, fluid='air',
                   excitation_hz=[300], modes=6, element_mm=10, workdir=str(tmp_path), name='x')
    assert any(n['mode'] == 'acoustic' and abs(n['separation_percent']) < 10 for n in r['resonances'])
    assert 'RESONANCE RISK' in r['plain_english']
    with pytest.raises(ValueError, match='fluid'):
        PU.analyse(legs=[{'dir': 'east', 'length': 1000}], od_mm=100, wall_mm=8, fluid='honey', workdir=str(tmp_path))
    with pytest.raises(ValueError, match='outside diameter'):
        PU.analyse(legs=[{'dir': 'east', 'length': 1000}], workdir=str(tmp_path))


def test_gmsh_is_never_used(tmp_path):
    import subprocess, sys, os
    code = ('import sys; sys.path.insert(0, %r); from shipbrain import openpulse_shim; openpulse_shim.install(); import gmsh\n'
            'try:\n    gmsh.initialize()\nexcept RuntimeError as e:\n    print("refused:", e)') % os.path.dirname(os.path.dirname(os.path.abspath(PU.__file__)))
    out = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True).stdout
    assert 'refused' in out and 'own 1D mesher' in out


def test_tool_from_plain_words(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('pipe_pulsation', {'legs': [{'dir': 'east', 'length': 4000}, {'dir': 'up', 'length': 2000}], 'od_mm': 114.3, 'wall_mm': 6.0,
                                  'fluid': 'water', 'open_ends': [-1], 'excitation_hz': [25, 50], 'modes': 6})
    assert 'error' not in r, r
    assert r['acoustic_natural_frequencies_hz'] and r['structural_natural_frequencies_hz'] and 'OpenPulse' in r['plain_english']
