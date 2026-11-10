"""python -m pytest tests -q   (CalculiX / gmsh tests are skipped when those programs are missing)"""
import json, os, shutil, sys, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from shipbrain import agent, fea, knowledge, mesh, server, solver  # noqa: E402


# ------------------------------------------------------------------ mesher
def test_positions_centred():
    assert mesh._positions(3200, 800) == [800, 1600, 2400]
    assert mesh._positions(3000, 800) == [700, 1500, 2300]
    assert mesh._positions(4800, 2400) == [2400]
    assert mesh._positions(1000, 0) == [] and mesh._positions(500, 800) == []


def test_panel_counts_and_sharing(tmp_path):
    m, info = mesh.build_panel({'name': 'p', 'length': 2400, 'width': 1600, 'thickness': 10, 'element_size': 100,
                                'stiffeners': {'spacing': 800, 'profile': {'type': 'FlatBar', 'h': 150, 't': 10}},
                                'frames': {'spacing': 1200, 'profile': {'type': 'TBar', 'h': 300, 't': 10, 'bf': 100, 'tf': 12}}}, tmp_path)
    assert info['stiffeners_at_mm'] == [800] and info['frames_at_mm'] == [1200]
    assert info['elements_by_part']['plate'] == 24 * 16
    # stiffener web and frame web share the node line at the crossing (x=1200, y=800), z down to the stiffener depth
    for z in (0, -50, -100, -150):
        assert (1200.0, 800.0, float(z)) in m.nodes
    assert os.path.exists(info['files']['bdf']) and os.path.exists(info['files']['inp'])


def test_bdf_fields_are_8_chars(tmp_path):
    _, info = mesh.build_panel({'name': 'b', 'stiffener_model': 'beam'}, tmp_path)
    for line in open(info['files']['bdf']):
        if line.startswith(('GRID', 'CQUAD4', 'CBAR', 'PSHELL', 'PBAR', 'MAT1', 'SPC1', 'PLOAD4')):
            assert len(line.rstrip('\n')) <= 72, line
            assert 'e' not in line[8:].lower(), line            # Nastran style exponents only (7.85-9)


def test_validation_errors():
    with pytest.raises(ValueError) as e:
        mesh.normalise_spec({'thickness': -1, 'boundary': 'fixed'})
    assert 'thickness' in str(e.value) and 'boundary' in str(e.value)


def test_section_props_flatbar():
    s = mesh.profile_props({'type': 'FlatBar', 'h': 200, 't': 10})
    assert s['A'] == 2000 and abs(s['zc'] - 100) < 1e-9 and abs(s['I_vert'] - 10 * 200 ** 3 / 12) < 1e-6


@pytest.mark.skipif(not solver.ccx_path(), reason='CalculiX not installed')
@pytest.mark.parametrize('bc', ['simply', 'clamped'])
def test_calculix_matches_roark(tmp_path, bc):
    spec = {'name': 'bare', 'length': 2000, 'width': 1000, 'thickness': 20, 'stiffeners': None, 'frames': None,
            'element_size': 25, 'pressure': 0.05, 'boundary': bc}
    _, info = mesh.build_panel(spec, tmp_path, formats=('inp',))
    r = solver.run_calculix(info['files']['inp'])
    ref = fea.plate_pressure(2000, 1000, 20, 0.05, bc)
    assert abs(r['max_displacement_mm'] - ref['w_max_mm']) / ref['w_max_mm'] < 0.02
    assert r['min_uz_mm'] < 0                                    # pressure pushes towards -Z


@pytest.mark.skipif(shutil.which('ccx') is None, reason='CalculiX not installed')
def test_calculix_stiffened_panel_runs(tmp_path):
    _, info = mesh.build_panel({'name': 'sp'}, tmp_path, formats=('inp',))
    r = solver.run_calculix(info['files']['inp'])
    assert 0 < r['max_displacement_mm'] < 50


# ------------------------------------------------------------------ own plate-assembly mesher
from shipbrain import platemesh, meshcheck  # noqa: E402

GRILLAGE = [
    {'id': 'DECK', 't': 12, 'outline': [[0, 0, 0], [6000, 0, 0], [6000, 4000, 0], [0, 4000, 0]],
     'holes': [[[4200, 1600, 0], [5200, 1600, 0], [5200, 2400, 0], [4200, 2400, 0]]]},
    {'id': 'G1', 't': 12, 'outline': [[0, 1000, 0], [6000, 1000, 0], [6000, 1000, -600], [0, 1000, -600]]},
    {'id': 'G2', 't': 12, 'outline': [[0, 3000, 0], [6000, 3000, 0], [6000, 3000, -600], [0, 3000, -600]]},
    {'id': 'W', 't': 10, 'outline': [[3000, 0, 0], [3000, 4000, 0], [3000, 4000, -800], [3000, 0, -800]]},
    {'id': 'BR', 't': 10, 'outline': [[3000, 2000, -800], [3600, 2000, -800], [3000, 2000, -200]]}]


