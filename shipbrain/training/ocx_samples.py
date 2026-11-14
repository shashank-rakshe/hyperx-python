"""
Real OCX ship models -> training samples (names removed first).

Public OCX exports (real CAD exports of ship structures, schema 2.8.5 / 2.8.6 / 3.0.0) are fetched at training time,
never stored in the repo:
    OCXStandard/ocx-reader  tests/data/*.3docx   (MIT)
    skfcz/OCXReader         ocxreader/data/*.3docx
plus any folders given with --src (your own OCX files; add --rules with your private name list).

Before a file is used, every name that is not structure data is replaced: file name, header (author, company, CAD
system, version), vessel name, yard / designer / owner, class identification number and the class society attribute;
the same strings are then removed anywhere else in the file. A sample that still contains one of them is dropped.

Samples (all answers are the real tool results): what is in the model, panels / plates / stiffeners by name, kind,
function or thickness, validation against the official XSD, upgrade to OCX 3.2.0, revision compare (thickness,
section, removed plate), file info.

    python training/ocx_samples.py --out data/ocx_train.jsonl --eval-out data/ocx_eval.jsonl
"""
import argparse, glob, json, os, random, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent   # noqa: E402

SOURCES = [('https://github.com/OCXStandard/ocx-reader.git', 'tests/data'),
           ('https://github.com/skfcz/OCXReader.git', 'ocxreader/data')]


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def res(name, out):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(out)}


def fetch(dst):
    """sparse clone of the sample folders -> list of .3docx paths"""
    files = []
    for url, sub in SOURCES:
        d = os.path.join(dst, re.sub(r'\W', '_', url.split('/')[-1]))
        try:
            subprocess.run(['git', 'clone', '-q', '--depth', '1', '--filter=blob:none', '--sparse', url, d], check=True, timeout=600)
            subprocess.run(['git', '-C', d, 'sparse-checkout', 'set', sub], check=True, timeout=1200)
        except Exception as e:
            print('could not fetch', url, e)
            continue
        files += sorted(glob.glob(os.path.join(d, sub, '*.3docx')))
    return files


# ---------------------------------------------------------------------- names out
_ATTRS = {'Header': ('name', 'author', 'organization', 'originating_system', 'application_version'),
          'Vessel': ('name',), 'BuilderInformation': ('yard', 'designer', 'owner'), 'ClassificationData': ('identification',)}
_REPL = {'name': '{m}', 'author': '', 'organization': '', 'originating_system': 'CAD system', 'application_version': '',
         'yard': '', 'designer': '', 'owner': '', 'identification': ''}


def anonymise(src, dst, label, rules=()):
    """-> (dst, hidden strings). Writes a copy with every non-structure name replaced."""
    s = open(src, encoding='utf-8', errors='replace').read()
    hidden = set()

    def fix_tag(m):
        tag, body = m.group(1), m.group(2)
        for a in _ATTRS[tag]:
            mm = re.search(r'(\s(?:\w+:)?' + a + r')="([^"]*)"', body)
            if mm:
                if mm.group(2).strip():
                    hidden.add(mm.group(2).strip())
                body = body.replace(mm.group(0), f'{mm.group(1)}="{_REPL[a].format(m=label)}"')
        if tag == 'ClassificationData':                     # class society (a company) left out
            body = re.sub(r'\s(?:\w+:)?newbuildingSociety="[^"]*"', '', body)
        return f'<{m.group(0)[1:m.group(0).index(tag)]}{tag}{body}'
    s = re.sub(r'<(?:\w+:)?(Header|Vessel|BuilderInformation|ClassificationData)(\s[^>]*)', fix_tag, s, count=0)
    more = set()
    for h in hidden:                                         # vessel / model name without its revision, brand words
        more.add(re.sub(r'/[A-Z]$', '', h))
        more |= {w for w in re.split(r'[\s/_]+', h) if len(w) >= 4 and w.isupper() and w not in ('OCX', 'STEEL', 'EXPORT')}
    hidden |= {x for x in more if len(x) >= 3}
    hidden |= {re.sub(r'[-_ ]?(OCX|V?2\d\d|MID|rev\d+).*$', '', os.path.splitext(os.path.basename(src))[0], flags=re.I)}
    hidden = {h for h in hidden if len(h) >= 3 and h.lower() not in ('ocx export', 'cad system', 'ocx', 'steel', 'test', 'shipbrain')}
    for h in sorted(hidden, key=len, reverse=True):
        s = re.sub(r'(?<![\w-])' + re.escape(h) + r'(?![\w-])', label, s, flags=re.I)
    for rx, rep in rules:
        s = rx.sub(rep, s)
    open(dst, 'w', encoding='utf-8').write(s)
    return dst, hidden


