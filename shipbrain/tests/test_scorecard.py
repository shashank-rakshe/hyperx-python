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
    T = agent.Tools(tempfile.mkdtemp(), knowledge.load(None))
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
