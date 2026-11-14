import math, os, sys, pytest
pytest.importorskip('pint')
from shipbrain import pipestress as PS

HERE = os.path.dirname(os.path.abspath(__file__))


def frame_thermal(pts, E, G, A, I, J, eps):
    """independent 3D Euler-Bernoulli frame, both ends fixed, uniform free thermal strain eps"""
    import numpy as np
    n = len(pts)
    K, F = np.zeros((6 * n, 6 * n)), np.zeros(6 * n)
    for i in range(n - 1):
        a, b = np.array(pts[i], float), np.array(pts[i + 1], float)
        L = np.linalg.norm(b - a)
        ex = (b - a) / L
        ref = np.array([0, 0, 1.0]) if abs(ex[2]) < 0.9 else np.array([1.0, 0, 0])
        ey = np.cross(ref, ex); ey /= np.linalg.norm(ey); ez = np.cross(ex, ey)
        T = np.kron(np.eye(4), np.array([ex, ey, ez]))
        k = np.zeros((12, 12))
        k[0, 0] = k[6, 6] = E * A / L; k[0, 6] = k[6, 0] = -E * A / L
        k[3, 3] = k[9, 9] = G * J / L; k[3, 9] = k[9, 3] = -G * J / L
        for v, th, s in ((1, 5, 1), (2, 4, -1)):
            c = E * I / L ** 3
            idx = [v, th, v + 6, th + 6]
            m = c * np.array([[12, 6 * L * s, -12, 6 * L * s], [6 * L * s, 4 * L * L, -6 * L * s, 2 * L * L],
                              [-12, -6 * L * s, 12, -6 * L * s], [6 * L * s, 2 * L * L, -6 * L * s, 4 * L * L]])
            for p in range(4):
                for q in range(4):
                    k[idx[p], idx[q]] += m[p, q]
        fl = np.zeros(12); fl[0], fl[6] = -E * A * eps, E * A * eps
        d = list(range(6 * i, 6 * i + 12))
        K[np.ix_(d, d)] += T.T @ k @ T
        F[d] += T.T @ fl
    free = list(range(6, 6 * (n - 1)))
    U = np.zeros(6 * n); U[free] = np.linalg.solve(K[np.ix_(free, free)], F[free])
    return U, K @ U - F


def test_cantilever_weight_hand_check(tmp_path):
    r = PS.analyse(legs=[{'dir': 'east', 'length': 3048}], nps=10, schedule='40', t_oper_c=21.1, water=False,
                   supports=[{'at': 0, 'type': 'anchor'}], workdir=str(tmp_path), name='a')
    R = list(r['cases']['sus']['support_loads'].values())[0]
    w = 0.283 * math.pi * (10.75 - 0.365) * 0.365 * 120                    # lb of steel, 10 ft of NPS 10 sch 40
    assert abs(R['F_kN'][2]) == pytest.approx(w * PS.LBF, rel=1e-3)
    assert abs(R['M_kNm'][1]) == pytest.approx(w * 5 * PS.FTLBF, rel=1e-3)   # w L^2 / 2


def test_fully_restrained_thermal_force(tmp_path):
    r = PS.analyse(legs=[{'dir': 'east', 'length': 6000}], nps=6, schedule='40', t_oper_c=150.0, water=False,
                   workdir=str(tmp_path), name='b')
    A = math.pi * (6.625 - 0.28) * 0.28
    alp = 6.6e-6 + 0.22e-6 * 2 / 100                                        # psi's A53A table at 302 F
    for v in r['cases']['exp']['support_loads'].values():
        assert abs(v['F_kN'][0]) == pytest.approx(27.9e6 * A * alp * 232 * PS.LBF, rel=1e-3)
    assert r['cases']['exp']['code_stress']['stress_MPa'] == 0.0           # B31.1 expansion stress has no axial part


def test_l_bend_against_independent_frame(tmp_path):
    legs = [{'dir': 'east', 'length': 6000}, {'dir': 'north', 'length': 3000}]
    r = PS.analyse(legs=legs, nps=6, schedule='40', t_oper_c=150.0, water=False, workdir=str(tmp_path), name='l')
    OD, t = 6.625, 0.28
    ID = OD - 2 * t
    A = math.pi / 4 * (OD ** 2 - ID ** 2); I = math.pi / 64 * (OD ** 4 - ID ** 4)
    E = 27.9e6
    U, R = frame_thermal([(0, 0, 0), (6000 / 25.4, 0, 0), (6000 / 25.4, 3000 / 25.4, 0)], E, E / 2.6, A, I, 2 * I,
                         (6.6e-6 + 0.22e-6 * 2 / 100) * 232)
    ps = r['cases']['exp']['support_loads']
    an = [k for k in ps if 'anchor' in k]
    a, b = ps[an[0]], ps[an[1]]
    corner = next(n['node'] for n in r['nodes'] if n['xyz_mm'] == [6000.0, 0.0, 0.0])
    # psi includes shear deformation (more flexible): 1.3 % lower loads than the Euler-Bernoulli frame
    for got, own in ((abs(a['F_kN'][0]), abs(R[0]) * PS.LBF), (abs(a['F_kN'][1]), abs(R[1]) * PS.LBF),
                     (abs(a['M_kNm'][2]), abs(R[5]) * 0.0254 * PS.LBF), (abs(b['M_kNm'][2]), abs(R[17]) * 0.0254 * PS.LBF)):
        assert 0.97 * own < got <= own
    assert r['cases']['ope']['displacement_mm'][corner][:2] == pytest.approx([U[6] * 25.4, U[7] * 25.4], abs=0.02)