def leaks(text, hidden, rules=()):
    low = text.lower()
    return [h for h in hidden if len(h) >= 3 and re.search(r'(?<![\w-])' + re.escape(h.lower()) + r'(?![\w-])', low)] + \
        [rx.pattern for rx, _ in rules if rx.search(text)]


# ---------------------------------------------------------------------- samples
def samples_for(T, fname, r, per_model, big):
    from shipbrain import ocx
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    rows = []

    def add(task, ask, tool, args, answer=None):
        out = T.call(tool, args)
        if not isinstance(out, dict) or 'error' in out:
            return None
        rows.append({'task': task, 'messages': [sysmsg, {'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tb(tool, args)},
                                                res(tool, out), {'role': 'assistant', 'content': answer(out) if answer else out['plain_english']}]})
        return out

    rd = ocx.read_cached(T._path(fname))
    panels = rd['model']['blocks'][0]['panels']
    funcs = sorted({str(p.get('function') or '').split(':')[0].strip() for p in panels if p.get('function')} - {''})
    thks = sorted({pl['thk'] for p in panels for pl in p['plates'] if pl.get('thk')})
    secs = sorted({st['sec'] for p in panels for st in p['stiffeners'] if st.get('sec')})
    pnames = [p.get('name') for p in panels if p.get('name')]
    makers = [
        lambda: add('ocx_read', r.choice([f'What is in {fname}?', f'Read the OCX model {fname}', f'Summarise {fname}: plates, thicknesses, sections',
                                          f'How much plate steel is in {fname}?', f'Open {fname} and tell me what structure it has']),
                    'ocx_read', {'file': fname}),
        lambda: add('ocx_query', r.choice([f'List the panels in {fname}', f'Which panels does {fname} have?']), 'ocx_query', {'file': fname}),
        lambda: funcs and add('ocx_query', r.choice(['Show the {f} panels of {n}', 'What {f} structure is in {n}?', 'List {f} members in {n}']).format(
            f=(fc := r.choice(funcs)).lower(), n=fname), 'ocx_query', {'file': fname, 'function': fc}),
        lambda: thks and add('ocx_query', r.choice(['Which plates in {n} are {t:g} mm?', 'Find all {t:g} mm plates in {n}']).format(
            t=(t := r.choice(thks)), n=fname), 'ocx_query', {'file': fname, 'kind': 'plate', 'min_thk': t, 'max_thk': t}),
        lambda: thks and add('ocx_query', f'Plates thicker than {(t := r.choice(thks)) - 0.5:g} mm in {fname}?', 'ocx_query',
                             {'file': fname, 'kind': 'plate', 'min_thk': t}),
        lambda: secs and add('ocx_query', r.choice(['Where is {s} used in {n}?', 'Which stiffeners in {n} are {s}?']).format(
            s=(sc := r.choice(secs)), n=fname), 'ocx_query', {'file': fname, 'kind': 'stiffener', 'name': sc}),
        lambda: pnames and add('ocx_query', r.choice(['Tell me about panel {p} in {n}', 'What plates and stiffeners does {p} have ({n})?']).format(
            p=(pn := r.choice(pnames)), n=fname), 'ocx_query', {'file': fname, 'name': pn}),
        lambda: validate_sample(T, fname, r, sysmsg, rows),
        lambda: add('file_info', f'What kind of file is {fname}?', 'file_info', {'file': fname}),
    ]
    if not big:
        makers.append(lambda: add('ocx_upgrade', r.choice([f'Upgrade {fname} to OCX 3.2.0', f'Convert {fname} to the newest OCX version',
                                                           f'Write {fname} again as OCX 3.2.0 and check it']),
                                  'ocx_write', {'file': fname, 'out': fname.replace('.3docx', '_v320.3docx')}))
        makers.append(lambda: revision(T, fname, r, add))
    for mk in makers:                                        # every kind once, then random extra ones
        try:
            mk()
        except Exception as e:
            print('  sample failed:', type(e).__name__, str(e)[:120])
    for _ in range(max(0, per_model - len(makers))):
        try:
            r.choice(makers[2:7])()
        except Exception:
            pass
    return rows


def validate_sample(T, fname, r, sysmsg, rows):
    """validation of the real file; the class society attribute was taken out with the names, so its 'missing' error
    is not part of the sample (the original file has it)"""
    from shipbrain import ocx
    out = T.call('ocx_validate', {'file': fname})
    if 'error' in out:
        return None
    errs = [e for e in out['errors'] if 'newbuildingSociety' not in e]
    if len(errs) != len(out['errors']):
        out = ocx._verdict(fname, out['schema_version'], out['elements'], errs, out['xsd_checked'], out['checks'], out['version'])
    ask = r.choice([f'Is {fname} valid OCX?', f'Check {fname} against the OCX schema', f'Validate {fname}'])
    rows.append({'task': 'ocx_validate', 'messages': [sysmsg, {'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tb('ocx_validate', {'file': fname})},
                                                      res('ocx_validate', out), {'role': 'assistant', 'content': out['plain_english']}]})
    return out


def revision(T, fname, r, add):
    """revision B of a real model: thicker / thinner plates, another section, one plate removed -> compare"""
    out = T.call('ocx_read', {'file': fname})
    if 'error' in out:
        return None
    js = T._path(out['structure_json'])
    m = json.load(open(js))
    plates = [(p, pl) for p in m['blocks'][0]['panels'] for pl in p['plates'] if pl.get('thk')]
    stiffs = [(p, st) for p in m['blocks'][0]['panels'] for st in p['stiffeners']]
    if len(plates) < 4:
        return None
    for _, pl in r.sample(plates, min(len(plates) - 1, r.randint(1, 3))):
        pl['thk'] = pl['thk'] + r.choice([-2, -1, 1, 2, 3])
    if stiffs and len(m['sections']) > 1:
        _, st = r.choice(stiffs)
        st['sec'] = r.choice([k for k in m['sections'] if k != st['sec']])
    p, pl = r.choice(plates)
    p['plates'].remove(pl)
    rev = fname.replace('.3docx', '_revB.json')
    json.dump(m, open(T._path(rev), 'w'))
    return add('ocx_revision', r.choice([f'What changed from {fname} to {rev}?', f'Compare {fname} with revision {rev} member by member']),
               'compare_structures', {'a': fname, 'b': rev, 'method': 'members'})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='data/ocx_train.jsonl')
    ap.add_argument('--eval-out', default='data/ocx_eval.jsonl')
    ap.add_argument('--src', action='append', default=[], help='folder with your own .3docx files')
    ap.add_argument('--rules', help='private name rules (scrub.py format), kept outside the repo')
    ap.add_argument('--per-model', type=int, default=16)
    ap.add_argument('--big-mb', type=float, default=12, help='larger files: read / query / validate only')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    rules = []
    if a.rules:
        from scrub import load_rules
        rules = load_rules(a.rules)
    tmp = tempfile.mkdtemp(prefix='sb_ocx_')
    files = fetch(os.path.join(tmp, 'src')) + [f for d in a.src for f in sorted(glob.glob(os.path.join(d, '**', '*.3docx'), recursive=True))]
    print(len(files), 'OCX models')
    work = os.path.join(tmp, 'work')
    os.makedirs(work)
    T = agent.Tools(work)
    rows, dropped = [], 0
    for k, f in enumerate(files, 1):
        label = f'model_{k}'
        fname = label + '.3docx'
        _, hidden = anonymise(f, os.path.join(work, fname), label, rules)
        left = leaks(open(os.path.join(work, fname), encoding='utf-8', errors='replace').read(), hidden, rules)
        if left:
            print(f'  {fname}: names still present ({len(left)}), skipped')
            continue
        big = os.path.getsize(f) > a.big_mb * 1e6
        got = samples_for(T, fname, r, a.per_model, big)
        for x in got:
            if leaks(json.dumps(x), hidden, rules):
                dropped += 1
                continue
            rows.append(x)
        print(f'  {fname}: {len(got)} samples ({os.path.getsize(f) / 1e6:.1f} MB)')
    r.shuffle(rows)
    n_eval = max(1, len(rows) // 12) if rows else 0
    for path, part in ((a.eval_out, rows[:n_eval]), (a.out, rows[n_eval:])):
        os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
        with open(path, 'w', encoding='utf-8') as fh:
            for x in part:
                fh.write(json.dumps(x) + '\n')
    shutil.rmtree(tmp, ignore_errors=True)
    print(f'{a.out}: {len(rows) - n_eval} samples, {a.eval_out}: {n_eval}; {dropped} dropped for a name')


if __name__ == '__main__':
    main()
