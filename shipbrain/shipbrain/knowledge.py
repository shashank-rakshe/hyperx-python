"""
Knowledge base = the "brain" you can grow without retraining.
Drop files into a folder (rule books .md/.txt, notes, standards you are licensed to use, .json rule indexes, .py examples,
.pdf if PyMuPDF is installed). They are cut into chunks and searched with BM25 on every question; the best chunks go into the
model's prompt together with their source, so answers cite where they came from.

Fine-tuning teaches the model *how* to work (formats, tool use, method). The knowledge base gives it *facts* that change.
"""
import json, math, os, re

TEXT_EXT = ('.md', '.txt', '.rst', '.py', '.csv', '.inp', '.bdf', '.dat', '.log')
_tok = re.compile(r'[A-Za-z][A-Za-z0-9_\-\.]*|\d+(?:\.\d+)?')
_STOP = set('the a an of to in on and or for is are be by with as at it this that from into than then use used when which'.split())


def tokens(text):
    return [w for w in (t.lower().strip('.') for t in _tok.findall(text)) if w and w not in _STOP]


def _chunks(text, size=900):
    """split on headings / blank lines, then pack paragraphs to ~size chars"""
    parts = re.split(r'\n(?=#{1,6} )|\n\s*\n', text)
    out, cur, head = [], '', ''
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if p.startswith('#'):
            head = p.splitlines()[0].lstrip('# ').strip()
        if len(cur) + len(p) > size and cur:
            out.append((head, cur))
            cur = ''
        cur = (cur + '\n\n' + p) if cur else p
        while len(cur) > size * 2:
            out.append((head, cur[:size * 2]))
            cur = cur[size * 2:]
    if cur:
        out.append((head, cur))
    return out


def _read(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == '.pdf':
        md = _mineru(path)
        if md:
            return md
        try:
            import fitz                              # PyMuPDF
        except ImportError:
            return None
        with fitz.open(path) as d:
            return '\n\n'.join(f'# page {i + 1}\n' + p.get_text() for i, p in enumerate(d))
    if ext in TEXT_EXT:
        return open(path, encoding='utf-8', errors='replace').read()
    return None


def _mineru(path):
    """optional: MinerU (opendatalab, own licence - see README) turns PDFs incl. scans, tables and formulas into Markdown.
    Used only when SHIPBRAIN_MINERU=1 and the `mineru` command is installed. Results are cached next to the PDF."""
    import shutil, subprocess
    if os.environ.get('SHIPBRAIN_MINERU') != '1' or not shutil.which('mineru'):
        return None
    cache = path + '.mineru.md'
    if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(path):
        return open(cache, encoding='utf-8').read()
    out = path + '.mineru_out'
    try:
        subprocess.run(['mineru', '-p', path, '-o', out], check=True, capture_output=True, timeout=3600)
    except Exception:
        return None
    mds = [os.path.join(r, f) for r, _, fs in os.walk(out) for f in fs if f.endswith('.md')]
    if not mds:
        return None
    text = '\n\n'.join(open(m, encoding='utf-8').read() for m in mds)
    open(cache, 'w', encoding='utf-8').write(text)
    return text


class Knowledge:
    def __init__(self):
        self.docs = []                               # {'id', 'source', 'title', 'text'}
        self._df, self._tf, self._len = {}, [], []

    # ---------------------------------------------------------- loading
    def add(self, source, text, title='', id=None):
        d = {'id': id or f'{os.path.basename(source)}#{len(self.docs) + 1}', 'source': source, 'title': title, 'text': text}
        tf = {}
        for w in tokens(title + ' ' + text + ' ' + (id or '')):
            tf[w] = tf.get(w, 0) + 1
        for w in tf:
            self._df[w] = self._df.get(w, 0) + 1
        self.docs.append(d)
        self._tf.append(tf)
        self._len.append(sum(tf.values()))

    def add_rule_index(self, path):
        """rules_index.json style: [{'id','text','file','section'}, ...] -> one chunk per rule (rule id kept)"""
        n = 0
        for e in json.load(open(path, encoding='utf-8')):
            if isinstance(e, dict) and e.get('text'):
                self.add(e.get('file', os.path.basename(path)), e['text'], e.get('section', ''), id=e.get('id'))
                n += 1
        return n

    def add_folder(self, folder, skipped=None):
        n = 0
        for root, dirs, files in os.walk(folder):
            dirs[:] = [d for d in dirs if not d.startswith(('.', '__'))]
            for f in sorted(files):
                p = os.path.join(root, f)
                try:
                    if f.endswith('.json'):
                        data = json.load(open(p, encoding='utf-8'))
                        if isinstance(data, list) and data and isinstance(data[0], dict) and 'text' in data[0]:
                            n += self.add_rule_index(p)
                        continue
                    if os.path.getsize(p) > 50e6:                 # huge XML/models are data, not knowledge
                        skipped is not None and skipped.append(p)
                        continue
                    text = _read(p)
                    if text is None:
                        skipped is not None and skipped.append(p)
                        continue
                    for head, c in _chunks(text):
                        self.add(os.path.relpath(p, folder), c, head)
                        n += 1
                except Exception:
                    skipped is not None and skipped.append(p)
        return n

    # ---------------------------------------------------------- search
    def search(self, query, k=5, k1=1.4, b=0.75):
        q = tokens(query)
        if not q or not self.docs:
            return []
        N, avg = len(self.docs), sum(self._len) / len(self._len)
        idq = [(w, math.log(1 + (N - self._df.get(w, 0) + .5) / (self._df.get(w, 0) + .5))) for w in set(q)]
        ql = query.lower()
        scored = []
        for i, tf in enumerate(self._tf):
            s = 0.0
            for w, idf in idq:
                f = tf.get(w)
                if f:
                    s += idf * f * (k1 + 1) / (f + k1 * (1 - b + b * self._len[i] / avg))
            did = self.docs[i]['id']
            if did and not did.endswith(tuple('#' + str(j) for j in range(10))) and did.lower() in ql:
                s += 10                                            # exact rule id asked for
            if s > 0:
                scored.append((s, i))
        scored.sort(reverse=True)
        return [{**self.docs[i], 'score': round(s, 2)} for s, i in scored[:k]]

    def __len__(self):
        return len(self.docs)


def load(paths):
    kb, skipped = Knowledge(), []
    for p in paths or []:
        if os.path.isdir(p):
            kb.add_folder(p, skipped)
        elif p.endswith('.json'):
            kb.add_rule_index(p)
        elif os.path.exists(p):
            t = _read(p)
            for head, c in _chunks(t or ''):
                kb.add(os.path.basename(p), c, head)
    kb.skipped = skipped
    return kb
