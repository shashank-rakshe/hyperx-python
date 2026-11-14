import glob, gzip, json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = sorted(glob.glob(os.path.join(ROOT, 'training', 'data', '*.jsonl.gz')) + glob.glob(os.path.join(ROOT, 'training', 'data', 'generated', '*.jsonl.gz')))
NAMES = re.compile(r'hsma|hyundai|\bHN\d{3,5}\b|90000003|ERM-|mayo-develop', re.I)


def test_every_committed_training_line_is_valid_json_with_messages():
    """a bad line stops the whole training run (it did once: JSONDecodeError after a scrub); every committed set is parsed line by line"""
    assert len(FILES) > 40
    bad = []
    for f in FILES:
        for i, l in enumerate(gzip.open(f, 'rt', encoding='utf-8'), 1):
            if not l.strip():
                continue
            try:
                d = json.loads(l)
            except ValueError as e:
                bad.append((os.path.basename(f), i, str(e)[:60]))
                continue
            if os.path.basename(f).startswith('cad_bank'):              # a bank of code examples that make_dataset reads, not a training file
                continue
            if 'messages' not in d and 'chosen' not in d:
                bad.append((os.path.basename(f), i, 'no messages'))
    assert not bad, bad[:5]


def test_generated_sets_hold_no_company_names_or_company_derived_questions():
    hits = []
    for f in glob.glob(os.path.join(ROOT, 'training', 'data', 'generated', '*.jsonl.gz')):
        t = gzip.open(f, 'rt', encoding='utf-8').read()
        if NAMES.search(t):
            hits.append(os.path.basename(f))
    assert not hits, hits
