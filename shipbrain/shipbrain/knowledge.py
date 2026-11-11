"""
Knowledge base = the "brain" you can grow without retraining.
Drop files into a folder (rule books .md/.txt, notes, standards you are licensed to use, .json rule indexes, .py examples,
.pdf via pypdfium2). They are cut into chunks and searched with BM25 on every question; the best chunks go into the
model's prompt together with their source, so answers cite where they came from.

Fine-tuning teaches the model *how* to work (formats, tool use, method). The knowledge base gives it *facts* that change.
"""
import json, math, os, re
from array import array

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
        try:
            import pypdfium2                         # Apache-2.0 / BSD
        except ImportError:
            return None
        pdf = pypdfium2.PdfDocument(path)
        try:
            return '\n\n'.join(f'# page {i + 1}\n' + pdf[i].get_textpage().get_text_range() for i in range(len(pdf)))
        finally:
            pdf.close()
    if ext in TEXT_EXT:
        return open(path, encoding='utf-8', errors='replace').read()
    return None


class Knowledge:
    def __init__(self):
        self.docs = []                               # {'id', 'source', 'title', 'text'}
        self._post, self._len, self._tot = {}, array('i'), 0   # word -> (doc ids, term counts): an inverted index

    # ---------------------------------------------------------- loading
    def add(self, source, text, title='', id=None):
        d = {'id': id or f'{os.path.basename(source)}#{len(self.docs) + 1}', 'source': source, 'title': title, 'text': text}
        tf = {}
        for w in tokens(title + ' ' + text + ' ' + (id or '')):
            tf[w] = tf.get(w, 0) + 1
        i = len(self.docs)
        for w, c in tf.items():
            p = self._post.get(w)
            if p is None:
                p = self._post[w] = (array('i'), array('H'))
            p[0].append(i)
            p[1].append(min(c, 65535))
        self.docs.append(d)
        n = sum(tf.values())
        self._len.append(n)
        self._tot += n

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
                    rel = os.path.relpath(p, folder)
                    st = os.stat(p)
                    key = f'{os.path.abspath(p)}|{st.st_size}|{int(st.st_mtime)}'
                    cache = getattr(self, 'file_cache', None)
                    if cache is not None and key in cache:          # unchanged file: reuse its chunks
                        chunks = cache[key]
                    else:
                        text = _read(p)
                        if text is None:
                            skipped is not None and skipped.append(p)
                            continue
                        chunks = _chunks(text)
                        if cache is not None:
                            for old in [k_ for k_ in cache if k_.startswith(os.path.abspath(p) + '|')]:
                                del cache[old]
                            cache[key] = chunks
                    for head, c in chunks:
                        self.add(rel, c, head)
                        n += 1
                except Exception:
                    skipped is not None and skipped.append(p)
        return n

    # ---------------------------------------------------------- search
    def search(self, query, k=5, k1=1.4, b=0.75, scope=None):
        """hybrid: BM25 keyword score, fused (reciprocal rank fusion) with meaning-based embedding search when an
        embedding server is set; scope = text a source path must contain (search one project / folder only)"""
        bm = self._bm25(query, max(k * 4, 20), k1, b, scope)
        if not getattr(self, 'embedder', None) or not self.docs:
            return bm[:k]
        try:
            emb = self._semantic(query, max(k * 4, 20), scope)
        except Exception:
            return bm[:k]
        fused = {}
        for lst in (bm, emb):
            for r, h in enumerate(lst):
                fused.setdefault(h['id'], [0.0, h])[0] += 1.0 / (60 + r)
        out = sorted(fused.values(), key=lambda x: -x[0])[:k]
        return [{**h, 'score': round(sc * 1000, 2)} for sc, h in out]

    def _semantic(self, query, k, scope):
        import numpy as np
        V = self._vectors()
        qv = np.array(self.embedder.embed([query])[0], float)
        sims = V @ (qv / (np.linalg.norm(qv) or 1))
        order = np.argsort(-sims)
        out = []
        for i in order:
            d = self.docs[int(i)]
            if scope and scope.lower() not in d['source'].lower():
                continue
            out.append({**d, 'score': float(sims[i])})
            if len(out) >= k:
                break
        return out

    def _vectors(self):
        import numpy as np, hashlib
        cache = getattr(self, 'emb_cache', None)
        store = {}
        if cache and os.path.exists(cache):
            z = np.load(cache, allow_pickle=False)
            store = dict(zip(z['keys'].tolist(), z['vecs']))
        keys = [hashlib.sha1(d['text'].encode()).hexdigest() for d in self.docs]
        todo = [i for i, k_ in enumerate(keys) if k_ not in store]
        for j in range(0, len(todo), 32):
            batch = todo[j:j + 32]
            for i, v in zip(batch, self.embedder.embed([self.docs[i]['text'][:2000] for i in batch])):
                v = np.array(v, float)
                store[keys[i]] = v / (np.linalg.norm(v) or 1)
        if todo and cache:
            np.savez(cache, keys=np.array(list(store)), vecs=np.array(list(store.values())))
        return np.array([store[k_] for k_ in keys])

    def _bm25(self, query, k=5, k1=1.4, b=0.75, scope=None):
        q = tokens(query)
        if not q or not self.docs:
            return []
        N, avg = len(self.docs), self._tot / max(len(self._len), 1)
        score = {}
        for w in set(q):                                       # only the documents that contain a query word
            p = self._post.get(w)
            if not p:
                continue
            idf = math.log(1 + (N - len(p[0]) + .5) / (len(p[0]) + .5))
            for i, f in zip(p[0], p[1]):
                score[i] = score.get(i, 0.0) + idf * f * (k1 + 1) / (f + k1 * (1 - b + b * self._len[i] / avg))
        ql = query.lower()
        scored = []
        for i, s in score.items():
            if scope and scope.lower() not in self.docs[i]['source'].lower():
                continue
            scored.append((s, i))
        for i in self._exact_ids(ql):                          # exact rule id asked for
            if not scope or scope.lower() in self.docs[i]['source'].lower():
                scored.append((score.get(i, 0.0) + 10, i))
                score.pop(i, None)
        seen = set()
        scored = [(s, i) for s, i in sorted(scored, reverse=True) if not (i in seen or seen.add(i))]
        return [{**self.docs[i], 'score': round(s, 2)} for s, i in scored[:k]]

    def _exact_ids(self, ql):
        """documents whose own id (a rule id, not a chunk number) appears in the question"""
        if getattr(self, '_ids_n', -1) != len(self.docs):
            self._ids = [(d['id'].lower(), i) for i, d in enumerate(self.docs)
                         if d['id'] and not re.search(r'#\d+$', d['id'])]
            self._ids_n = len(self.docs)
        return [i for did, i in self._ids if did in ql]

    def __len__(self):
        return len(self.docs)


