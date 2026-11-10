"""
ship_eval.py - measures how well a model follows the ship rules (before vs after training).

Every ship sample has an answer made by the rule code, so the model's output can be scored automatically:
  ship_ocr_fix, ship_numclass      JSON fields equal (text / class)
  ship_notes                       JSON equal on every printed field
  ship_review, ship_review_plus    same set of rule codes (C3 C4 C5 C6 PN1 PN4) as the checker; 'No violations' when none
  ship_joint                       rule id named + every number of the answer present (+-1)
  ship_members_json                same members (id, a, b) as the reference
  ship_rule_lookup / _find         the rule id is named (find) / 50 % of the rule words are given (lookup)
  ship_label, ship_method          the rule id(s) named
Usage (Colab, after training):
  from ship_eval import evaluate;  evaluate(lambda img, prompt: ask(model, tok, img, prompt), "ship_test", per_kind=20)
  python ship_eval.py --selftest   (scores the reference answers themselves: must be 100 %)
"""
import json, re, random, collections

CODES = re.compile(r'\b(C3|C4|C5|C6|PN1|PN4)\b')
NUM = re.compile(r'-?\d+(?:\.\d+)?')
RID = re.compile(r'\bR-?[A-Z]*\d+(?:\.\d+)?[\w.\-]*|\bP\d\b')


def _js(t):
    i, j = t.find('{'), t.rfind('}')
    try:
        return json.loads(t[i:j + 1])
    except Exception:
        return None


def _words(t):
    return set(w for w in re.findall(r'[a-z0-9.]{3,}', t.lower()))


def score(kind, out, ref):
    """-> 1.0 / 0.0 (or a fraction) for one answer"""
    if kind in ('ship_ocr_fix', 'ship_numclass'):
        a, b = _js(out), _js(ref)
        key = 'text' if kind == 'ship_ocr_fix' else 'class'
        return float(bool(a) and a.get(key) == b.get(key))
    if kind == 'ship_notes':
        a, b = _js(out), _js(ref)
        if not a:
            return 0.0
        return sum(1 for k, v in b.items() if a.get(k) == v) / max(1, len(b))
    if kind in ('ship_review', 'ship_review_plus'):
        ra = collections.Counter(CODES.findall(ref)); oa = collections.Counter(CODES.findall(out))
        if not ra:
            return float(not oa and 'no violation' in out.lower())
        return float(set(ra) == set(oa))
    if kind == 'ship_joint':
        ids = set(RID.findall(ref.split(':')[0])) or set(RID.findall(ref))
        nums = [float(x) for x in NUM.findall(ref) if abs(float(x)) >= 10]
        onums = [float(x) for x in NUM.findall(out)]
        idok = bool(ids & set(RID.findall(out)))
        numok = all(any(abs(n - o) <= 1 for o in onums) for n in nums)
        return (idok + numok) / 2
    if kind == 'ship_members_json':
        a, b = _js(out), _js(ref)
        if not a or 'members' not in a:
            return 0.0
        key = lambda m: (str(m.get('id')), tuple(m.get('a', [])), tuple(m.get('b', [])))
        A = {key(m) for m in a['members'] if isinstance(m, dict)}; B = {key(m) for m in b['members']}
        return len(A & B) / max(1, len(B))
    if kind == 'ship_drawing_pair':
        # real drawing tile -> members: a reference member is found when an output member has both ends within 60 mm
        # (either direction); score = F1 of found members
        a, b = _js(out), _js(ref)
        if not a or not isinstance(a.get('members'), list):
            return 0.0
        O = [m for m in a['members'] if isinstance(m, dict) and len(m.get('a', [])) == 2 and len(m.get('b', [])) == 2]
        Rm = b['members']
        near = lambda m, o: (max(abs(m['a'][0]-o['a'][0]), abs(m['a'][1]-o['a'][1]), abs(m['b'][0]-o['b'][0]), abs(m['b'][1]-o['b'][1])) <= 60 or
                             max(abs(m['a'][0]-o['b'][0]), abs(m['a'][1]-o['b'][1]), abs(m['b'][0]-o['a'][0]), abs(m['b'][1]-o['a'][1])) <= 60)
        tp = sum(1 for m in Rm if any(near(m, o) for o in O))
        if not tp:
            return 0.0
        p_, r_ = tp / max(1, len(O)), tp / len(Rm)
        return 2 * p_ * r_ / (p_ + r_)
    if kind == 'ship_rule_find':
        rid = ref.split(' ', 1)[0]
        return float(rid in out)
    if kind == 'ship_rule_lookup':
        w = _words(ref.split(':', 1)[-1])
        return min(1.0, len(w & _words(out)) / max(1, 0.5 * len(w)))
    if kind in ('ship_label', 'ship_method'):
        ids = set(RID.findall(ref))
        return float(bool(ids & set(RID.findall(out)))) if ids else float(len(_words(ref) & _words(out)) >= 0.4 * len(_words(ref)))
    return 0.0


