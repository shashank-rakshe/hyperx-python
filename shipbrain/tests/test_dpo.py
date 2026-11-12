import json, os, random, sys
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'training'))
import dpo_pairs


CONV = [{'role': 'user', 'content': 'Check an 84 mm R3 chain, 700 m, 120 m depth, anchor 640 m'},
        {'role': 'assistant', 'content': '```tool\n{"name": "mooring", "args": {"depth": 120}}\n```'},
        {'role': 'user', 'content': 'TOOL_RESULT mooring: {"fairlead_tension_kN": 230}'},
        {'role': 'assistant', 'content': 'Fairlead tension 230 kN at 67.4 deg, utilisation 0.08 - OK. (Static equilibrium; run the '
                                         'dynamics with waves and vessel motion for the design tension.)'}]


def test_pairs_from_a_conversation():
    pairs = {p['kind']: p for p in dpo_pairs.from_conversation(CONV, random.Random(0))}
    assert set(pairs) == {'unfaithful', 'invented', 'overclaim'}
    assert pairs['invented']['chosen'].startswith('```tool') and pairs['invented']['prompt'] == CONV[:1]
    assert pairs['unfaithful']['rejected'] != CONV[-1]['content'] and pairs['unfaithful']['prompt'] == CONV[:3]
    assert 'Static' not in pairs['overclaim']['rejected'] and 'Static' in pairs['overclaim']['chosen']


def test_feedback_pairs_only_from_corrections():
    bad = {'good': False, 'comment': 'It is 0.08, not 0.8.', 'messages': CONV[:3] + [{'role': 'assistant', 'content': 'Utilisation 0.8'}]}
    p = dpo_pairs.from_feedback(bad)
    assert p['chosen'] == 'It is 0.08, not 0.8.' and p['rejected'] == 'Utilisation 0.8'
    assert dpo_pairs.from_feedback(dict(bad, comment='')) is None
    assert dpo_pairs.from_feedback(dict(bad, good=True)) is None


def test_builder_skips_eval_and_dedupes(tmp_path):
    for name in ('a.jsonl', 'b.jsonl', 'eval.jsonl'):
        (tmp_path / name).write_text(json.dumps({'messages': CONV}) + '\n')
    out = tmp_path / 'p.jsonl'
    dpo_pairs.main(['--data', str(tmp_path / '*.jsonl'), '--out', str(out)])
    rows = [json.loads(l) for l in open(out)]
    assert len(rows) == 3                                   # a and b are the same conversation; eval is never used


def test_config_across_versions():
    trl = pytest.importorskip('trl')
    import finetune
    c = finetune.make_config(trl.DPOConfig, max_length=1024, max_prompt_length=900, warmup_ratio=0.1, beta=0.1,
                             output_dir='/tmp/x', use_cpu=True, bf16=False, report_to='none')
    assert c.max_length == 1024 and c.beta == 0.1
