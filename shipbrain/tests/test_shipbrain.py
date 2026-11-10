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


# ------------------------------------------------------------------ FE model: formats, editing, 1D/2D/3D
from shipbrain.femodel import FEModel  # noqa: E402


def _bare(tmp_path, h=50):
    spec = {'name': 'c', 'element_size': h, 'fix': [{'x': 0}, {'x': 2000}, {'y': 0}, {'y': 1000}],
            'loads': [{'plates': ['P'], 'pressure': 0.05}],
            'plates': [{'id': 'P', 't': 20, 'outline': [[0, 0, 0], [2000, 0, 0], [2000, 1000, 0], [0, 1000, 0]]}]}
    m, _ = platemesh.build_plates(spec, tmp_path, formats=())
    return FEModel.from_mesh(m)


def test_format_round_trips_keep_the_model(tmp_path):
    f = _bare(tmp_path)
    for ext in ('bdf', 'inp'):
        f.write(str(tmp_path / f'r.{ext}'))
        g = FEModel.read(str(tmp_path / f'r.{ext}'))
        assert len(g.nodes) == len(f.nodes) and len(g.elems) == len(f.elems)
        assert len(g.spc) == len(f.spc) and sum(len(l['elems']) for l in g.loads) == len(f.elems)
        assert max(np.abs(g.nodes[k] - f.nodes[k]).max() for k in f.nodes) < 1e-5
    f.write(str(tmp_path / 'r.mac'))
    txt = open(tmp_path / 'r.mac').read()
    assert txt.count('\nEN,') == len(f.elems) and 'SECDATA,20' in txt and 'SFE,' in txt
    assert len(f.write_drivers(str(tmp_path / 'r'))) == 2


@pytest.mark.skipif(not solver.ccx_path(), reason='CalculiX not installed')
def test_same_answer_through_every_format(tmp_path):
    f = _bare(tmp_path, 100)
    f.write(str(tmp_path / 'a.inp'))
    ref = solver.run_calculix(str(tmp_path / 'a.inp'))['max_displacement_mm']
    f.write(str(tmp_path / 'a.bdf'))
    FEModel.read(str(tmp_path / 'a.bdf')).write(str(tmp_path / 'b.inp'))
    assert solver.run_calculix(str(tmp_path / 'b.inp'))['max_displacement_mm'] == pytest.approx(ref, rel=1e-6)


@pytest.mark.skipif(not solver.ccx_path(), reason='CalculiX not installed')
def test_refine_keeps_supports_and_converges(tmp_path):
    f = _bare(tmp_path, 50)
    f.refine()
    f.write(str(tmp_path / 'r.inp'))
    w = solver.run_calculix(str(tmp_path / 'r.inp'))['max_displacement_mm']
    assert abs(w / fea.plate_pressure(2000, 1000, 20, 0.05, 'clamped')['w_max_mm'] - 1) < 0.02


def test_mirror_merge_delete_renumber(tmp_path):
    f = _bare(tmp_path, 100)
    n0, e0 = len(f.nodes), len(f.elems)
    r = f.mirror('y', 1000)
    assert len(f.elems) == 2 * e0 and r['merged_nodes'] == 21 and f.check()['all_elements_parts'] == 1
    d = f.delete(box=[[0, 1000, -1], [500, 2000, 1]])
    assert d['deleted_elements'] > 0 and f.check()['free_nodes_all'] == 0
    f.renumber(1001, 5001)
    assert min(f.nodes) == 1001 and min(f.elems) == 5001


def test_dimension_conversions(tmp_path):
    f = _bare(tmp_path, 100)
    s = f.copy()
    s.shell_to_solid(layers=2)
    c = s.check()
    assert c['by_dimension']['3D'] == 2 * len(f.elems) and c['inverted_solids'] == 0 and c['all_elements_parts'] == 1
    k = s.copy()
    assert k.solid_skin()['skin_shells'] == 2 * len(f.elems) + 2 * 2 * (20 + 10)      # top + bottom + 2 layers on 60 edge faces
    b = f.copy()
    assert b.edges_to_beams()['bars_added'] == 60
    assert b.beams_to_shells(100, 10)['web_shells'] == 120 and b.check()['all_elements_parts'] == 1


