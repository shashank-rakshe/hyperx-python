"""
Verified CAD example library for retrieval (RAG): examples/cadquery/*.py, each with
    # Prompt: <what the part is>
    # Tags: <words>
and a script that sets `result`. `python -m shipbrain.examples verify` builds every example and stores its metrics in
examples/cadquery/index.json; an example is only served if it built and its metrics are on record.
Add your own parts the same way - the library grows without retraining.
"""
import json, os, re, sys

from .knowledge import Knowledge

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(os.path.dirname(HERE), 'examples', 'cadquery')


def parse(path):
    src = open(path, encoding='utf-8').read()
    pr = re.search(r'^#\s*Prompt:\s*(.+)$', src, re.M)
    tg = re.search(r'^#\s*Tags:\s*(.+)$', src, re.M)
    return {'name': os.path.splitext(os.path.basename(path))[0], 'prompt': pr.group(1).strip() if pr else '',
            'tags': tg.group(1).strip() if tg else '', 'code': src}


class Examples:
    def __init__(self, folder=None):
        self.folder = folder or DEFAULT_DIR
        self.items, self.kb = [], Knowledge()
        idx_path = os.path.join(self.folder, 'index.json')
        index = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
        if not os.path.isdir(self.folder):
            return
        for f in sorted(os.listdir(self.folder)):
            if f.endswith('.py'):
                e = parse(os.path.join(self.folder, f))
                m = index.get(e['name'])
                if not m or not m.get('ok'):
                    continue                                   # unverified examples are never served
                e['metrics'] = {k: m[k] for k in ('bbox', 'volume', 'n_solids') if k in m}
                self.items.append(e)
                ids = ' '.join(set(re.findall(r'\.(\w+)\(', e['code'])))   # API calls used: rect, extrude, slot2D...
                self.kb.add(f, e['prompt'] + '\n' + e['tags'] + '\n' + ids, e['name'], id=e['name'])

    def search(self, query, k=2):
        by = {e['name']: e for e in self.items}
        return [by[h['id']] for h in self.kb.search(query, k) if h['id'] in by]


def verify_all(folder=None, workdir=None):
    import tempfile
    from . import cadrun
    folder = folder or DEFAULT_DIR
    work = workdir or tempfile.mkdtemp(prefix='sb_ex_')
    idx_path = os.path.join(folder, 'index.json')
    old = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    index, report = {}, []
    for f in sorted(os.listdir(folder)):
        if not f.endswith('.py'):
            continue
        e = parse(os.path.join(folder, f))
        r = cadrun.run(e['code'], work)
        ok = r.get('ok') and r.get('n_solids', 0) >= 1 and r.get('valid')
        if ok and e['name'] in old:                            # must reproduce what is on record
            chk = cadrun.verify(r, {'bbox': old[e['name']]['bbox'], 'volume': old[e['name']]['volume']})
            ok = all(c.startswith('PASS') for c in chk)
            if not ok:
                report.append(f"{e['name']}: CHANGED {chk}")
        index[e['name']] = {'ok': bool(ok), **{k: r.get(k) for k in ('bbox', 'volume', 'n_solids', 'error_type', 'message') if r.get(k) is not None}}
        report.append(f"{e['name']}: {'ok' if ok else 'FAILED'} {r.get('bbox', r.get('message', ''))}")
    json.dump(index, open(idx_path, 'w'), indent=1)
    return report


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'verify':
        print('\n'.join(verify_all(sys.argv[2] if len(sys.argv) > 2 else None)))
    else:
        print(__doc__)
