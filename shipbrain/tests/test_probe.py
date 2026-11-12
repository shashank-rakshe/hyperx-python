import json, threading, urllib.request, numpy as np, pytest
from shipbrain import solver, openfoam as O

needs_ccx = pytest.mark.skipif(solver.ccx_path() is None, reason='CalculiX not installed')


def _plate(tmp_path):
    from shipbrain.platemesh import build_plates
    from shipbrain.femodel import FEModel
    spec = {'name': 'cant', 'element_size': 50, 'plates': [{'id': 'P1', 'group': 'P1', 't': 20.0, 'outline': [[0, 0, 0], [1000, 0, 0], [1000, 200, 0], [0, 200, 0]], 'holes': []}],
            'loads': [], 'fix': [{'x': 0, 'dof': '123456'}]}
    build_plates(spec, str(tmp_path))
    inp = tmp_path / 'cant.inp'
    M = FEModel.read(str(inp))
    ids = [i for i, x in M.nodes.items() if abs(x[0] - 1000) < 1e-6]
    inp.write_text(inp.read_text().replace('*STEP\n*STATIC\n', '*STEP\n*STATIC\n*CLOAD\n' + ''.join(f'{i}, 3, {-100.0 / len(ids):.8g}\n' for i in ids), 1))
    solver.run_calculix(str(inp))


@needs_ccx
def test_probe_tool_and_server_endpoints(tmp_path):
    from shipbrain import agent, knowledge, server
    _plate(tmp_path)
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('probe_result', {'file': 'cant.inp', 'x': 1000, 'y': 100, 'z': 0})
    ref = solver.read_frd(str(tmp_path / 'cant.frd'))
    assert r['displacement_magnitude_mm'] == pytest.approx(ref['max_displacement_mm'], rel=0.05)          # the tip carries the largest displacement
    assert T.call('probe_result', {'file': 'cant.inp', 'x': 0, 'y': 100, 'z': 0})['displacement_magnitude_mm'] == pytest.approx(0, abs=1e-6)       # the clamp
    # the chat window's endpoints
    from http.server import HTTPServer
    server.STATE.update(tools=T, llm=None, lan=False)
    h = [c for c in vars(server).values() if isinstance(c, type) and hasattr(c, 'do_GET')][0]
    srv = HTTPServer(('127.0.0.1', 0), h)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{srv.server_address[1]}'
    try:
        f = json.load(urllib.request.urlopen(base + '/api/field?file=cant.inp&frd=cant.frd'))
        assert len(f['xyz']) == len(f['fields']['von_mises']['values']) and f['faces']
        p = json.load(urllib.request.urlopen(base + '/api/probe?file=cant.inp&x=1000&y=100&z=0'))
        assert p['von_mises_MPa'] >= 0 and p['displacement_magnitude_mm'] > 0
        (tmp_path / 'p.png').write_bytes(b'\x89PNG\r\n\x1a\n' + b'0' * 20)
        resp = urllib.request.urlopen(base + '/files/p.png?inline=1')
        assert resp.headers['Content-Type'] == 'image/png'                                           # pictures show in the chat
    finally:
        srv.shutdown()


@pytest.mark.skipif(not O.installed(), reason='OpenFOAM not installed')
def test_openfoam_probe(tmp_path):
    from shipbrain import agent, knowledge
    out, res, info = O.solve(str(tmp_path), 'c', velocity=0.01, fluid='oil', length=2.0, height=1.0, plate_x=0.5, plate_t=0.04, plate_h=0.4, cell=0.05)
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('probe_result', {'file': 'c', 'x': 0.3, 'y': 0.2, 'z': 0.025})
    assert 'error' not in r and r['distance_m'] < 0.1
    j = int(np.argmin(np.linalg.norm(res['centres'] - np.array([0.3, 0.2, 0.025]), axis=1)))
    assert r['pressure_pa'] == pytest.approx(res['p_cells'][j], rel=1e-3) and r['speed_m_s'] == pytest.approx(np.linalg.norm(res['U_cells'][j]), rel=1e-3)
    assert r['pressure_pa'] > 0                                                                      # in front of the plate the pressure is above the outlet