def test_plate_assembly_is_conforming():
    m = platemesh.mesh_plates(GRILLAGE, 200)
    c = meshcheck.check(m.xyz, [e['nodes'] for e in m.elems])
    assert c['free_nodes'] == 0 and c['duplicate_nodes'] == 0 and c['parts'] == 1, c
    assert c['quality']['inverted_or_degenerate'] == 0 and all(len(e['nodes']) == 4 for e in m.elems)
    X = np.array(m.xyz)
    # girder/deck joint: every deck node on the joint line is also a girder node
    on_joint = {i for i, p in enumerate(X) if abs(p[1] - 1000) < 1e-6 and abs(p[2]) < 1e-6}
    g1 = {n - 1 for e in m.elems if e['group'] == 'G1' for n in e['nodes']}
    deck = {n - 1 for e in m.elems if e['group'] == 'DECK' for n in e['nodes']}
    assert on_joint and on_joint <= g1 and on_joint <= deck
    # no element inside the opening
    for e in m.elems:
        if e['group'] == 'DECK':
            c0 = X[[n - 1 for n in e['nodes']]].mean(0)
            assert not (4200 < c0[0] < 5200 and 1600 < c0[1] < 2400)


def test_gap_closing_joins_midsurfaces():
    web = {'id': 'WEB', 't': 12, 'outline': [[0, 500, 6], [2000, 500, 6], [2000, 500, 400], [0, 500, 400]]}   # stops t/2 above the deck
    deck = {'id': 'DECK', 't': 12, 'outline': [[0, 0, 0], [2000, 0, 0], [2000, 1000, 0], [0, 1000, 0]]}
    m = platemesh.mesh_plates([deck, web], 100)
    assert m.report['gap_snaps'] == 2
    assert meshcheck.check(m.xyz, [e['nodes'] for e in m.elems])['parts'] == 1


def test_meshcheck_finds_broken_mesh():
    xyz = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (1, 0, 0), (2, 0, 0), (2, 1, 0), (1, 1, 0), (5, 5, 5)]
    c = meshcheck.check(xyz, [[1, 2, 3, 4], [5, 6, 7, 8]])
    assert c['free_nodes'] == 1 and c['duplicate_nodes'] == 2 and c['parts'] == 2 and c['verdict'] != 'ok'


@pytest.mark.skipif(not solver.ccx_path(), reason='CalculiX not installed')
@pytest.mark.parametrize('bc', ['simply', 'clamped'])
def test_unstructured_mesher_matches_roark(tmp_path, bc):
    fx = ([{'x': 0}, {'x': 2000}, {'y': 0}, {'y': 1000}] if bc == 'clamped' else
          [{'x': 0, 'dof': '3'}, {'x': 2000, 'dof': '3'}, {'y': 0, 'dof': '3'}, {'y': 1000, 'dof': '3'},
           {'x': 0, 'y': 0, 'dof': '12'}, {'x': 2000, 'y': 0, 'dof': '2'}])
    spec = {'name': 'u', 'element_size': 25, 'fix': fx, 'loads': [{'plates': ['P'], 'pressure': 0.05}],
            'plates': [{'id': 'P', 't': 20, 'outline': [[0, 0, 0], [2000, 0, 0], [2000, 1000, 0], [0, 1000, 0]]}]}
    _, info = platemesh.build_plates(spec, tmp_path, formats=('inp',))
    r = solver.run_calculix(info['files']['inp'])
    ref = fea.plate_pressure(2000, 1000, 20, 0.05, bc)['w_max_mm']
    assert abs(r['max_displacement_mm'] / ref - 1) < 0.02


