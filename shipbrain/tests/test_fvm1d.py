import pytest
from shipbrain import fvm1d as F

pytestmark = pytest.mark.skipif(F.octave() is None, reason='Octave not installed')


def test_diffusion_is_exact(tmp_path):
    r = F.run('diffusion', workdir=str(tmp_path), n=8, k=50, Ta=20, Tb=80)
    assert r['max_error'] < 1e-9 and r['values'][0] == 20 and r['values'][-1] == 80


def test_heat_generation_error_is_q_dx2_over_8k_and_second_order(tmp_path):
    e = []
    for n in (5, 10, 20, 40):
        r = F.run('heat_generation', workdir=str(tmp_path), n=n)
        dx = 0.02 / n
        assert r['max_error'] == pytest.approx(1e6 * dx * dx / (8 * 0.5), rel=1e-3)
        e.append(r['max_error'])
    assert e[0] / e[1] == pytest.approx(4, rel=0.01)


def test_convection_diffusion_central_scheme_converges(tmp_path):
    e = [F.run('convection_diffusion', workdir=str(tmp_path), n=n)['max_error'] for n in (5, 10, 20, 40)]
    assert e[0] < 0.01 and all(a / b > 3.5 for a, b in zip(e, e[1:]))


def test_simple_conserves_mass(tmp_path):
    r = F.run('simple', workdir=str(tmp_path), rho=1.2, A=0.5)
    assert set(r['velocity_m_s']) == {10.0} and set(r['mass_flow_kg_s']) == {6.0}


def test_wrong_input_refused_and_original_script_untouched(tmp_path):
    import hashlib, os
    f = os.path.join(F.ROOT, 'oned_diffusion.m')
    h = hashlib.md5(open(f, 'rb').read()).hexdigest()
    with pytest.raises(ValueError, match='not an input'):
        F.run('diffusion', workdir=str(tmp_path), banana=1)
    F.run('diffusion', workdir=str(tmp_path), n=6)
    assert hashlib.md5(open(f, 'rb').read()).hexdigest() == h


def test_tool(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('fvm_1d', {'case': 'heat_generation', 'params': {'n': 20}})
    assert r['max_error'] == pytest.approx(0.25, rel=1e-3) and 'exact' in r['plain_english']
