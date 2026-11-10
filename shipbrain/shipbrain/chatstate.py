"""
Long chats on a small local model: keep the important things when old turns no longer fit in the context window.
(Idea from compact-state, MIT, https://github.com/BrijeshParmar/compact-state-skill: after compaction, a notes file with
State now / Decisions / IDs and paths / Next is what the session relies on. Own implementation.)

The model's window is small (8k tokens by default). When the chat no longer fits, the oldest turns are dropped and a
notes block made from them goes in their place. It is built by code, not by the model, so nothing is paraphrased away:

  State now      the last answers that were dropped (their first sentences)
  Decisions      the user's dropped messages, word for word, with "user" and the date
  IDs and paths  every file name, path and id that appeared in the dropped turns
  Next           the newest request (it is always kept in full)

The same notes are written to <workdir>/.state/<chat id>.md, so the user can open, check and correct them; a corrected
file is used as it is on the next turn.
"""
import hashlib, os, re, time

CTX_TOKENS = 8192          # the model server's context; the app sets it from --ctx
RESERVE = 1800             # room for the answer and the tool steps of this turn

_FILE = re.compile(r'[\w\-./\\:]+\.(?:step|stp|brep|iges|igs|stl|bdf|dat|nas|inp|frd|mac|py|json|jsonl|csv|xlsx|xls|pdf|dxf|dwg|png|jpg|'
                   r'vtk|npz|hpp|gguf|md|txt|xml|sbpack|op2|f06|odb)\b', re.I)
_ID = re.compile(r'\b(?:[A-Z]{1,4}[-_]?\d{2,}[A-Za-z0-9_-]*|[a-z]+_[0-9a-f]{6,}|trig_\w+|session_\w+)\b')


def tokens(text):
    return int(len(text) / 3.5) + 4                      # rough: ~3.5 characters per token for English + numbers


def chat_id(history):
    first = next((m['content'] for m in history if m['role'] == 'user'), '')
    return 'chat_' + hashlib.sha1(first[:500].encode('utf-8', 'ignore')).hexdigest()[:10]


def fit(history, budget):
    """-> (kept, dropped): the newest messages that fit in budget tokens (the last message is always kept);
    the kept part starts with a user turn"""
    used, start = 0, len(history)
    for i in range(len(history) - 1, -1, -1):
        t = tokens(history[i]['content'])
        if start < len(history) and used + t > budget:
            break
        used += t
        start = i
    while start < len(history) - 1 and history[start]['role'] != 'user':
        start += 1
    return history[start:], history[:start]


def _first_sentence(text, n=220):
    t = re.sub(r'```.*?```', '', text, flags=re.S).strip()
    m = re.match(r'(.{20,}?[.!?])(\s|$)', t, re.S)
    return (m.group(1) if m else t)[:n].replace('\n', ' ')


_DECIDE = re.compile(r"(?i)\b(use|using|never|always|don'?t|do not|must|should|shall|we|our|prefer|keep|set|remember|from now|"
                     r"instead|only|not|change|switch|decided?|agree[ds]?|ok(ay)?|yes|no)\b")


def notes(dropped, newest=None, date=None):
    """the four sections; decisions = the opening request + messages that read like a decision or an instruction"""
    date = date or time.strftime('%Y-%m-%d')
    state = [_first_sentence(m['content']) for m in dropped if m['role'] == 'assistant' and m['content'].strip()][-4:]
    users = [m['content'].strip().replace('\n', ' ') for m in dropped if m['role'] == 'user' and m['content'].strip()
             and not m['content'].startswith('TOOL_RESULT')]
    decisions = [u for i, u in enumerate(users) if i == 0 or _DECIDE.search(u[:300])]
    ids = []
    for m in dropped:
        for x in _FILE.findall(m['content']) + _ID.findall(m['content']):
            if x not in ids:
                ids.append(x)
    return {'state': state, 'decisions': [f'"{d[:300]}" (user, {date})' for d in decisions], 'ids': ids,
            'next': newest.strip()[:300] if newest else 'answer the newest message'}


def render(n):
    out = ['# Notes from the earlier part of this chat (kept by code, word for word where it matters)', '', '## State now']
    out += [f'- {s}' for s in n['state']] or ['- (nothing answered yet)']
    out += ['', '## Decisions'] + ([f'- {d}' for d in n['decisions']] or ['- (none)'])
    out += ['', '## IDs and paths'] + ([f'- {x}' for x in n['ids']] or ['- (none)'])
    out += ['', '## Next', f"- {n['next']}"]
    return '\n'.join(out)


def shrink(n, budget):
    """fit the notes in budget tokens; what goes first: old answers, then old ids, then middle decisions
    (the opening request and the newest decisions stay)"""
    n = {k: (list(v) if isinstance(v, list) else v) for k, v in n.items()}
    while tokens(render(n)) > budget:
        if n['state']:
            n['state'].pop(0)
        elif len(n['ids']) > 10:
            n['ids'].pop(0)
        elif len(n['decisions']) > 3:
            n['decisions'].pop(1)
        elif n['ids']:
            n['ids'].pop(0)
        elif len(n['decisions']) > 1:
            n['decisions'].pop(1)
        else:
            break
    return render(n)


def compact(history, workdir=None, ctx=None, fixed_tokens=0):
    """history -> (history that fits, notes text or None). fixed_tokens = system prompt + retrieved context"""
    budget = max(400, (ctx or CTX_TOKENS) - RESERVE - fixed_tokens)
    if sum(tokens(m['content']) for m in history) <= budget:
        return history, None
    path = None
    if workdir:
        path = os.path.join(workdir, '.state', chat_id(history) + '.md')
    note_budget = min(900, budget // 3)
    kept, dropped = fit(history, budget - note_budget)
    newest = history[-1]['content'] if history and history[-1]['role'] == 'user' else None
    text = None
    if path and os.path.exists(path):
        try:
            old = open(path, encoding='utf-8').read()
            if old.splitlines() and '(edited)' in old.splitlines()[0]:
                text = old.strip()                         # the user corrected the file: use it as it is
        except Exception:
            pass
    if text is None:
        text = shrink(notes(dropped, newest), note_budget)
        if path:
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                open(path, 'w', encoding='utf-8').write(text + '\n\n(To correct these notes: edit them and add " (edited)" to '
                                                        'the first line; ShipBrain then uses your version.)\n')
            except Exception:
                pass
    return kept, text
