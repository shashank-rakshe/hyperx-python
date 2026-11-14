"""
Public P&ID drawing sets -> training samples for the P&ID tools (run where the internet is open, e.g. on Kaggle).

The list comes from the copied public-chemical-manufacturing-datasets repo (P&IDs of real permitted water-treatment
facilities, public records). The PDFs are downloaded to a cache, prepared with pid-to-kg's own scripts (probe, render,
hints) through ShipBrain's pid_kg tool, and the REAL tool outputs become chat samples: how to start a P&ID job, what the
pages are, which tags each sheet carries. The drawings themselves are never written into the repo or a pack: only the
model learns from them.

    python training/public_pids.py --out data/public_pid_train.jsonl [--cache ~/.cache/shipbrain/pids] [--max-pages 4]
    python training/public_pids.py --local some.pdf --pages 1-2 --name "Test plant" --out x.jsonl   (offline check)
"""
import argparse, json, os, random, re, sys, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, polyglot   # noqa: E402


def datasets():
    """(name, facility, url, pages, format) from the copied datasets README"""
    readme = os.path.join(polyglot.repo_dir('public-chemical-manufacturing-datasets'), 'README.md')
    out, on = [], False
    for line in open(readme, encoding='utf-8'):
        if line.startswith('## '):
            on = line.strip().lower() == '## p&ids'
        m = re.match(r'\|\s*\[([^\]]+)\]\((https?://[^)]+)\)\s*\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|', line) if on else None
        if m:
            out.append({'name': m.group(1).strip(), 'url': m.group(2), 'facility': m.group(3).strip(),
                        'pages': re.sub(r'\s', '', m.group(4)).replace('–', '-'), 'format': m.group(5).strip()})
    return out


def fetch(url, cache):
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, re.sub(r'[^A-Za-z0-9_.-]', '_', url.rsplit('/', 1)[-1])[:80] or 'drawing.pdf')
    if not os.path.exists(path):
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (compatible; research download)'})
        with urllib.request.urlopen(req, timeout=180) as r, open(path + '.part', 'wb') as f:
            f.write(r.read())
        os.replace(path + '.part', path)
    return path


def _first_pages(spec, n):
    """'47-60' -> '47-50' (the first n pages); '114,117,119' -> '114,117' """
    pages = []
    for part in spec.split(','):
        if '-' in part:
            a, b = (int(x) for x in part.split('-')[:2])
            pages += list(range(a, b + 1))
        elif part.strip().isdigit():
            pages.append(int(part))
    pages = pages[:n]
    return ','.join(str(p) for p in pages)


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def samples_for(T, pdf_name, title, pages, sysmsg, r):
    """run the real P&ID preparation, turn each step into samples"""
    plant = re.sub(r'\s+', ' ', title)
    out, msgs = [], []
    steps = []
    for action in ('probe', 'render', 'hints', 'tags', 'status'):
        a = {'action': action, 'pdf': pdf_name, 'plant_name': plant}
        if action == 'probe':
            a['pages'] = pages
        res = T.call('pid_kg', a)
        if 'error' in res:
            print(f'  {plant}: {action} failed: {res["error"][:200]}')
            return out
        steps.append((a, res))
    ask = r.choice([f'Turn the P&IDs in {pdf_name} (pages {pages}) into a knowledge graph',
                    f'{plant}: digitise the P&ID pages {pages} of {pdf_name}',
                    f'Prepare {pdf_name} for P&ID extraction, the drawings are on pages {pages}'])
    convo = [{'role': 'user', 'content': ask}]
    for a, res in steps[:3]:
        convo += [{'role': 'assistant', 'content': tb('pid_kg', a)}, {'role': 'user', 'content': 'TOOL_RESULT pid_kg: ' + agent.compact_result(res)}]
    st = steps[4][1]['output']
    convo.append({'role': 'assistant', 'content': f'Pages {pages} of {pdf_name} are prepared: page types found, sheets rendered into '
                                                   f'tiles and text / OCR tag hints collected. {st}'})
    out.append({'task': 'public_pid_prepare', 'messages': [sysmsg] + convo})
    tags = steps[3]
    for line in tags[1]['output'].splitlines():
        m = re.match(r'page (\d+)', line)
        if not m:
            continue
        q = r.choice([f'Which tags are on page {m.group(1)} of the {plant} P&IDs?', f'What equipment and instruments does page {m.group(1)} of {pdf_name} show?'])
        a = {'action': 'tags', 'plant_name': plant, 'pages': m.group(1)}
        res = T.call('pid_kg', a)
        if 'error' in res:
            continue
        out.append({'task': 'public_pid_tags', 'messages': [sysmsg, {'role': 'user', 'content': q},
                                                           {'role': 'assistant', 'content': tb('pid_kg', a)},
                                                           {'role': 'user', 'content': 'TOOL_RESULT pid_kg: ' + agent.compact_result(res)},
                                                           {'role': 'assistant', 'content': 'Tags found on the sheet (text layer / OCR; to be '
                                                                                            'confirmed when the sheet is read):\n' + res['output']}]})
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', required=True)
    ap.add_argument('--cache', default=os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'pids'))
    ap.add_argument('--max-pages', type=int, default=4, help='pages per drawing set (render + OCR take time)')
    ap.add_argument('--local')
    ap.add_argument('--pages')
    ap.add_argument('--name')
    a = ap.parse_args(argv)
    work = tempfile.mkdtemp(prefix='sb_pid_')
    T = agent.Tools(work)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    r = random.Random(0)
    jobs = [{'name': a.name or 'Local plant', 'path': a.local, 'pages': a.pages or '1'}] if a.local else datasets()
    rows = []
    for d in jobs:
        try:
            path = d.get('path') or fetch(d['url'], a.cache)
        except Exception as e:
            print(f"  {d['name']}: download failed ({type(e).__name__}: {e})")
            continue
        name = os.path.basename(path)
        dst = os.path.join(work, name)
        if not os.path.exists(dst):
            os.symlink(os.path.abspath(path), dst) if os.name != 'nt' else __import__('shutil').copy(path, dst)
        pages = _first_pages(d['pages'], a.max_pages)
        got = samples_for(T, name, d['name'], pages, sysmsg, r)
        print(f"  {d['name']}: {len(got)} samples (pages {pages})")
        rows += got
    with open(a.out, 'w', encoding='utf-8') as f:
        for x in rows:
            f.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
