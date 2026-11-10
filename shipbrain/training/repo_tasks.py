"""
Verified training / eval samples from shared git repos (same chat JSONL format as make_dataset.py).

  python training/repo_tasks.py --packs packs/ --out data/repo_train.jsonl --eval-out data/repo_eval.jsonl

Two task families, every tool result produced by really calling the tool:
  repo_cad        a ported, verified CAD example (examples/cadquery/*.py with a "# Source:" line, e.g. solidcraft oracle
                  parts and text-to-cad prompts) -> cadquery_build(code, expect) -> PASS -> short plain-English answer.
                  expect holds the user's sizes (and the analytic volume when the source repo gives one).
  repo_knowledge  a question about a repo concept -> knowledge_search -> answer quoting the chunk and citing its id.
                  Only from packs with allowed_for_training = true, and only when the search really finds the chunk.
Eval samples come from held-out examples / chunks (split by a hash of the name), so eval is not a copy of train.
"""
import argparse, hashlib, json, os, random, re, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from shipbrain import agent, repopack   # noqa: E402
from shipbrain.examples import Examples   # noqa: E402
from shipbrain.knowledge import Knowledge   # noqa: E402


def tool_block(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}, separators=(', ', ': ')) + '\n```'


def result_msg(name, res):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + json.dumps(res, default=str)[:6000]}