def test_rests_carry_the_weight_and_never_pull(tmp_path):
    r = PS.analyse(legs=[{'dir': 'east', 'length': 12000}], nps=6, schedule='40', t_oper_c=21.1, water=True,
                   rest_spacing_m=3.0, workdir=str(tmp_path), name='r')
    R = r['cases']['sus']['support_loads']
    OD, t = 6.625, 0.28
    ID = OD - 2 * t
    L = 12000 / 25.4
    total = (0.283 * math.pi / 4 * (OD ** 2 - ID ** 2) + 62.4 / 1728 * math.pi / 4 * ID ** 2) * L * PS.LBF
    assert -sum(v['F_kN'][2] for v in R.values()) == pytest.approx(total, rel=1e-3)
    legs = [{'dir': 'east', 'length': 6000}, {'dir': 'up', 'length': 3000}, {'dir': 'east', 'length': 6000}]
    hot = PS.analyse(legs=legs, nps=4, schedule='40', t_oper_c=250.0, water=True, rest_spacing_m=2.0, workdir=str(tmp_path), name='u')
    rests = {k: v['F_kN'][2] for k, v in hot['cases']['ope']['support_loads'].items() if 'rest' in k}
    span = PS.analyse(legs=[{'dir': 'east', 'length': 6000}], nps=4, schedule='40', water=False, workdir=str(tmp_path), name='s')
    mid = next(n['node'] for n in span['nodes'] if n['xyz_mm'] == [3000.0, 0.0, 0.0])
    OD, t = 4.5, 0.237
    ID = OD - 2 * t
    A = math.pi / 4 * (OD ** 2 - ID ** 2); I = math.pi / 64 * (OD ** 4 - ID ** 4)
    hand = 0.283 * A * (6000 / 25.4) ** 4 / (384 * 27.9e6 * I) * 25.4      # fixed-fixed span, own weight
    assert abs(span['cases']['sus']['displacement_mm'][mid][2]) == pytest.approx(hand, rel=0.03)
    assert len(rests) == 4 and all(v <= 1e-6 for v in rests.values())    # one-way: they press or lift off, never pull
    assert 'sharp joints' in hot['plain_english']


def test_inputs_checked(tmp_path):
    with pytest.raises(ValueError, match='standard NPS'):
        PS.analyse(legs=[{'dir': 'east', 'length': 1000}], od_mm=150.0, workdir=str(tmp_path))
    with pytest.raises(ValueError, match='schedule'):
        PS.analyse(legs=[{'dir': 'east', 'length': 1000}], nps=6, schedule='999', workdir=str(tmp_path))
    with pytest.raises(ValueError, match='anchor'):
        PS.analyse(legs=[{'dir': 'east', 'length': 1000}], nps=6, supports=[{'at': 0, 'type': 'rest'}], workdir=str(tmp_path))
    assert PS.nps_name(od_mm=168.3) == '6'


def test_tool_from_plain_words(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('pipe_stress', {'legs': [{'dir': 'east', 'length': 6000}, {'dir': 'north', 'length': 3000}], 'od_mm': 168.3,
                               't_oper_c': 150, 'pressure_bar': 10, 'water': True})
    assert r['pipe']['nps'] == '6' and 'code_stress' in r['cases']['exp'] and 'B31.1' in r['plain_english']
    assert os.path.exists(tmp_path / 'pipe_stress_psi.py')


def test_vendored_psi_own_tests_pass():
    import subprocess
    root = os.path.join(os.path.dirname(HERE), 'shipbrain', 'vendor', 'psi', 'repo')
    r = subprocess.run([sys.executable, '-m', 'pytest', '-q', '-p', 'no:cacheprovider', 'tests'], cwd=root, capture_output=True, text=True)
    last = r.stdout.strip().splitlines()[-1]
    assert '47 passed' in last and '1 failed' in last                     # test_variable_spring also fails in unchanged psi
