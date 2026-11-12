import ast, os, shutil, subprocess, pytest
import numpy as np
from shipbrain import openfoam as O, fluentmesh, cfdexport, tabfield

needs_of = pytest.mark.skipif(not O.installed() or shutil.which('fluentMeshToFoam') is None, reason='OpenFOAM not installed')


@needs_of
def test_fluent_mesh_is_read_back_by_openfoams_fluent_importer(tmp_path):
    info = O.build_case(str(tmp_path / 'of'), velocity=1.0, fluid='water', length=2.0, height=1.0, width=0.6, plate_x=0.5, plate_t=0.06, plate_h=0.4, plate_w=0.2, cell=0.1)
    topo = info['grid']['topology']
    msh = tmp_path / 'm.msh'
    fluentmesh.write_msh(topo, cfdexport.ZONES, str(msh))
    rt = tmp_path / 'rt'
    (rt / 'system').mkdir(parents=True)
    for f in ('controlDict', 'fvSchemes', 'fvSolution'):
        shutil.copy(tmp_path / 'of' / 'system' / f, rt / 'system' / f)
    env = O._env()
    r = subprocess.run(['fluentMeshToFoam', str(msh)], cwd=str(rt), capture_output=True, text=True, env=env)
    assert 'FATAL' not in r.stdout + r.stderr
    c = subprocess.run(['checkMesh'], cwd=str(rt), capture_output=True, text=True, env=env).stdout
    assert 'Mesh OK' in c and f"cells:            {info['cells']}" in c               # same cells, positive volumes, consistent faces
    b = (rt / 'constant' / 'polyMesh' / 'boundary').read_text()
    for z in ('inlet', 'outlet', 'floor', 'body'):
        assert z in b                                                                 # the zone names survive


def test_cases_for_fluent_and_starccm_are_written(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('cfd_export', {'target': 'fluent', 'velocity': 1.0, 'fluid': 'water', 'plate_h': 0.4, 'plate_t': 0.04, 'turbulence': 'sst', 'cell': 0.1, 'name': 'p'})
    assert r['files'] == ['p.msh', 'p_setup.txt', 'p_fluent.py'] and r['tested_in_the_target_program'] is False
    ast.parse((tmp_path / 'p_fluent.py').read_text())
    assert 'k-omega' in (tmp_path / 'p_fluent.py').read_text() and '998.2' in (tmp_path / 'p_fluent.py').read_text()
    r = T.call('cfd_export', {'target': 'starccm', 'velocity': 2.0, 'fluid': 'air', 'plate_h': 0.4, 'plate_t': 0.04, 'turbulence': 'laminar', 'cell': 0.1, 'name': 'q'})
    j = (tmp_path / 'q_starccm.java').read_text()
    assert j.count('{') == j.count('}') and 'LaminarModel' in j and '1.204' in j
    assert 'NOT run' in (tmp_path / 'p_fluent.py').read_text() and 'NOT compiled' in j        # the scripts say they are untested
    assert 'could not run' in r['plain_english']                                           # and so does the answer


def test_result_tables_from_fluent_and_starccm(tmp_path):
    (tmp_path / 'fl.csv').write_text('nodenumber,      x-coordinate,      y-coordinate,      z-coordinate,          pressure\n1,0,0,0,120\n2,0.1,0,0,110\n3,0.1,0.1,0,90\n')
    (tmp_path / 'st.csv').write_text('"X (m)","Y (m)","Z (m)","Pressure (Pa)","Velocity: Magnitude (m/s)"\n0,0,0,5.5,0.2\n0.5,0,0,4.5,0.4\n0.5,0.5,0,2.5,0.9\n')
    (tmp_path / 'pv.csv').write_text('"Points:0","Points:1","Points:2","p"\n0,0,0,1\n1,0,0,2\n')
    for f, exp in (('fl.csv', 90.0), ('st.csv', 2.5)):
        p = tabfield.probe(str(tmp_path / f), 0.5 if f == 'st.csv' else 0.1, 0.5 if f == 'st.csv' else 0.1, 0)
        assert list(p['values'].values())[-1 if f == 'fl.csv' else 0] == pytest.approx(exp) and p['distance'] < 1e-9
    assert tabfield.probe(str(tmp_path / 'pv.csv'), 0.9, 0, 0)['values']['p'] == 2
    info = tabfield.render(str(tmp_path / 'st.csv'), str(tmp_path / 's.png'), field='Pressure (Pa)')
    assert os.path.getsize(tmp_path / 's.png') > 3000 and info['max'] == 5.5
    with pytest.raises(ValueError, match='coordinate'):
        (tmp_path / 'bad.csv').write_text('a,b\n1,2\n')
        tabfield.read(str(tmp_path / 'bad.csv')) and tabfield.coords(['a', 'b'])


def test_commercial_solvers_are_known_to_the_finder():
    from shipbrain import solvers
    assert 'fluent' in solvers.KNOWN and 'starccm' in solvers.KNOWN and solvers.ANALYSES['fluent'] == ['cfd']