def load(data_dir, per_kind=20, seed=0):
    rows = collections.defaultdict(list)
    for l in open(f'{data_dir}/dataset.jsonl'):
        d = json.loads(l)
        if d['part'].startswith('ship_'):
            rows[d['part']].append(d)
    r = random.Random(seed)
    out = []
    for k, v in sorted(rows.items()):
        r.shuffle(v)
        out += v[:per_kind]
    return out


def evaluate(ask, data_dir, per_kind=20, verbose=False, train_dir=None):
    """ask(image_path_or_None, prompt) -> text. Returns {kind: mean score} and prints a table.
    train_dir: also report the score on test cases that are NOT in the training data (generalisation, column 'new')."""
    seen = set()
    if train_dir:
        seen = {json.dumps(json.loads(l)['messages']) for l in open(f'{train_dir}/dataset.jsonl')}
    res = collections.defaultdict(list); new = collections.defaultdict(list)
    for d in load(data_dir, per_kind):
        prompt = d['messages'][0]['content'][-1]['text']
        ref = d['messages'][1]['content'][0]['text']
        img = f"{data_dir}/{d['image']}" if d.get('image') else None
        out = ask(img, prompt)
        s = score(d['part'], out, ref)
        res[d['part']].append(s)
        if train_dir and json.dumps(d['messages']) not in seen:
            new[d['part']].append(s)
        if verbose and s < 1:
            print(f"--- {d['part']} {s:.2f}\nOUT: {out[:300]}\nREF: {ref[:300]}")
    tab = {k: round(sum(v) / len(v), 3) for k, v in sorted(res.items())}
    allv = [x for v in res.values() for x in v]
    tab['ALL'] = round(sum(allv) / max(1, len(allv)), 3)
    if train_dir:
        nv = [x for v in new.values() for x in v]
        tab['_new'] = {k: round(sum(v) / len(v), 3) for k, v in sorted(new.items())}
        tab['_new']['ALL'] = round(sum(nv) / max(1, len(nv)), 3)
    for k, v in tab.items():
        if k != '_new':
            nn = tab.get('_new', {}).get(k)
            print(f'{k:22s} {v:6.1%}' + (f'   new cases {nn:6.1%} (n={len(new[k]) if k != "ALL" else sum(len(x) for x in new.values())})' if nn is not None else ''))
    return tab


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--data', default='ship_data')
    a = ap.parse_args()
    if a.selftest:
        refs = {}
        for d in load(a.data, 50):
            img = f"{a.data}/{d['image']}" if d.get('image') else None
            refs[(img, d['messages'][0]['content'][-1]['text'])] = d['messages'][1]['content'][0]['text']
        print('reference answers scored against themselves (must be 100 %):')
        t = evaluate(lambda img, p: refs[(img, p)], a.data, 50)
        assert t['ALL'] == 1.0, t
        print('empty answers (must be low):')
        t0 = evaluate(lambda img, p: '', a.data, 50)
        assert t0['ALL'] < 0.2, t0
        print('selftest OK')