def is_eval(key, frac):
    return int(hashlib.sha1(key.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF < frac


# ------------------------------------------------------------------ CAD examples ported from repos
HEADER = re.compile(r'^#\s*(Prompt|Tags|Source|Expect):.*\n', re.M)


def repo_examples(examples):
    """verified examples that came from a shared repo: [(example, source line, expect)]"""
    out = []
    for e in examples.items:
        src = re.search(r'^#\s*Source:\s*(.+)$', e['code'], re.M)
        if not src:
            continue
        m = re.search(r'^#\s*Expect:\s*(\{.*\})\s*$', e['code'], re.M)
        exp = json.loads(m.group(1)) if m else {'bbox': e['metrics']['bbox']}
        exp = {k: exp[k] for k in ('bbox', 'volume', 'n_solids') if k in exp}       # default tolerance (1 %)
        out.append((e, src.group(1).strip(), exp))
    return out


CAD_ASK = ['Make a 3D model of a {p}', 'CAD model: {p}', 'Create a STEP file of a {p}', 'Model a {p}',
           'Build this part in CadQuery: {p}', '{P}. I need STEP and STL.']


def cad_samples(tools, examples, r, variants=2, frac=0.2):
    """-> (train, eval) lists of (task, messages)"""
    train, ev, cache = [], [], {}
    for e, source, expect in repo_examples(examples):
        code = HEADER.sub('', e['code']).strip() + '\n'
        args = {'name': e['name'], 'code': code, 'expect': expect}
        key = e['name']
        if key not in cache:
            cache[key] = tools.call('cadquery_build', json.loads(json.dumps(args)))
        res = cache[key]
        if not res.get('ok') or not res.get('pass'):
            continue                                            # only parts that build AND match the expected values
        repo = re.sub(r'^https?://github\.com/', '', source.split()[0])
        asks = r.sample(CAD_ASK, k=min(variants, len(CAD_ASK)))
        for ask in asks:
            p = e['prompt'].rstrip('.')
            user = ask.format(p=p[0].lower() + p[1:], P=p[0].upper() + p[1:])
            vol = f", volume {res['volume']:g} mm3" if res.get('volume') is not None else ''
            ans = (f"Built and checked: {res['n_solids']} solid{'s' if res['n_solids'] != 1 else ''}, bounding box "
                   f"{' x '.join(f'{v:g}' for v in res['bbox'])} mm{vol}.\n"
                   f"Checks: {'; '.join(res['checks'])}.\n"
                   f"Files: {', '.join(res['files'])}.\n"
                   f"(The part follows the verified example {e['name']}, ported from {repo}.)")
            msgs = [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('cadquery_build', args)},
                    result_msg('cadquery_build', res), {'role': 'assistant', 'content': ans}]
            (ev if is_eval(key, frac) else train).append(('repo_cad', msgs))
    return train, ev


# ------------------------------------------------------------------ knowledge questions from packs
DOC_ASK = ['What does {repo} say about {t}?', 'In {repo}, how does {t} work?', 'Explain {t} ({repo}).',
           '{repo}: what is {t}?', 'Tell me about {t} in {repo}.']
CODE_ASK = ['In {repo}, what does {t} do?', 'Where is {t} in {repo} and what is it for?', 'Explain {t} from {repo}.']


def _plain(text, n=420):
    """chunk text -> short plain sentences for the answer (headings, code, links and markup removed)"""
    t = re.sub(r'```.*?```', ' ', text, flags=re.S)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = re.sub(r'!\[[^\]]*\]\([^)]*\)', ' ', t)
    t = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', t)
    t = re.sub(r'^\s*#{1,6}\s.*$', ' ', t, flags=re.M)
    t = re.sub(r'^\s*\|.*\|\s*$', ' ', t, flags=re.M)              # tables
    t = re.sub(r'[*_`>]+', '', t)
    t = re.sub(r'\s+', ' ', t).strip()
    if len(t) <= n:
        return t
    cut = t.rfind('. ', 0, n)
    return t[:cut + 1] if cut > n // 3 else t[:n].rsplit(' ', 1)[0] + ' ...'


def _docstring(code):
    m = re.search(r'(?:def|class)\s+\w+[^\n]*:\s*\n\s*(?:\'\'\'|""")(.+?)(?:\'\'\'|""")', code, re.S)
    if m:
        return re.sub(r'\s+', ' ', m.group(1)).strip()
    m = re.search(r'((?:^\s*///?.*\n)+)\s*(?:pub|fn|struct|impl|enum|export|function|class)', code, re.M)
    if m:
        return re.sub(r'\s+', ' ', re.sub(r'^\s*///?\s?', '', m.group(1), flags=re.M)).strip()
    return ''


def _topic(chunk):
    title = chunk['title'].split(' > ')[-1].strip()
    title = re.sub(r'^(\d+(\.\d+)*\.?|[A-Z]\.|Step \d+:)\s+', '', title)  # "3.2 Foo", "C. Foo" -> "Foo"
    title = re.sub(r'\s*\([^)]*\)\s*$', '', title)                    # "Foo (2026-10-13)" -> "Foo"
    return title.strip(' :-')


def knowledge_candidates(pack):
    """chunks worth a question: doc sections with a real heading and enough prose; code with a docstring"""
    out = []
    for c in pack['chunks']:
        src = c['source'].lower()
        topic = _topic(c)
        if src.endswith(repopack.DOC_EXT):
            words = len(re.findall(r'[A-Za-z]{3,}', _plain(c['text'], 2000)))
            first = c['text'].lstrip().startswith('#')               # the start of a section, not a fragment of one
            if first and words >= 25 and 3 <= len(topic) <= 70 and not re.search(r'licen[cs]e|install|contribut|table of contents|changelog|security|revision', topic, re.I):
                out.append(('doc', topic, c))
        elif src.endswith(repopack.CODE_EXT) and re.match(r'(def|class|fn|struct|function|impl|trait|enum) ', c['title']):
            doc = _docstring(c['text'])
            if len(doc) >= 30:
                out.append(('code', c['title'].split(', ')[0].split(' ', 1)[1].split('::')[0].strip(), c, doc))
    return out


def knowledge_samples(tools, packs, r, per_pack=40, frac=0.15):
    """packs: list of loaded pack dicts (allowed_for_training only). -> (train, eval)"""
    train, ev = [], []
    for pack in packs:
        if not pack.get('allowed_for_training'):
            continue
        name = pack['name']
        cands = knowledge_candidates(pack)
        r.shuffle(cands)
        n_ok = 0
        for cand in cands:
            if n_ok >= per_pack:
                break
            kind, topic, c = cand[:3]
            ask = r.choice(DOC_ASK if kind == 'doc' else CODE_ASK)
            if kind == 'doc' and topic.endswith('?'):
                user = f'{topic} ({name})'                         # the heading already is a question
            else:
                user = ask.format(repo=name, t=topic if kind == 'doc' else f'`{topic}`')
            args = {'query': user, 'k': 4}
            if r.random() < 0.5:
                args['scope'] = name                              # the question names the repo: search only that pack
            res = tools.call('knowledge_search', args)
            ids = [h['id'] for h in res.get('results', [])]
            if c['id'] not in ids:
                continue                                          # only train what retrieval actually finds
            hit = next(h for h in res['results'] if h['id'] == c['id'])
            if kind == 'doc':
                body = _plain(hit['text'])
                ans = f"From {name} ({hit['source'].removeprefix('repo:')}): {body} [{c['id']}]"
            else:
                ans = (f"`{topic}` is in {hit['source'].removeprefix('repo:')} [{c['id']}]. "
                       f"{_plain(cand[3], 360)}")
            others = [i for i in ids if i != c['id']][:2]
            if others:
                ans += f"\nRelated: {', '.join(others)}."
            ans += f"\n(Source: {pack['repo']}, {pack['license']}.)"
            msgs = [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('knowledge_search', args)},
                    result_msg('knowledge_search', res), {'role': 'assistant', 'content': ans}]
            (ev if is_eval(c['id'], frac) else train).append(('repo_knowledge', msgs))
            n_ok += 1
    return train, ev