# ------------------------------------------------------------------ 1D in the plate mesher, cleaning, fatigue
def test_beams_share_plate_nodes():
    beams = [{'id': 'L1', 'a': [0, 500, 0], 'b': [2000, 500, 0], 'profile': {'type': 'FlatBar', 'h': 150, 't': 12}}]
    m = platemesh.mesh_plates([{'id': 'P', 't': 12, 'outline': [[0, 0, 0], [2000, 0, 0], [2000, 1000, 0], [0, 1000, 0]]}], 100, beams=beams)
    bars = [e for e in m.elems if e['type'] == 'bar']
    assert len(bars) == 20
    plate_nodes = {n for e in m.elems if e['type'] == 'quad' for n in e['nodes']}
    assert all(n in plate_nodes for e in bars for n in e['nodes'])
    assert bars[0]['offset'][2] < 0                                  # hangs below the plate


def test_geometry_cleaning_makes_dirty_input_meshable():
    import copy
    from shipbrain import geoclean
    dirty = copy.deepcopy(GRILLAGE)
    dirty[1]['outline'][0] = [0, 1000.8, 0.6]
    dirty[1]['outline'].insert(1, [3000, 1000, 0])
    dirty.append(copy.deepcopy(dirty[3]))
    dirty[-1]['id'] = 'W_copy'
    dirty.append({'id': 'SLIVER', 't': 5, 'outline': [[0, 0, -10], [5, 0, -10], [5, 1, -10]]})
    clean, act = geoclean.clean_plates(dirty)
    assert len(clean) == len(GRILLAGE) and any('duplicate' in a for a in act) and any('sliver' in a for a in act)
    m = platemesh.mesh_plates(clean, 200)
    assert meshcheck.check(m.xyz, [e['nodes'] for e in m.elems])['verdict'] == 'ok'


@pytest.mark.skipif(not solver.ccx_path(), reason='CalculiX not installed')
def test_fatigue_hotspot(tmp_path):
    from shipbrain import fatigue
    m, info = fatigue.fatigue_mesh(GRILLAGE, [3000, 1000, -300], size=200, out_dir=str(tmp_path), loads=[{'plates': ['G1'], 'pressure': 1.0}])
    assert info['t_ref'] == 10 and info['check']['verdict'] == 'ok' and len(info['readout_points']) == 4
    assert max(abs(e - 10) for e in [np.linalg.norm(np.subtract(m.xyz[a['nodes'][0] - 1], m.xyz[a['nodes'][1] - 1])) for a in m.elems[:50]]) < 6
    r = solver.run_calculix(info['files']['inp'])
    h = fatigue.hotspot_stress(r['frd'], info['readout_points'])
    w = h['worst']
    face = 'top' if abs(w['top']['hot_spot']) >= abs(w['bottom']['hot_spot']) else 'bottom'
    assert w[face]['hot_spot'] == pytest.approx(1.5 * w[face]['s_0.5t'] - 0.5 * w[face]['s_1.5t'], abs=0.02)


# ------------------------------------------------------------------ drawings
def _plan(path, extra=False):
    ezdxf = pytest.importorskip('ezdxf')
    doc = ezdxf.new()
    ms = doc.modelspace()
    ms.add_lwpolyline([(0, 0), (6000, 0), (6000, 4000), (0, 4000)], close=True, dxfattribs={'layer': 'DECK'})
    ms.add_lwpolyline([(4200, 1600), (5200, 1600), (5200, 2400), (4200, 2400)], close=True, dxfattribs={'layer': 'OPENING'})
    for y in (1000, 3000):
        ms.add_line((0, y), (6000, y), dxfattribs={'layer': 'GIRDER'})
    ms.add_line((3000, 0), (3000, 4000), dxfattribs={'layer': 'WEB_FRAME'})
    ms.add_line((0, 500), (3000, 500), dxfattribs={'layer': 'STIFF'})
    if extra:
        ms.add_line((0, 2500), (6000, 2500), dxfattribs={'layer': 'GIRDER'})
    doc.saveas(path)
    return path


