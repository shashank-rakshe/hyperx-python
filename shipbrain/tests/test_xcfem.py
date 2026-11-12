import os, sys, pytest
from shipbrain import xcfem, engines, agent, knowledge


@pytest.fixture
def fake_xc(tmp_path, monkeypatch):
    """a stand-in for the xc_base module so the plumbing (not XC itself) is tested"""
    stub = tmp_path / 'stub'
    stub.mkdir()
    (stub / 'xc_base.py').write_text('VERSION = "stub"\n')
    monkeypatch.setenv('PYTHONPATH', str(stub))
    monkeypatch.setenv('XC_PYTHON', sys.executable)
    return tmp_path


def test_runs_a_script_and_reports_files_and_output(fake_xc):
    wd = fake_xc / 'work'
    r = xcfem.run('import xc_base\nprint("utilisation 0.87")\nopen("res.csv", "w").write("a,b\\n1,2\\n")\n', str(wd), name='beam check')
    assert r['exit_code'] == 0 and 'utilisation 0.87' in r['plain_english'] and r['files'] == ['res.csv'] and r['script'] == 'beam_check.py'


def test_failing_script_is_reported(fake_xc):
    r = xcfem.run('import xc_base\nraise ValueError("bad section")\n', str(fake_xc / 'w2'))
    assert r['exit_code'] != 0 and 'bad section' in r['error']
    with pytest.raises(ValueError, match='Python text'):
        xcfem.run('just words', str(fake_xc / 'w3'))


def test_not_installed_gives_install_card(tmp_path, monkeypatch):
    monkeypatch.setenv('XC_PYTHON', '')
    monkeypatch.setenv('SHIPBRAIN_XC_DOCKER', '0')
    monkeypatch.setattr(xcfem, '_local_python', lambda: None)
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('xc_run', {'script': 'import xc_base\nprint(1)\n'})
    assert 'install' in r and r['install']['key'] == 'xcfem' and 'engthiago/xcfem' in r['plain_english']


def test_assessment_questions_route_to_xc():
    out = engines.choose('Check this reinforced concrete beam to Eurocode 2, bending and shear')
    names = [e['engine'] for p in out['plan'] for e in p['engines']]
    assert any(n.startswith('XC') for n in names), names
    out = engines.choose('AISC 360 member check of a steel column with interaction diagram')
    assert any(e['engine'].startswith('XC') for p in out['plan'] for e in p['engines'])


def test_tool_is_offered_for_code_checks(tmp_path):
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    assert 'xc_run' in set(agent.select_tools(T, 'Check the rebar in this concrete slab to Eurocode 2'))
    assert 'xc_run' in set(agent.select_tools(T, 'Assess this column to AISC 360 with an interaction diagram'))
