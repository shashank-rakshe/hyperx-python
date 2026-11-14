import numpy as np, pytest, shutil
from shipbrain import openfoam as O, elmer as E

needs_of = pytest.mark.skipif(not O.installed(), reason='OpenFOAM not installed')


@needs_of
def test_mesh_passes_checkmesh_2d_and_3d(tmp_path):
    for kw in (dict(), dict(width=0.6, plate_w=0.2)):
        d = tmp_path / ('a' if not kw else 'b')
        info = O.build_case(str(d), velocity=0.01, fluid='oil', length=2.0, height=1.0, plate_h=0.4, plate_t=0.06, cell=0.1, **kw)
        rc, out = O._run(['checkMesh'], str(d), 300)
        assert 'Mesh OK' in out and info['body_faces'] > 0


@needs_of
def test_poiseuille_flow(tmp_path):
    H, U, nu = 1.0, 1e-5, 1.002e-3 / 998.2
    info = O.build_case(str(tmp_path), velocity=U, fluid='water', length=2.0, height=H, plate_h=0, cell=0.05, side_walls='wall', turbulence='laminar')
    O.run_case(str(tmp_path))
    r = O.results(str(tmp_path), info)
    X, u, p = r['centres'], r['U_cells'][:, 0], r['p_cells']
    xs = np.unique(np.round(X[:, 0], 9))
    c = xs[np.argmin(abs(xs - 1.5))]
    s = np.abs(X[:, 0] - c) < 1e-9
    o = np.argsort(X[s, 1])
    y, uu = X[s, 1][o], u[s][o]
    mean = np.trapezoid(uu, y) / H
    assert mean == pytest.approx(U, rel=0.05)                                    # flow rate conserved (the cell centres miss the wall layer)
    assert uu.max() / mean == pytest.approx(1.5, rel=0.03)                      # parabolic profile
    pc = lambda x0: (p[np.abs(X[:, 0] - xs[np.argmin(abs(xs - x0))]) < 1e-9].mean(), xs[np.argmin(abs(xs - x0))])
    a, b = pc(1.0), pc(1.8)
    assert (b[0] - a[0]) / (b[1] - a[1]) == pytest.approx(-12 * 998.2 * nu * mean / H ** 2, rel=0.05)


@needs_of
def test_plate_drag_agrees_with_elmer(tmp_path):
    kw = dict(length=2.0, height=1.0, plate_x=0.5, plate_t=0.04, plate_h=0.4, velocity=0.01, fluid='oil', cell=0.02)
    info = O.build_case(str(tmp_path / 'of'), turbulence='laminar', **kw)
    O.run_case(str(tmp_path / 'of'))
    r = O.results(str(tmp_path / 'of'), info)
    cd = r['pressure_force_n'][0] / (0.5 * 870 * 0.01 ** 2 * 0.4 * 0.02)
    if E.exe():
        e = E.solve_plate(str(tmp_path), 'el', plate='rigid', **kw)
        assert cd == pytest.approx(e['drag_coefficient_pressure'], rel=0.10)      # two independent solvers, same case (refined they meet at ~7.1-7.2)
    assert 6.5 < cd < 7.7
    assert r['force_n'][0] == pytest.approx(r['pressure_force_n'][0], rel=0.05)    # at Re 70 the plate drag is nearly all pressure


@needs_of
def test_flow_force_is_conserved_on_the_shell_model(tmp_path):
    import cadquery as cq
    from shipbrain import flowload, cadplates
    from shipbrain.femodel import FEModel
    cq.exporters.export(cq.Workplane('XY').box(300, 30, 200, centered=(False, False, True)), str(tmp_path / 'plate.step'))   # 300 x 30 x 200 mm block: thin in y
    out, res, info = O.solve(str(tmp_path), 'fl', velocity=0.5, fluid='water', length=3.0, height=1.0, width=1.0, plate_x=0.8, body_file=str(tmp_path / 'plate.step'),
                             turbulence='sst', cell=0.05, end_iter=300)
    cadplates.mesh_cad(str(tmp_path / 'plate.step'), 40.0, 10.0, str(tmp_path), name='fe')
    F = flowload.nodal_forces(FEModel.read(str(tmp_path / 'fe.inp')), res['body_faces'], info['offset'])
    tot = sum(F.values())
    assert np.allclose(tot, res['force_n'], rtol=1e-9, atol=1e-9)           # every face force reaches the structure
    assert out['drag_n'] > 0


@needs_of
def test_tool_flow_load_stress(tmp_path):
    import cadquery as cq
    from shipbrain import agent, knowledge
    cq.exporters.export(cq.Workplane('XY').box(400, 20, 300, centered=(False, False, False)), str(tmp_path / 'p.step'))
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('flow_load_stress', {'file': 'p.step', 'velocity': 0.5, 'fluid': 'water', 'fix': [{'y': 0, 'dof': '123456'}], 'thickness_mm': 20, 'element_size': 50,
                                      'turbulence': 'sst', 'cell': 0.05})
    assert 'error' not in r, r
    assert r['max_von_mises_MPa'] > 0 and r['max_displacement_mm'] > 0
    assert abs(r['force_applied_n'][0] - r['flow']['drag_n']) < 1e-3
    for f in ('fls_velocity.png', 'fls_pressure.png', 'fls_von_mises.png', 'fls_displacement.png'):
        assert (tmp_path / f).stat().st_size > 5000
