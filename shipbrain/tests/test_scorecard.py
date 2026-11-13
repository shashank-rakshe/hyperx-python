import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'training'))
import scorecard as sc


def test_items_file_matches_source_and_categories():
    items = [json.loads(l) for l in open(os.path.join(os.path.dirname(HERE), 'training', 'scorecard.jsonl'))]
    assert items == sc._items()                              # the committed file is the current source
    cats = {i['category'] for i in items}
    assert cats == {'complete', 'messy', 'missing', 'multi', 'no_tool'}


def test_scoring_rules():
    it = next(i for i in sc._items() if i['id'].startswith('messy') and i['expect'].get('tool') == 'plate_check')
    a = it['expect']['args']
    good = '```tool\n' + json.dumps({'name': 'plate_check', 'args': a}) + '\n```'
    assert sc.score(it, good)['ok']
    assert not sc.score(it, good.replace(str(a['t']), str(a['t'] * 3)))['ok']          # wrong thickness
    ask = next(i for i in sc._items() if i['category'] == 'missing')
    assert sc.score(ask, 'Which chain size, line length and anchor distance?')['ok']
    assert not sc.score(ask, '```tool\n{"name": "mooring", "args": {"depth": 100}}\n```')['ok']   # invented inputs
    nt = next(i for i in sc._items() if i['category'] == 'no_tool')
    assert sc.score(nt, 'A web frame is a deep transverse member supporting the longitudinals.')['ok']
    assert not sc.score(nt, '```tool\n{"name": "plate_check", "args": {"a": 1}}\n```')['ok']


def test_tool_selector_recall_and_prompt():
    import gzip, glob, tempfile
    from shipbrain import agent, knowledge
    T = agent.Tools(tempfile.mkdtemp(), knowledge.load(None), allow_code=True)       # the app shows the code tools by default
    hit = tot = 0
    for f in sorted(glob.glob(os.path.join(os.path.dirname(HERE), 'training', 'data', '*.jsonl.gz'))):
        for l in gzip.open(f, 'rt'):
            m = json.loads(l).get('messages') or []
            q = next((x['content'] for x in m if x['role'] == 'user' and isinstance(x['content'], str)), '')
            used = {c['name'] for x in m if x['role'] == 'assistant' and isinstance(x['content'], str)
                    for c in [agent.parse_tool_call(x['content'])] if c}
            sel = set(agent.select_tools(T, q))
            tot += len(used)
            hit += len(used & sel)
    assert tot > 1000 and hit / tot > 0.97                   # the needed tool is shown in full almost always
    full, small = agent.system_prompt(T), agent.system_prompt(T, question='84 mm R3 chain in 120 m water')
    assert len(small) < 0.5 * len(full) and 'mooring(' in small and 'Other tools' in small and 'pipe_flow' in small


def test_correction_memory_worked_example_and_check(tmp_path):
    from shipbrain.memory import Memory
    M = Memory(str(tmp_path))
    conv = [{'role': 'user', 'content': 'Check an 84 mm R3 chain, 700 m, 120 m depth, anchor 640 m'},
            {'role': 'assistant', 'content': '```tool\n{"name": "mooring", "args": {"depth": 120}}\n```'},
            {'role': 'user', 'content': 'TOOL_RESULT mooring: {"utilisation": 0.08}'},
            {'role': 'assistant', 'content': 'Utilisation 0.8 - NOT OK.'}]
    a = M.answer_feedback(conv, False, 'Utilisation is 0.08, so it is OK.')['memory']
    conv[0]['content'] = 'Check an 84 mm R3 chain, 700 m long, 120 m depth, anchor at 640 m'
    b = M.answer_feedback(conv, False, 'Read the utilisation 0.08 from the result.')['memory']
    assert b['id'] == a['id'] and 'given 2 times' in b['note']                 # repeated -> stronger, not a duplicate
    m = M.list()[0]
    assert m['kind'] == 'correction' and m['tool'] == 'mooring' and not m['disagrees_with_tool']
    bad = M.answer_feedback(conv[:3] + [{'role': 'assistant', 'content': 'ok'}], False, 'It should be 0.5.')['memory']
    assert 'check' in bad                                                        # numbers the tool never computed


def test_correction_shown_as_worked_example(tmp_path):
    import tempfile
    from shipbrain import agent, knowledge
    from shipbrain.memory import Memory
    M = Memory(str(tmp_path))
    M.answer_feedback([{'role': 'user', 'content': 'Plate 2800 x 800 x 12 at 0.05 MPa'},
                       {'role': 'assistant', 'content': '```tool\n{"name": "plate_check", "args": {}}\n```'},
                       {'role': 'user', 'content': 'TOOL_RESULT plate_check: {"sigma_max_MPa": 153}'},
                       {'role': 'assistant', 'content': 'Simply supported: 153 MPa'}], False, 'Use clamped edges for our deck plating.')
    T = agent.Tools(tempfile.mkdtemp(), knowledge.load(None))
    T.memory = M
    ctx, used = agent.retrieve(T, 'Plate 2800 x 800 x 12 at 0.05 MPa - stress?')
    assert any(u.startswith('memory:') for u in used) and 'Use clamped edges' in ctx and 'Do it this way now' in ctx
