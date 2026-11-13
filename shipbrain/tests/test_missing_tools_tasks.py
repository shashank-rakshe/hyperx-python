import gzip, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def test_generator_makes_real_alternating_samples_without_paths(tmp_path):
    out = str(tmp_path / 'm.jsonl.gz')
    r = subprocess.run([sys.executable, '-W', 'ignore', os.path.join(ROOT, 'training', 'missing_tools_tasks.py'), '--n', '8', '--seed', '3', '--out', out],
                       capture_output=True, text=True, timeout=500, env=dict(os.environ, MPLBACKEND='Agg'))
    assert r.returncode == 0, r.stderr[-500:]
    rows = [json.loads(l) for l in gzip.open(out, 'rt')]
    assert len(rows) == 8
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert roles[0] == 'user' and roles[-1] == 'assistant' and all(a != b for a, b in zip(roles, roles[1:]))
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    assert any('TOOL_RESULT' in m['content'] for x in rows for m in x['messages'])               # the results are real tool output


def test_second_generator_makes_real_samples_without_paths(tmp_path):
    out = str(tmp_path / 'm2.jsonl.gz')
    r = subprocess.run([sys.executable, '-W', 'ignore', os.path.join(ROOT, 'training', 'missing_tools2_tasks.py'), '--n', '8', '--seed', '2', '--out', out],
                       capture_output=True, text=True, timeout=500, env=dict(os.environ, MPLBACKEND='Agg'))
    assert r.returncode == 0, r.stderr[-500:]
    rows = [json.loads(l) for l in gzip.open(out, 'rt')]
    assert len(rows) == 8
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s and '/root/' not in s
    assert all(x['messages'][0]['role'] == 'user' and x['messages'][-1]['role'] == 'assistant' for x in rows)