class Embedder:
    """meaning-based search vectors from any OpenAI-compatible /v1/embeddings server running locally, e.g.
    llama-server -m nomic-embed-text-v1.5.Q8_0.gguf --embedding --port 8090   (open source, CPU)"""
    def __init__(self, base_url, model='local'):
        self.base, self.model = base_url.rstrip('/').removesuffix('/v1'), model

    def embed(self, texts):
        import urllib.request
        req = urllib.request.Request(self.base + '/v1/embeddings', json.dumps({'model': self.model, 'input': texts}).encode(),
                                     {'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=300) as r:
            data = json.loads(r.read())['data']
        return [d['embedding'] for d in sorted(data, key=lambda d: d.get('index', 0))]


def load(paths, cache_dir=None, embedder=None):
    """paths: folders / files. cache_dir: keeps the chunked index (re-reads only files whose content changed) and the
    embedding vectors, so restarting the app is fast even with large rule books"""
    kb, skipped = Knowledge(), []
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
        kb.file_cache_path = os.path.join(cache_dir, 'index_cache.json')
        try:
            kb.file_cache = json.load(open(kb.file_cache_path, encoding='utf-8'))
        except Exception:
            kb.file_cache = {}
        kb.emb_cache = os.path.join(cache_dir, 'embeddings.npz')
    kb.embedder = embedder
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
    if cache_dir:
        json.dump(kb.file_cache, open(kb.file_cache_path, 'w', encoding='utf-8'))
    return kb
