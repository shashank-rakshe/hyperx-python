import os, shutil, pytest
pytest.importorskip('pyNastran')
from shipbrain import nastran_bridge as N

DATA = os.path.join(os.path.dirname(__file__), 'data', 'pynastran')       # plate.bdf / plate.op2 from the pyNastran repository (BSD-3, LICENSE.md next to them)


def test_reads_the_pynastran_plate_deck():
    r = N.read_bdf(os.path.join(DATA, 'plate.bdf'))
    assert (r['nodes'], r['elements'], r['sol']) == (36, 25, 101) and r['element_types'] == ['CQUAD4']


def test_reads_op2_results():
    r = N.read_op2(os.path.join(DATA, 'plate.op2'))
    assert r['displacement'][1]['max'] == pytest.approx(3.7992e-5, rel=1e-3)
    assert r['von_mises'][1]['max'] == pytest.approx(418.0, rel=1e-3)


def test_written_deck_has_the_right_mass_nodes_and_total_force(tmp_path):
    p = N.write_plate(str(tmp_path / 'p.bdf'), 1.0, 0.2, 0.01, nx=10, ny=4, force_N=1000.0)
    r = N.read_bdf(p)
    assert r['mass'] == pytest.approx(7850 * 1.0 * 0.2 * 0.01, rel=1e-6)
    assert (r['nodes'], r['elements']) == (55, 40)
    from pyNastran.bdf.bdf import BDF
    m = BDF(debug=False); m.read_bdf(p)
    assert sum(f.mag for loads in m.loads.values() for f in loads) == pytest.approx(1000.0, rel=1e-9)


@pytest.mark.skipif(shutil.which('ccx') is None, reason='CalculiX not installed')
def test_deck_solved_by_calculix_matches_beam_theory(tmp_path):
    from shipbrain import solver
    from shipbrain.femodel import FEModel
    p = N.write_plate(str(tmp_path / 'p.bdf'), 1.0, 0.2, 0.01, nx=40, ny=8, force_N=1000.0)
    m = FEModel.read(p)
    m.write_inp(str(tmp_path / 'p.inp'))
    r = solver.run_calculix(str(tmp_path / 'p.inp'))
    I = 0.2 * 0.01 ** 3 / 12
    assert r['max_displacement_mm'] == pytest.approx(1000 * 1.0 ** 3 / (3 * 210e9 * I), rel=0.05)      # SI units in, so the "mm" label is metres
    assert r['max_von_mises_MPa'] == pytest.approx(6 * 1000 * 1.0 / (0.2 * 0.01 ** 2), rel=0.05)        # Pa