def test_drawing_to_3d_and_mesh(tmp_path):
    from shipbrain import drawings
    r = drawings.dxf_to_plates(_plan(str(tmp_path / 'p.dxf')))
    assert r['report']['outlines'] == 1 and r['report']['webs'] == 3 and r['report']['stiffeners'] == 1
    assert len(r['plates'][0]['holes']) == 1
    m, info = platemesh.build_plates({'name': 'p', 'plates': r['plates'], 'beams': r['beams'], 'element_size': 250}, str(tmp_path))
    assert info['check']['verdict'] == 'ok' and info['bars'] > 0
    if pytest.importorskip('cadquery'):
        assert drawings.plates_to_step(r['plates'], str(tmp_path / 'p.step'), r['beams'])['solids'] == 5


def test_compare_two_drawings(tmp_path):
    from shipbrain import drawings
    a, b = _plan(str(tmp_path / 'a.dxf')), _plan(str(tmp_path / 'b.dxf'), extra=True)
    r = drawings.compare_drawings(a, b, str(tmp_path / 'o.png'))
    assert r['only_in_A_px'] == 0 and len(r['regions_only_in_B']) == 1 and 0.85 < r['similarity'] < 1
    assert drawings.compare_drawings(a, a, str(tmp_path / 'o2.png'))['similarity'] == 1.0


def test_mesh_vs_drawing(tmp_path):
    from shipbrain import drawings
    from PIL import Image
    p = _plan(str(tmp_path / 'a.dxf'))
    r = drawings.dxf_to_plates(p)
    m, _ = platemesh.build_plates({'name': 'p', 'plates': r['plates'], 'beams': r['beams'], 'element_size': 250}, str(tmp_path), formats=())
    img, box = drawings.render_dxf(p, 1200)
    Image.fromarray(img.astype('uint8')).save(tmp_path / 'a.png')
    f = FEModel.from_mesh(m)
    good = drawings.compare_mesh_drawing(f, str(tmp_path / 'a.png'), box, out_png=str(tmp_path / 'g.png'))
    assert good['pass'] and good['mesh_on_drawing'] > 0.95
    f.translate([120, -80, 0])
    bad = drawings.compare_mesh_drawing(f, str(tmp_path / 'a.png'), box, out_png=str(tmp_path / 'b.png'))
    assert not bad['pass'] and abs(bad['best_shift_mm'][0] + 120) < 20 and abs(bad['best_shift_mm'][1] - 80) < 20


def test_file_info_plain_english(tmp_path):
    from shipbrain.fileinfo import file_info
    f = _bare(tmp_path, 200)
    f.write(str(tmp_path / 'm.bdf'))
    t = file_info(str(tmp_path / 'm.bdf'))['plain_english']
    assert 'finite element model' in t and 'no problems found' in t
    assert 'DXF' in file_info(_plan(str(tmp_path / 'p.dxf')))['plain_english']


def test_agent_fe_tools(tmp_path):
    t = agent.Tools(tmp_path)
    f = _bare(tmp_path, 200)
    f.write(str(tmp_path / 'm.bdf'))
    c = t.call('fe_convert', {'file': 'm.bdf'})
    assert 'm_conv.inp' in c['files'] and 'm_conv.mac' in c['files']
    e = t.call('fe_edit', {'file': 'm.bdf', 'ops': [{'op': 'mirror', 'axis': 'y', 'value': 1000}, {'op': 'refine'}]})
    assert e['parts'] == 1 and e['model']['elements'] == 4 * 2 * len(f.elems)
    assert 'error' in t.call('fe_edit', {'file': 'm.bdf', 'ops': [{'op': '__class__'}]})


