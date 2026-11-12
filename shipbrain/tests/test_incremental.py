import gzip, json, os
from training import incremental as I


def _w(p, rows):
    with open(p, 'w') as f:
        for r in rows:
            f.write(json.dumps(r) + '\n')


def _rows(a, b):
    return [{'messages': [{'role': 'user', 'content': f'q{i}'}, {'role': 'assistant', 'content': f'a{i}'}]} for i in range(a, b)]


def test_first_run_is_full_then_only_new_samples_plus_replay(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    os.makedirs('data')
    _w('data/a_train.jsonl', _rows(0, 1000))
    st = 'state/manifest.json.gz'
    assert I.plan(I.files_of(['data/*_train.jsonl']), st, 'B')['mode'] == 'full'
    I.commit(I.files_of(['data/*_train.jsonl']), st, 'B', 'r1')
    _w('data/a_train.jsonl', _rows(0, 1000))                                 # same data again
    _w('data/b_train.jsonl', _rows(5000, 5050))                              # 50 new samples in a new file
    r = I.plan(I.files_of(['data/*_train.jsonl']), st, 'B', replay=0.1)
    assert r['mode'] == 'incremental' and r['new'] == 50 and r['old'] == 1000
    kept = sum(1 for _ in open('data/a_train.jsonl'))
    assert 60 <= kept <= 140 and kept == r['replayed']                       # about 10 % of the old ones replayed
    assert sum(1 for _ in open('data/b_train.jsonl')) == 50
    assert sum(1 for _ in open('data_full/a_train.jsonl')) == 1000           # originals kept for the commit


def test_replay_zero_trains_only_new_and_base_change_forces_full(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    os.makedirs('data')
    _w('data/a_train.jsonl', _rows(0, 100))
    st = 'state/manifest.json.gz'
    I.commit(I.files_of(['data/*_train.jsonl']), st, 'B', 'r1')
    _w('data/a_train.jsonl', _rows(0, 130))
    r = I.plan(I.files_of(['data/*_train.jsonl']), st, 'B', replay=0.0)
    assert (r['new'], r['replayed']) == (30, 0) and sum(1 for _ in open('data/a_train.jsonl')) == 30
    assert I.plan(I.files_of(['data_full/*_train.jsonl']), st, 'OTHER', inplace=False)['mode'] == 'full'


def test_commit_records_everything_and_eval_files_are_ignored(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    os.makedirs('data')
    _w('data/a_train.jsonl', _rows(0, 10))
    _w('data/eval.jsonl', _rows(100, 110))
    assert I.files_of(['data/*.jsonl']) == ['data/a_train.jsonl']
    st = 'state/manifest.json.gz'
    r = I.commit(I.files_of(['data/*.jsonl']), st, 'B', 'r1')
    assert r['added'] == 10
    assert I.commit(I.files_of(['data/*.jsonl']), st, 'B', 'r2')['added'] == 0           # nothing new the second time
    assert len(json.load(gzip.open(st, 'rt'))['keys']) == 10
