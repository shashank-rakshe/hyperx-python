"""
OpenPhysicsAI runs -> training samples (the model learns to pick, set up and run the physics lab, and to read its results).

Builds the copied OpenPhysicsAI (C compiler + make), runs every example scenario that finishes within --timeout seconds
on this machine (as written, and with a changed load / size where it has one), and writes chat samples from the REAL
records: list -> run -> answer. Also samples for its MCP server's operations.

    python training/physics_tasks.py --out data/physics_train.jsonl [--timeout 40]
"""
import argparse, json, os, random, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, openphysics   # noqa: E402

ASK_RUN = ['Simulate this: {t}', 'Run the {n} case', 'Can you compute "{t}"?', '{d} simulation: {t}. What are the results?',
           'Use the physics lab for: {t}']
ASK_LIST = ['What {d} simulations can you run?', 'Which {d} examples does the physics lab have?', 'Show me the {d} scenarios']


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def res(name, out):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(out)}


def _scale_change(sc):
    """a sensible change for a scenario: the first load-like number list or value x1.5 (None if there is none)"""
    for key in ('load', 'loads', 'sloshing', 'flow', 'inflow', 'source', 'heater'):
        v = sc.get(key)
        if isinstance(v, dict):
            for k, x in v.items():
                if k.endswith(('_n', '_w', '_pa', '_m_s', '_nm', '_hz')):
                    unit = {'_n': 'N', '_w': 'W', '_pa': 'Pa', '_m_s': 'm/s', '_nm': 'N m', '_hz': 'Hz'}[next(u for u in ('_m_s', '_nm', '_n', '_w', '_pa', '_hz') if k.endswith(u))]
                    what = k[:-len(next(u for u in ('_m_s', '_nm', '_n', '_w', '_pa', '_hz') if k.endswith(u)))].replace('_', ' ')
                    if isinstance(x, (int, float)) and x:
                        return {key: {k: round(x * 1.5, 6)}}, f'{what} {round(x * 1.5, 6):g} {unit}'
                    if isinstance(x, list) and x and all(isinstance(e, (int, float)) for e in x):
                        return {key: {k: [round(max(x) * 1.5, 6)]}}, f'{what} {round(max(x) * 1.5, 6):g} {unit}'
    return None, None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='data/physics_train.jsonl')
    ap.add_argument('--timeout', type=int, default=40)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--probe-all', action='store_true', help='try every scenario, not only training/data/physics_quick.json')
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    if not openphysics.built():
        openphysics.build()
    import tempfile, subprocess
    work = tempfile.mkdtemp(prefix='sb_phys_')
    T = agent.Tools(work)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    rows, quick = [], []
    qfile = os.path.join(HERE, 'data', 'physics_quick.json')
    known = set(json.load(open(qfile))['quick']) if os.path.exists(qfile) and not a.probe_all else None
    for sc in openphysics.scenarios():
        if known is not None and sc['name'] not in known:
            continue                                         # measured slow (> 40 s on 4 cores) or macOS-only: skipped
        t0 = time.time()
        try:
            p = subprocess.run([openphysics.LABRUN, os.path.join(openphysics.ROOT, 'examples', 'lab', sc['name'] + '.json'),
                                os.path.join(work, 'probe.lab')], capture_output=True, text=True, timeout=a.timeout, cwd=openphysics.ROOT)
            if p.returncode:
                continue
        except subprocess.TimeoutExpired:
            continue
        quick.append(dict(sc, seconds=round(time.time() - t0, 1)))
    print(f'{len(quick)} scenarios run within {a.timeout} s:', ', '.join(f"{q['name']} ({q['seconds']} s)" for q in quick))
    for q in quick:
        ask = r.choice(ASK_RUN).format(t=q['title'], n=q['name'], d=q['domain'])
        args = {'action': 'run', 'scenario': q['name']}
        out = T.call('physics_lab', args)
        if 'error' in out:
            continue
        rows.append({'task': 'physics_run', 'messages': [sysmsg, {'role': 'user', 'content': ask},
                                                         {'role': 'assistant', 'content': tb('physics_lab', args)}, res('physics_lab', out),
                                                         {'role': 'assistant', 'content': out['plain_english']}]})
        ch, what = _scale_change(openphysics.scenario(q['name']))
        if ch:
            args2 = {'action': 'run', 'scenario': q['name'], 'changes': ch}
            out2 = T.call('physics_lab', args2)
            if 'error' not in out2:
                rows.append({'task': 'physics_change', 'messages': [
                    sysmsg, {'role': 'user', 'content': f"{q['title']} - but with {what}. What changes?"},
                    {'role': 'assistant', 'content': tb('physics_lab', args2)}, res('physics_lab', out2),
                    {'role': 'assistant', 'content': out2['plain_english']}]})
    for dom in sorted({q['domain'] for q in openphysics.scenarios()}):
        args = {'action': 'list', 'query': dom}
        out = T.call('physics_lab', args)
        rows.append({'task': 'physics_list', 'messages': [sysmsg, {'role': 'user', 'content': r.choice(ASK_LIST).format(d=dom)},
                                                          {'role': 'assistant', 'content': tb('physics_lab', args)}, res('physics_lab', out),
                                                          {'role': 'assistant', 'content': out['plain_english']}]})
    for qy, ask in (('modal', 'Which vibration / modal operations does OpenPhysicsAI have?'), ('topology', 'Can it do topology optimisation?'),
                    ('mesh', 'What meshing operations can the physics server do?'), ('print', 'What 3D printing simulations are there?')):
        try:
            out = T.call('mcp_tools', {'server': 'openphysics', 'query': qy})
        except Exception:
            continue
        if 'error' in out:
            continue
        rows.append({'task': 'physics_mcp', 'messages': [sysmsg, {'role': 'user', 'content': ask},
                                                         {'role': 'assistant', 'content': tb('mcp_tools', {'server': 'openphysics', 'query': qy})},
                                                         res('mcp_tools', out), {'role': 'assistant', 'content': out['plain_english']}]})
    with open(a.out, 'w', encoding='utf-8') as f:
        for x in rows:
            f.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