# ------------------------------------------------------------------ structure models (member level)
def _structure():
    pan = lambda pid, o, u, w, plates, st: {'id': pid, 'cs': {'origin': o, 'uaxis': u, 'waxis': w}, 'plates': plates,
                                             'holes': [], 'stiffeners': st, 'brackets': []}
    deck = pan('DECK', [0, 0, 0], [1, 0, 0], [0, 0, 1],
               [{'name': 'D1', 'thk': 12.0, 'grade': 'A', 'contour': [[0, 0], [6000, 0], [6000, 4000], [0, 4000], [0, 0]]}],
               [{'name': f'L{k}', 'sec': 'FB150', 'grade': 'A', 'trace': [[0, y], [6000, y]], 'incl': [0, 0, -1]} for k, y in enumerate((800, 1600, 2400, 3200))])
    gir = pan('GIR', [0, 2000, 0], [1, 0, 0], [0, -1, 0],
              [{'name': 'G1', 'thk': 10.0, 'grade': 'A', 'contour': [[0, 0], [6000, 0], [6000, -600], [0, -600]]}], [])
    return {'sections': {'FB150': {'type': 'FlatBar', 'H': 150.0, 't': 12.0}, 'HP200': {'type': 'Other', 'params': [200.0, 90.0, 10.0]}},
            'blocks': [{'id': 'B1', 'panels': [deck, gir]}]}


def test_compare_structures_finds_each_change():
    import copy
    from shipbrain import members
    A = _structure()
    B = copy.deepcopy(A)
    B['blocks'][0]['panels'][0]['plates'][0]['thk'] = 14.0                    # thickness change
    del B['blocks'][0]['panels'][0]['stiffeners'][3]                           # removed
    B['blocks'][0]['panels'][0]['stiffeners'][0]['sec'] = 'HP200'             # section change
    s = B['blocks'][0]['panels'][0]['stiffeners'][1]
    s['trace'] = [[u, v + 150] for u, v in s['trace']]                        # moved 150 mm
    r = members.compare(A, B)
    assert r['counts'] == {'removed': 1, 'added': 0, 'changed': 2, 'moved': 1}
    assert 'thk 12.0 -> 14.0' in str(r['details']['changed']) and 'FB150 -> HP200' in str(r['details']['changed'])
    assert members.compare(A, A)['match_ratio'] == 1.0


def test_structure_to_mesh(tmp_path):
    t = agent.Tools(tmp_path)
    json.dump(_structure(), open(tmp_path / 's.json', 'w'))
    r = t.call('structure_to_mesh', {'file': 's.json', 'element_size': 250})
    assert r['check']['parts'] == 1 and r['bars'] > 0 and r['check']['verdict'] == 'ok', r.get('plain_english')
    assert 'connected piece' in r['plain_english']


# ------------------------------------------------------------------ semantic drawing comparison
def test_number_classes():
    from shipbrain.drawdiff import number_class
    assert number_class('a5') == 'weld size' and number_class('6 TYP.') == 'weld size'
    assert number_class('t=12') == 'plate thickness' and number_class('FB150x12') == 'section size'
    assert number_class('FR.23') == 'frame number' and number_class('2400') == 'dimension'


def test_semantic_dxf_compare(tmp_path):
    ezdxf = pytest.importorskip('ezdxf')
    from shipbrain.drawdiff import compare_vector

    def plan(path, rev):
        doc = ezdxf.new()
        doc.linetypes.add('DASHED', [0.5, 0.25, -0.25])
        ms = doc.modelspace()
        ms.add_line((0, 1000), (6000, 1000), dxfattribs={'layer': 'GIRDER'})
        ms.add_line((0, 3000), (6000, 3000), dxfattribs={'layer': 'GIRDER', 'linetype': 'DASHED' if rev else 'CONTINUOUS'})
        ms.add_text('t=14' if rev else 't=12', dxfattribs={'insert': (500, 2000), 'height': 80})
        if rev:
            ms.add_line((3000, 0), (3000, 4000), dxfattribs={'layer': 'WEB'})
        doc.saveas(path)
        return path
    r = compare_vector(plan(str(tmp_path / 'a.dxf'), 0), plan(str(tmp_path / 'b.dxf'), 1))
    assert r['lines'] == {'removed': 0, 'added': 1, 'style_changed': 1}
    assert r['texts']['changed'] == 1 and r['texts']['changed_by_class'] == {'plate thickness': 1}