def test_step_to_mesh_with_cadquery(tmp_path):
    cq = pytest.importorskip('cadquery')
    from shipbrain import cadplates
    deck = cq.Workplane('XY').box(3000, 2000, 12, centered=(False, False, False)).faces('>Z').workplane().center(2200, 1000).hole(500)
    web = cq.Workplane('XY').box(3000, 12, 400, centered=(False, True, False)).translate((0, 700, -400))
    frame = cq.Workplane('XY').box(10, 2000, 600, centered=(True, False, False)).translate((1500, 0, -600))
    step = str(tmp_path / 'g.step')
    cq.exporters.export(cq.Workplane().add([deck.val(), web.val(), frame.val()]), step)
    m, info = cadplates.mesh_cad(step, 100, out_dir=str(tmp_path))
    assert info['cad']['solids_to_plates'] == 3 and info['gap_snaps'] > 0
    assert info['check']['parts'] == 1 and info['check']['free_nodes'] == 0 and info['check']['duplicate_nodes'] == 0


def test_cadquery_build_checks(tmp_path):
    pytest.importorskip('cadquery')
    from shipbrain import cadrun
    ok = cadrun.run('result = cq.Workplane("XY").box(100, 50, 10)', tmp_path, 'b', {'bbox': [100, 50, 10], 'volume': 50000})
    assert ok['ok'] and ok['pass'] and os.path.exists(tmp_path / 'b.step')
    bad = cadrun.run('result = cq.Workplane("XY").box(100, 50, 12)', tmp_path, 'c', {'bbox': [100, 50, 10]})
    assert bad['ok'] and not bad['pass'] and bad['checks'][0].startswith('FAIL')
    err = cadrun.run('x = 1\nresult = cq.Workplane("XY").bxo(1, 1, 1)', tmp_path)
    assert not err['ok'] and err['error_type'] == 'AttributeError' and err['error_line'] == 3


def test_example_library_rag():
    from shipbrain.examples import Examples
    E = Examples()
    assert len(E.items) >= 10
    assert E.search('bulkhead plate with pipe penetration collar')[0]['name'] == 'pipe_penetration_collar'
    t = agent.Tools(os.path.join(os.path.dirname(__file__), '..', 'shipbrain_work_test'), examples=E)
    ctx, used = agent.retrieve(t, 'make a 3D model of a triangular bracket with a snipe')
    assert 'example:triangular_bracket' in used and 'cq.Workplane' in ctx
    assert agent.retrieve(t, 'mesh a deck panel 4800 x 3200')[0] is None


# ------------------------------------------------------------------ hand checks
def test_plate_check_values():
    r = fea.plate_pressure(2000, 1000, 10, 0.05, 'simply')
    assert abs(r['sigma_max_MPa'] - 0.6102 * 0.05 * 1000 ** 2 / 100) < 0.1


def test_stiffener_check_sane():
    r = fea.stiffener_check(2400, 800, 12, {'type': 'FlatBar', 'h': 150, 't': 12}, 0.05)
    assert r['Z_toe_cm3'] < r['Z_plate_cm3'] and r['sigma_toe_MPa'] > 0


def test_calc_is_safe():
    assert agent.calc('sqrt(16)+2^3')['value'] == 12
    with pytest.raises(ValueError):
        agent.calc('__import__("os").system("echo")')


# ------------------------------------------------------------------ knowledge
def test_knowledge_search(tmp_path):
    (tmp_path / 'notes.md').write_text('# Carlings\n\nA carling butting on a girder starts at the girder web.\n\n# Paint\n\nUse epoxy.')
    json.dump([{'id': 'R-X1', 'text': 'bracket toe must land on a stiffener', 'file': 'r.md'}], open(tmp_path / 'idx.json', 'w'))
    kb = knowledge.load([str(tmp_path)])
    assert kb.search('where does a carling start at a girder')[0]['source'] == 'notes.md'
    assert kb.search('rule R-X1')[0]['id'] == 'R-X1'


# ------------------------------------------------------------------ tool protocol + plugins
def test_parse_tool_call_variants():
    assert agent.parse_tool_call('x\n```tool\n{"name": "calc", "args": {"expression": "1+1"}}\n```')['name'] == 'calc'
    assert agent.parse_tool_call("```tool\n{'name': 'calc', 'args': {}}\n```")['name'] == 'calc'
    assert agent.parse_tool_call('```tool\nnot json\n```')['name'] == '__bad__'
    assert agent.parse_tool_call('plain answer') is None


def test_plugin_tools(tmp_path):
    (tmp_path / 'ship_mcp.py').write_text("def hello(name):\n    return {'hi': name}\nTOOLS = {'hello': (hello, 'say hi', {'type': 'object'})}\n")
    t = agent.Tools(tmp_path / 'w')
    assert t.load_plugin(str(tmp_path)) == 1
    assert t.call('hello', {'name': 'x'}) == {'hi': 'x'}
    assert 'error' in t.call('nope', {})


