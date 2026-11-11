import ast
import pytest
from shipbrain import nxopen


def test_catalogue_from_code():
    c = nxopen.catalogue()
    assert len(c) > 100 and 'nxopentse.cae.solving.solve_all_solutions' in c
    s = nxopen.syntax('create_nodal_force')
    assert [a['name'] for a in s['args']] == ['node_label', 'fx', 'fy', 'fz', 'force_name']
    assert any('pressure' in h['function'] for h in nxopen.find('pressure on group'))
    with pytest.raises(KeyError, match='closest'):
        nxopen.syntax('make_me_a_ship')


def test_journal_checked_and_valid(tmp_path):
    out = nxopen.journal([{'fn': 'get_all_bodies_in_part', 'as': 'bodies'},
                          {'fn': 'get_body_properties', 'for_each': '$bodies'},
                          {'fn': 'create_pressure_on_group', 'args': {'group_name': 'DECK', 'pressure': 0.05, 'force_name': 'P',
                                                                      'group_filter_type': {'nx': 'NXOpen.CAE.CaeSetGroupFilterType.GeomFace'}}}],
                         part='a.sim', out=str(tmp_path / 'j.py'))
    text = open(out).read()
    ast.parse(text)
    assert 'OpenActiveDisplay' in text and 'for item in bodies' in text and 'GeomFace' in text
    with pytest.raises(ValueError, match='has no argument'):
        nxopen.journal([{'fn': 'solve_solution', 'args': {'name': 'x'}}], out=str(tmp_path / 'k.py'))
    with pytest.raises(ValueError, match='needs'):
        nxopen.journal([{'fn': 'solve_solution'}], out=str(tmp_path / 'k.py'))
    with pytest.raises(ValueError, match='not an NXOpen name'):
        nxopen.journal([{'fn': 'solve_solution', 'args': {'solution_name': {'nx': 'os.system("x")'}}}], out=str(tmp_path / 'k.py'))


def test_without_nx_says_how_to_run(tmp_path, monkeypatch):
    monkeypatch.setattr(nxopen, 'nx_dir', lambda: None)
    j = nxopen.journal([{'fn': 'solve_all_solutions'}], out=str(tmp_path / 'j.py'))
    r = nxopen.run(j, 'a.sim')
    assert r['ran'] is False and 'Alt+F8' in r['plain_english']