def test_semantic_pdf_compare(tmp_path):
    pytest.importorskip('pdfplumber')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from shipbrain.drawdiff import compare_vector

    def pdf(path, rev):
        f = plt.figure(figsize=(6, 4))
        ax = f.add_axes([0, 0, 1, 1])
        ax.set_xlim(0, 600)
        ax.set_ylim(0, 400)
        ax.axis('off')
        ax.plot([50, 500], [100, 100], lw=1.5, color='k')
        ax.plot([50, 500], [300, 300], lw=0.3, color='k', ls='--' if rev else '-')
        ax.text(60, 200, 'HP200x10' if rev else 'FB150x12', fontsize=9)
        f.savefig(path)
        plt.close(f)
        return path
    r = compare_vector(pdf(str(tmp_path / 'a.pdf'), 0), pdf(str(tmp_path / 'b.pdf'), 1))
    assert r['lines']['style_changed'] == 1 and r['texts']['changed_by_class'] == {'section size': 1}
    from shipbrain import drawings
    assert drawings.load_image(str(tmp_path / 'a.pdf')).ndim == 2
    from shipbrain.fileinfo import file_info
    assert 'PDF with 1 page' in file_info(str(tmp_path / 'a.pdf'))['plain_english']


# ------------------------------------------------------------------ memory, hybrid search, MCP, CPU training
def test_memory_and_feedback(tmp_path):
    from shipbrain.memory import Memory
    m = Memory(str(tmp_path))
    a = m.remember('Our yard uses 700 mm frame spacing in the engine room', ['practice'])
    m.remember('Brackets are modelled as shell elements')
    assert m.recall('what frame spacing in the engine room?')[0]['id'] == a['id']
    m.feedback(a['id'], False)
    m.feedback(a['id'], False)
    assert m.recall('frame spacing engine room') == []                       # clearly disliked -> not used
    r = m.answer_feedback([{'role': 'user', 'content': 'stiffener spacing?'}, {'role': 'assistant', 'content': '600'}],
                          False, 'Use 800 mm stiffener spacing on decks')
    assert 'memory' in r and Memory(str(tmp_path)).recall('stiffener spacing decks')
    t = agent.Tools(tmp_path / 'w', memory=Memory(str(tmp_path)))
    ctx, used = agent.retrieve(t, 'which stiffener spacing on decks?')
    assert any(u.startswith('memory:') for u in used) and 'taught by the user' in ctx


def test_hybrid_search_with_embedding_server(tmp_path):
    class Emb(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            vec = lambda t: [float('hull' in t.lower() or 'shell' in t.lower()), float('weld' in t.lower()), 0.1]
            out = json.dumps({'data': [{'index': i, 'embedding': vec(t)} for i, t in enumerate(body['input'])]}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(out)))
            self.end_headers()
            self.wfile.write(out)
    s = ThreadingHTTPServer(('127.0.0.1', 0), Emb)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    try:
        (tmp_path / 'docs').mkdir()
        (tmp_path / 'docs' / 'a.md').write_text('# Outer shell\n\nThe hull plating thickness is checked against slamming.')
        (tmp_path / 'docs' / 'b.md').write_text('# Joints\n\nFillet welds need a throat of 0.7 t.')
        emb = knowledge.Embedder(f'http://127.0.0.1:{s.server_address[1]}')
        kb = knowledge.load([str(tmp_path / 'docs')], cache_dir=str(tmp_path / 'c'), embedder=emb)
        assert kb.search('shell', 1)[0]['source'] == 'a.md'                   # meaning + keywords fused
        assert kb.search('welds', 2, scope='b.md')[0]['source'] == 'b.md'
        assert os.path.exists(tmp_path / 'c' / 'embeddings.npz')
        kb2 = knowledge.load([str(tmp_path / 'docs')], cache_dir=str(tmp_path / 'c'))   # cached index, no re-read
        assert len(kb2) == len(kb)
    finally:
        s.shutdown()


def test_mcp_server_lists_and_calls_tools(tmp_path):
    from shipbrain import mcp_server
    t = agent.Tools(tmp_path)
    r = mcp_server.handle(t, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})
    names = {x['name'] for x in r['result']['tools']}
    assert {'plates_mesh', 'fe_convert', 'compare_structures', 'remember'} <= names
    r = mcp_server.handle(t, {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'calc', 'arguments': {'expression': '6*7'}}})
    assert json.loads(r['result']['content'][0]['text'])['value'] == 42
    assert mcp_server.handle(t, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}) is None
