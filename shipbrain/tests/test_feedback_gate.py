import json, os, subprocess, sys
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'training'))
import accept_gate
from shipbrain import feedback

CONV = [{'role': 'user', 'content': 'Check the chain of MV Nordic Star, mail me at j.doe@acme.com'},
        {'role': 'assistant', 'content': 'Utilisation 0.8'}]


def _write(tmp_path, rows):
    (tmp_path / 'feedback.jsonl').write_text('\n'.join(json.dumps(r) for r in rows) + '\n')


def test_export_keeps_useful_scrubs_and_dedupes(tmp_path):
    rows = [{'good': False, 'comment': 'It is 0.08 (C:\\Users\\jdoe\\x.dat)', 'messages': CONV},
            {'good': False, 'comment': 'It is 0.08 (C:\\Users\\jdoe\\x.dat)', 'messages': CONV},      # duplicate
            {'good': False, 'comment': '', 'messages': CONV},                                         # bare thumbs-down
            {'good': True, 'comment': '', 'messages': CONV},
            {'good': True, 'comment': '', 'messages': CONV[:1]}]                                      # too short
    _write(tmp_path, rows)
    man = feedback.export(str(tmp_path), str(tmp_path / 'out'), ['Nordic Star', 'acme'])
    assert man['records'] == 2 and man['corrections'] == 1 and man['liked'] == 1
    assert man['dropped']['duplicate'] == 1 and man['dropped']['no correction'] == 1 and man['dropped']['too short'] == 1
    text = (tmp_path / 'out' / 'feedback.jsonl').read_text()
    for private in ('Nordic Star', 'j.doe@acme.com', 'jdoe', 'acme'):
        assert private.lower() not in text.lower()
    assert '<email>' in text and '<name>' in text and '<user-folder>' in text


def test_request_keeps_fields_and_adds_dataset(tmp_path):
    p = tmp_path / 'TRAIN_REQUEST.json'
    p.write_text(json.dumps({'n': 3000, 'datasets': ['me/rules']}))
    req = feedback.request('me/fb', str(p))
    assert req['n'] == 3000 and req['datasets'] == ['me/rules', 'me/fb']
    assert feedback.request('me/fb', str(p))['datasets'] == ['me/rules', 'me/fb']                     # no duplicate


def test_upload_uses_private_dataset_and_reports_failure(tmp_path, monkeypatch):
    calls = []

    class R:
        def __init__(self, rc): self.returncode, self.stdout, self.stderr = rc, 'ok', ''

    def fake(cmd, **k):
        calls.append(cmd[1:3])
        return R(1 if cmd[2] == 'version' else 0)               # first run: no dataset yet -> create
    monkeypatch.setattr(subprocess, 'run', fake)
    out = tmp_path / 'o'; out.mkdir()
    feedback.upload(str(out), 'me/fb')
    assert calls == [['datasets', 'version'], ['datasets', 'create']]
    assert json.load(open(out / 'dataset-metadata.json'))['isPrivate'] is True
    monkeypatch.setattr(subprocess, 'run', lambda cmd, **k: R(1))
    with pytest.raises(RuntimeError, match='Kaggle upload failed'):
        feedback.upload(str(out), 'me/fb')


def S(**kw):
    base = {'complete': '20/30 (67 %)', 'messy': '10/22 (45 %)', 'missing': '8/15 (53 %)', 'multi': '4/8 (50 %)',
            'no_tool': '6/8 (75 %)', 'ALL': '48/83 (58 %)'}
    base.update(kw)
    return base


def test_gate_accepts_improvement_rejects_regressions():
    better = S(complete='26/30 (87 %)', messy='16/22 (73 %)', missing='13/15 (87 %)', ALL='65/83 (78 %)')
    assert accept_gate.gate(S(), better)['accepted']
    r = accept_gate.gate(S(), S(missing='5/15 (33 %)', complete='28/30 (93 %)', ALL='51/83 (61 %)'))
    assert not r['accepted'] and any('missing' in x for x in r['reasons'])              # asks less often: rejected even if overall up
    r = accept_gate.gate(S(), S(messy='3/22 (14 %)', ALL='41/83 (49 %)'))
    assert not r['accepted'] and any('overall' in x for x in r['reasons'])
    r = accept_gate.gate(S(), better, {'n': 100, 'tool_ok': 90, 'args_ok': 80}, {'n': 100, 'tool_ok': 80, 'args_ok': 80})
    assert not r['accepted'] and any('tool_ok' in x for x in r['reasons'])
