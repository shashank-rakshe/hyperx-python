import glob, os, numpy as np, pytest
from shipbrain import elmer as E

needs_elmer = pytest.mark.skipif(E.exe() is None, reason='Elmer not installed')


def test_mesh_files_are_consistent(tmp_path):
    info = E.channel_plate(length=2.0, height=1.0, plate_x=0.5, plate_t=0.04, plate_h=0.4, velocity=0.01, fluid='oil', cell=0.1, plate='elastic',
                           structure=(1e5, 0.35, 1100.0), name='m', workdir=str(tmp_path))
    d = tmp_path / 'm'
    nn, ne, nb = map(int, (d / 'mesh.header').read_text().split('\n')[0].split())
    assert nn == info['nodes'] and ne == info['cells']
    els = [l.split() for l in (d / 'mesh.elements').read_text().splitlines()]
    bds = [l.split() for l in (d / 'mesh.boundary').read_text().splitlines()]
    assert len(els) == ne and len(bds) == nb
    assert {e[1] for e in els} == {'1', '2'}                                   # fluid and plate bodies
    assert {b[1] for b in bds} == {'1', '2', '3', '4', '5', '6'}               # inlet, outlet, walls, interface, clamp
    for b in bds:
        assert 1 <= int(b[2]) <= ne
        if b[1] == '5':
            assert int(b[3]) >= 1                                              # the interface has a cell on each side
    X = np.array([[float(v) for v in l.split()[2:4]] for l in (d / 'mesh.nodes').read_text().splitlines()])
    # every quad is counter-clockwise
    for e in els:
        p = X[[int(i) - 1 for i in e[3:7]]]
        cr = lambda a, b: a[0] * b[1] - a[1] * b[0]
        assert 0.5 * (cr(p[1] - p[0], p[2] - p[0]) + cr(p[2] - p[0], p[3] - p[0])) > 0


@needs_elmer
def test_poiseuille_flow_profile_and_pressure_gradient(tmp_path):
    H, U, mu = 1.0, 1e-5, 1.002e-3
    E.channel_plate(length=2.0, height=H, plate_h=0, velocity=U, fluid='water', cell=0.05, name='pf', workdir=str(tmp_path))
    E.run(str(tmp_path / 'pf.sif'), str(tmp_path))
    v = E.read_vtu(E.vtu_file(str(tmp_path), 'pf'))
    X, u, p = v['points'], v['fields']['velocity'][:, 0], v['fields']['pressure']
    xs = np.unique(np.round(X[:, 0], 9))
    c = xs[np.argmin(abs(xs - 1.5))]
    s = np.abs(X[:, 0] - c) < 1e-9
    o = np.argsort(X[s, 1])
    mean = np.trapezoid(u[s][o], X[s, 1][o])
    assert u[s].max() / mean == pytest.approx(1.5, rel=0.01)                   # parabolic profile: umax = 1.5 x mean
    col = lambda x0: (p[np.abs(X[:, 0] - xs[np.argmin(abs(xs - x0))]) < 1e-9].mean(), xs[np.argmin(abs(xs - x0))])
    a, b = col(1.0), col(1.8)
    assert (b[0] - a[0]) / (b[1] - a[1]) == pytest.approx(-12 * mu * mean / H ** 2, rel=0.04)    # dp/dx = -12 mu U / H^2


@needs_elmer
def test_fsi_coupling_is_linear_and_matches_rigid_pressure(tmp_path):
    kw = dict(length=2.0, height=1.0, plate_x=0.5, plate_t=0.04, plate_h=0.4, velocity=0.01, fluid='oil', cell=0.05)
    soft = E.solve_plate(str(tmp_path), 'a', plate='elastic', structure=(1e5, 0.35, 1100.0), **kw)
    stiff = E.solve_plate(str(tmp_path), 'b', plate='elastic', structure=(1e6, 0.35, 1100.0), **kw)
    rigid = E.solve_plate(str(tmp_path), 'c', plate='rigid', **kw)
    assert soft['plate_tip_displacement_m'] / stiff['plate_tip_displacement_m'] == pytest.approx(10, rel=0.03)    # linear elasticity
    assert soft['pressure_drag_n_per_m'] == pytest.approx(rigid['pressure_drag_n_per_m'], rel=0.02)              # small bending: same load
    assert soft['plate_tip_displacement_m'] > 0 and soft['plate_max_von_mises_pa'] > 0


@needs_elmer
def test_tool_makes_pictures(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('elmer_flow', {'velocity': 0.01, 'fluid': 'oil', 'plate': 'elastic', 'material': 'rubber', 'cell': 0.05, 'plate_t': 0.04})
    assert 'error' not in r, r
    for f in ('flow_velocity.png', 'flow_pressure.png', 'flow_displacement.png', 'flow_vonmises.png'):
        assert (tmp_path / f).stat().st_size > 5000
    assert 'bends' in r['plain_english']