# ------------------------------------------------------------------ end-to-end with a mock model server
class MockLLM(BaseHTTPRequestHandler):
    """first turn: call panel_mesh; after a TOOL_RESULT: final answer. Streams like llama-server."""
    def log_message(self, *a):
        pass

    def do_GET(self):
        b = b'{"data": [{"id": "local"}]}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last = body['messages'][-1]['content']
        if last.startswith('TOOL_RESULT'):
            n = json.loads(last.split(':', 1)[1])['elements']
            text = f'Mesh done: **{n}** elements.'
        else:
            text = '```tool\n' + json.dumps({'name': 'panel_mesh', 'args': {'name': 'mock', 'length': 2400, 'width': 1600}}) + '\n```'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for i in range(0, len(text), 7):
            self.wfile.write(b'data: ' + json.dumps({'choices': [{'delta': {'content': text[i:i + 7]}}]}).encode() + b'\n\n')
        self.wfile.write(b'data: [DONE]\n\n')


@pytest.fixture
def mock_llm():
    s = ThreadingHTTPServer(('127.0.0.1', 0), MockLLM)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    yield f'http://127.0.0.1:{s.server_address[1]}'
    s.shutdown()


def test_agent_loop(mock_llm, tmp_path):
    tools = agent.Tools(tmp_path)
    ev = list(agent.run(agent.LLM(mock_llm), tools, [{'role': 'user', 'content': 'mesh it'}]))
    kinds = [e['type'] for e in ev if e['type'] != 'text']
    assert kinds == ['tool_call', 'tool_result', 'done']
    res = ev[[e['type'] for e in ev].index('tool_result')]
    assert 'mesh' in res and res['result']['files']['bdf'] == 'mock.bdf'
    assert ev[-1]['content'].startswith('Mesh done')


def test_gui_server_end_to_end(mock_llm, tmp_path):
    tools = agent.Tools(tmp_path, knowledge.Knowledge())
    server.STATE.update(llm=agent.LLM(mock_llm), tools=tools, lan=False)
    srv = ThreadingHTTPServer(('127.0.0.1', 0), server.H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{srv.server_address[1]}'
    try:
        html = urllib.request.urlopen(base + '/').read().decode()
        assert '<title>ShipBrain</title>' in html
        st = json.loads(urllib.request.urlopen(base + '/api/status').read())
        assert st['model_ok'] and 'panel_mesh' in st['tools']
        req = urllib.request.Request(base + '/api/chat', json.dumps({'messages': [{'role': 'user', 'content': 'mesh'}]}).encode(),
                                     {'Content-Type': 'application/json'})
        evs = [json.loads(l[6:]) for l in urllib.request.urlopen(req).read().decode().split('\n\n') if l.startswith('data: ')]
        assert [e['type'] for e in evs if e['type'] != 'text'] == ['tool_call', 'tool_result', 'done']
        # offline slash command works without the model
        req = urllib.request.Request(base + '/api/chat', json.dumps({'messages': [{'role': 'user', 'content': '/calc {"expression": "2*21"}'}]}).encode(),
                                     {'Content-Type': 'application/json'})
        evs = [json.loads(l[6:]) for l in urllib.request.urlopen(req).read().decode().split('\n\n') if l.startswith('data: ')]
        assert evs[1]['result']['value'] == 42
        assert b'mock.bdf' in urllib.request.urlopen(base + '/api/files').read()
        assert urllib.request.urlopen(base + '/files/mock.bdf').read().startswith(b'$ shipbrain')
        # path traversal is blocked
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(base + '/files/..%2F..%2Fetc%2Fpasswd')
    finally:
        srv.shutdown()


def test_dataset_generation(tmp_path):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'training'))
    import make_dataset
    make_dataset.main(['--n', '40', '--eval-n', '5', '--no-cad', '--out', str(tmp_path / 't.jsonl'), '--eval-out', str(tmp_path / 'e.jsonl')])
    rows = [json.loads(l) for l in open(tmp_path / 't.jsonl')]
    assert len(rows) == 40
    for r in rows:
        roles = [m['role'] for m in r['messages']]
        rest = [x for x in roles if x != 'system']
        assert roles[0] == 'system' and rest[0] == 'user' and roles[-1] == 'assistant'
        assert roles.index('user') == len(roles) - len(rest)          # system messages only at the start
        for m in r['messages']:
            if m['role'] == 'assistant' and '```tool' in m['content']:
                assert agent.parse_tool_call(m['content'])['name'] != '__bad__'
