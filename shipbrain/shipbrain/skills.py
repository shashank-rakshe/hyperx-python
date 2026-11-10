"""
Skills and hooks: teach ShipBrain workflows and add behaviour WITHOUT retraining (same idea as LLM agent skills / plugins).

SKILL  a small Markdown file: what it is for, when to use it, and the steps.

    ---
    name: fea-prep
    description: get an uploaded CAD model ready for FEA
    when: clean ?up|defeature|prepare .*(fea|mesh)|repair
    ---
    1. file_info(file) ...
    2. repair_model(file, request=<the user's words>) ...

    Built-in skills ship in shipbrain/skill_library/; your own go in <workdir>/skills/ (or --skills DIR). For every question the
    best matching skill (its `when` pattern, else word match with its description) is given to the model with the
    retrieved knowledge, so it follows the steps. add_skill() saves a new one from the chat ("whenever I ask X, do ...").

HOOK   a function in a plugin file (the same file as its TOOLS), called at fixed moments; what it returns (text) is
       given to the model as a note:

    HOOKS = {'question': fn(question) -> str|None,                 # before the model sees a question
             'tool_result': fn(name, args, result) -> str|None,    # after every tool call
             'compact': fn(notes_text) -> str|None}                # after old turns were turned into notes
"""
import os, re

from .knowledge import Knowledge

BUILTIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'skill_library')


def parse(text, source=''):
    """Markdown with a '---' front matter -> dict(name, description, when, steps, source)"""
    meta, body = {}, text
    m = re.match(r'\s*---\s*\n(.*?)\n---\s*\n?(.*)$', text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if ':' in line:
                k, v = line.split(':', 1)
                meta[k.strip().lower()] = v.strip()
        body = m.group(2)
    name = meta.get('name') or os.path.splitext(os.path.basename(source))[0]
    return {'name': name, 'description': meta.get('description', ''), 'when': meta.get('when', ''), 'steps': body.strip(),
            'source': source}


class Skills:
    def __init__(self, folders=()):
        self.items = {}
        for f in [BUILTIN] + [x for x in folders if x]:
            self.load_folder(f)

    def load_folder(self, folder):
        if not os.path.isdir(folder):
            return 0
        n = 0
        for root, _, files in os.walk(folder):
            for fn in sorted(files):
                if fn.lower().endswith('.md'):
                    p = os.path.join(root, fn)
                    try:
                        sk = parse(open(p, encoding='utf-8').read(), p)
                    except Exception:
                        continue
                    if sk['steps']:
                        self.items[sk['name']] = sk                  # a user skill with the same name replaces a built-in
                        n += 1
        self._kb = None
        return n

    def match(self, question, k=1):
        """best skills for a question: `when` pattern first, then word match with name + description"""
        q = question or ''
        hits = []
        for sk in self.items.values():
            try:
                if sk['when'] and re.search(sk['when'], q, re.I):
                    hits.append(sk)
            except re.error:
                pass
        if len(hits) < k:
            if self._kb is None:
                self._kb = Knowledge()
                for sk in self.items.values():
                    self._kb.add(sk['source'], sk['name'].replace('-', ' ') + '. ' + sk['description'], sk['name'], id=sk['name'])
            for h in self._kb.search(q, k):
                sk = self.items.get(h['id'])
                if sk and sk not in hits and h['score'] >= 4.0:
                    hits.append(sk)
        return hits[:k]

    def add(self, folder, name, description, steps, when=''):
        name = re.sub(r'[^a-z0-9\-]+', '-', str(name).lower()).strip('-')[:40] or 'my-skill'
        if when:
            re.compile(when)                                       # a bad pattern is refused here, not at question time
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name + '.md')
        steps = steps if isinstance(steps, str) else '\n'.join(f'{i + 1}. {s}' for i, s in enumerate(steps))
        text = f'---\nname: {name}\ndescription: {description}\nwhen: {when}\n---\n{steps.strip()}\n'
        open(path, 'w', encoding='utf-8').write(text)
        self.items[name] = parse(text, path)
        self._kb = None
        return path


def context(sk):
    return f"[skill {sk['name']}] {sk['description']}. Follow these steps:\n{sk['steps'][:1500]}"
