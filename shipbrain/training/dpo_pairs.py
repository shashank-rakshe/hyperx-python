"""
Preference pairs for DPO (Direct Preference Optimisation, Rafailov et al. 2023; trained with Hugging Face TRL inside
training/finetune.py after the normal fine-tune). Each pair = the same conversation so far + a CHOSEN and a REJECTED
next assistant turn:

  feedback   the app's feedback.jsonl (thumbs down WITH a written correction): rejected = the model's answer,
             chosen = the user's correction. PRIVATE - attach it as a private Kaggle dataset, never commit it.
  invented   from the training conversations: at the question, chosen = the real tool call, rejected = a made-up answer
             with numbers that look right (teaches: compute with the tool, never answer engineering numbers from memory)
  unfaithful from the training conversations: after the tool result, chosen = the real answer, rejected = the same
             answer with some numbers changed (teaches: report the tool's numbers exactly)
  overclaim  chosen = the real answer with its caveat ("check ...", "static ...", "not converted ..."), rejected = the
             same answer with the caveat cut off (teaches: keep the limits of a result)

    python training/dpo_pairs.py --data data/*.jsonl --feedback feedback.jsonl --out data/dpo_pairs.jsonl --max 2000
"""
import argparse, glob, gzip, json, os, random, re

NUM = re.compile(r'(?<![\w.])(\d{1,3}(?:,\d{3})+|\d+\.\d+|\d{2,})(?![\w.])')
CAVEAT = re.compile(r'\s*(\([^()]*(check|static|not |only|assum|non-commercial|approx|guess)[^()]*\)\.?|'
                    r'(Check|Note|The design|Run the dynamics|Say )[^.]*\.)\s*$', re.I)


def _open(p):
    return gzip.open(p, 'rt', encoding='utf-8') if p.endswith('.gz') else open(p, encoding='utf-8')


def _perturb(text, r):
    """change some numbers so the text still looks right but is wrong"""
    nums = list(NUM.finditer(text))
    if not nums:
        return None
    pick = set(r.sample(range(len(nums)), max(1, len(nums) // 3)))
    out, last = [], 0
    for k, m in enumerate(nums):
        out.append(text[last:m.start()])
        s = m.group(0)
        if k in pick:
            v = float(s.replace(',', ''))
            nv = v * r.choice([0.55, 0.7, 1.35, 1.6, 2.0])
            dec = len(s.split('.')[1]) if '.' in s else 0
            ns = f'{nv:,.{dec}f}' if ',' in s else f'{nv:.{dec}f}'
            s = ns if ns != s else str(int(v) + 1)
        out.append(s)
        last = m.end()
    out.append(text[last:])
    t = ''.join(out)
    return t if t != text else None


def from_conversation(msgs, r):
    """pairs from one training conversation (list of messages)"""
    pairs = []
    roles = [m['role'] for m in msgs]
    if 'assistant' not in roles:
        return pairs
    last = len(msgs) - 1
    if msgs[last]['role'] != 'assistant' or not isinstance(msgs[last]['content'], str):
        return pairs
    final = msgs[last]['content']
    has_tool = any(m['role'] == 'assistant' and isinstance(m['content'], str) and m['content'].startswith('```tool') for m in msgs)
    bad = _perturb(final, r)
    if bad and has_tool:
        pairs.append({'kind': 'unfaithful', 'prompt': msgs[:last], 'chosen': final, 'rejected': bad})
    if has_tool:
        i = next(k for k, m in enumerate(msgs) if m['role'] == 'assistant')
        if isinstance(msgs[i]['content'], str) and msgs[i]['content'].startswith('```tool') and bad:
            pairs.append({'kind': 'invented', 'prompt': msgs[:i], 'chosen': msgs[i]['content'], 'rejected': bad})
    m = CAVEAT.search(final)
    if m and len(final) - (m.end() - m.start()) > 40:
        pairs.append({'kind': 'overclaim', 'prompt': msgs[:last], 'chosen': final, 'rejected': final[:m.start()].rstrip()})
    return pairs


def from_feedback(rec, sysmsg=None):
    """a thumbs-down with a written correction -> one pair"""
    msgs = rec.get('messages') or []
    if rec.get('good') or not str(rec.get('comment', '')).strip() or not msgs or msgs[-1]['role'] != 'assistant':
        return None
    prompt = ([sysmsg] if sysmsg else []) + msgs[:-1]
    return {'kind': 'feedback', 'prompt': prompt, 'chosen': rec['comment'].strip(), 'rejected': msgs[-1]['content']}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', nargs='*', default=[])
    ap.add_argument('--feedback', nargs='*', default=[])
    ap.add_argument('--out', default='data/dpo_pairs.jsonl')
    ap.add_argument('--max', type=int, default=2000, help='synthetic pairs at most (feedback pairs are all kept, x3)')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    synth, fb, sysmsg = [], [], None
    for pat in a.data:
        for p in sorted(glob.glob(pat)):
            base = os.path.basename(p).lower()
            if not os.path.getsize(p) or 'eval' in base or 'dpo' in base or 'feedback' in base:
                continue                                         # never the test questions, the pairs themselves, feedback
            for line in _open(p):
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get('images') or 'good' in d:               # pictures: text-only DPO; feedback records: below
                    continue
                msgs = d.get('messages') or []
                if msgs and msgs[0]['role'] == 'system' and sysmsg is None:
                    sysmsg = msgs[0]
                synth += from_conversation(msgs, r)
    for pat in a.feedback:
        for p in sorted(glob.glob(pat)):
            for line in _open(p):
                try:
                    x = from_feedback(json.loads(line), sysmsg)
                except (ValueError, KeyError, TypeError):
                    continue
                if x:
                    fb.append(x)
    seen, uniq = set(), []
    for x in synth:                                             # the same conversation may sit in data/ and training/data/
        key = (json.dumps(x['prompt'], sort_keys=True)[-400:], x['chosen'][:200], x['kind'])
        if key not in seen:
            seen.add(key)
            uniq.append(x)
    synth = uniq
    r.shuffle(synth)
    kinds = {}
    keep = []
    per = max(1, a.max // 3)                                        # balance the three synthetic kinds
    for x in synth:
        if kinds.get(x['kind'], 0) < per:
            kinds[x['kind']] = kinds.get(x['kind'], 0) + 1
            keep.append(x)
    rows = keep + fb * 3
    r.shuffle(rows)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as f:
        for x in rows:
            f.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'pairs:', dict(kinds, feedback=len(fb)))


if __name__ == '__main__':
    main()