# ------------------------------------------------------------------ main
def load_training_packs(folder):
    packs = []
    for fn in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if fn.endswith('.sbpack'):
            p = repopack.read_pack(os.path.join(folder, fn))
            if p.get('allowed_for_training'):
                packs.append(p)
            else:
                print(f'skipped {fn}: {p.get("usage", "not allowed for training")}')
    return packs


def make(packs_dir, workdir, seed=0, per_pack=40, cad=True, cad_variants=2, examples=None):
    """-> (train, eval): lists of {'task', 'messages'}; the tools see only training-allowed packs"""
    r = random.Random(seed)
    kb = Knowledge()
    packs = load_training_packs(packs_dir)
    for p in packs:
        for c in p['chunks']:
            kb.add(f"repo:{p['name']}/{c['source']}", c['text'], c.get('title', ''), id=c['id'])
    ex = examples if examples is not None else Examples()
    tools = agent.Tools(workdir, kb, allow_code=True, examples=ex)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(tools)}
    tr, ev = knowledge_samples(tools, packs, r, per_pack)
    if cad:
        try:
            import cadquery  # noqa: F401
            ctr, cev = cad_samples(tools, ex, r, cad_variants)
            tr, ev = tr + ctr, ev + cev
        except ImportError:
            print('CadQuery is not installed: CAD samples skipped')
    out = []
    for part in (tr, ev):
        rows = []
        for task, msgs in part:
            ctx, _ = agent.retrieve(tools, msgs[0]['content'])          # same RAG context as at run time
            head = [sysmsg] + ([{'role': 'system', 'content': ctx}] if ctx else [])
            rows.append({'task': task, 'messages': head + msgs})
        r.shuffle(rows)
        out.append(rows)
    return out[0], out[1]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--packs', default='packs')
    ap.add_argument('--out', default='data/repo_train.jsonl')
    ap.add_argument('--eval-out', default='data/repo_eval.jsonl')
    ap.add_argument('--per-pack', type=int, default=40, help='knowledge questions per pack (train + eval)')
    ap.add_argument('--cad-variants', type=int, default=2, help='phrasings per verified CAD example')
    ap.add_argument('--no-cad', action='store_true')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    work = tempfile.mkdtemp(prefix='sb_repo_')
    train, ev = make(a.packs, work, a.seed, a.per_pack, not a.no_cad, a.cad_variants)
    for path, rows in ((a.out, train), (a.eval_out, ev)):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            for row in rows:
                f.write(json.dumps(row) + '\n')
        counts = {}
        for row in rows:
            counts[row['task']] = counts.get(row['task'], 0) + 1
        print(path, len(rows), 'samples', counts)
    for fn in os.listdir(work):
        p = os.path.join(work, fn)
        if os.path.isfile(p):
            os.remove(p)


if __name__ == '__main__':
    main()
