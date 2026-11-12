"""
Long-term memory of the assistant (idea from Voitta's "anamnesis"; own implementation).

  remember   facts and corrections the user teaches ("our frame spacing is 700 mm", "model brackets as shells")
  recall     searched on every question and given to the model with the retrieved knowledge
  feedback   like / dislike a memory: liked ones rank higher, clearly disliked ones are no longer used
  answers    thumbs up / down on an answer (from the chat page) are logged to feedback.jsonl:
             liked conversations become training samples for the next fine-tune; a thumbs-down with a correction
             is also stored as a memory, so the assistant stops repeating the mistake right away.
Everything is plain JSON lines in the work folder: readable, editable, and private to your PC.
"""
import json, os, time

from .knowledge import Knowledge


class Memory:
    def __init__(self, folder):
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(folder, 'memory.jsonl')
        self.fb_path = os.path.join(folder, 'feedback.jsonl')
        self.items = []
        if os.path.exists(self.path):
            for l in open(self.path, encoding='utf-8'):
                if l.strip():
                    self.items.append(json.loads(l))
        self._index()

    def _index(self):
        self.kb = Knowledge()
        for m in self.items:
            if not m.get('deleted'):
                self.kb.add('memory', m['text'] + ' ' + ' '.join(m.get('tags', [])), m.get('tags', [''])[0] if m.get('tags') else '', id=m['id'])

    def _save(self):
        tmp = self.path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            for m in self.items:
                f.write(json.dumps(m) + '\n')
        os.replace(tmp, self.path)

    def remember(self, text, tags=None, source='user'):
        text = ' '.join(str(text).split())
        if not text:
            raise ValueError('nothing to remember')
        for m in self.items:                                   # same fact again -> just like it
            if not m.get('deleted') and m['text'].lower() == text.lower():
                m['likes'] = m.get('likes', 0) + 1
                self._save()
                return {'id': m['id'], 'note': 'already known; liked it once more'}
        m = {'id': f'm{len(self.items) + 1}', 'text': text, 'tags': list(tags or []), 'source': source,
             'likes': 0, 'dislikes': 0, 'time': time.strftime('%Y-%m-%d %H:%M')}
        self.items.append(m)
        self._save()
        self._index()
        return {'id': m['id'], 'saved': text}

    def recall(self, query, k=3, min_score=2.0):
        out = []
        by = {m['id']: m for m in self.items}
        for h in self.kb.search(query, k * 3):
            m = by.get(h['id'])
            if not m or m.get('deleted'):
                continue
            if m.get('dislikes', 0) > m.get('likes', 0) + 1:           # clearly wrong: not used any more
                continue
            score = h['score'] * (1 + 0.25 * (m.get('likes', 0) - m.get('dislikes', 0)))
            if score >= min_score:
                out.append({**m, 'score': round(score, 2)})
        return sorted(out, key=lambda x: -x['score'])[:k]

    def feedback(self, id, good=True):
        for m in self.items:
            if m['id'] == id:
                m['likes' if good else 'dislikes'] = m.get('likes' if good else 'dislikes', 0) + 1
                self._save()
                return {'id': id, 'likes': m['likes'], 'dislikes': m['dislikes']}
        raise ValueError(f'no memory {id}')

    def forget(self, id):
        for m in self.items:
            if m['id'] == id:
                m['deleted'] = True
                self._save()
                self._index()
                return {'id': id, 'forgotten': True}
        raise ValueError(f'no memory {id}')

    def list(self):
        return [m for m in self.items if not m.get('deleted')]

    # ------------------------------------------------------------------ answer feedback (training data)
    def answer_feedback(self, messages, good, comment=''):
        rec = {'time': time.strftime('%Y-%m-%d %H:%M'), 'good': bool(good), 'comment': comment, 'messages': messages}
        with open(self.fb_path, 'a', encoding='utf-8') as f:
            f.write(json.dumps(rec) + '\n')
        out = {'logged': True}
        if not good and comment.strip():
            out['memory'] = self.correction(messages, comment.strip())
        return out

    def correction(self, messages, comment):
        """a thumbs-down with a correction -> a worked example used for similar questions right away:
        the question, the wrong answer, the correction, the tool involved; repeated corrections of the same kind gain weight;
        a correction whose numbers are not among the tool's numbers is marked, so the model checks before following it"""
        import re
        users = [m['content'] for m in messages if m['role'] == 'user' and isinstance(m['content'], str)
                 and not m['content'].startswith('TOOL_RESULT')]
        q = (users[0] if users else '')[:240]
        wrong = next((m['content'] for m in reversed(messages) if m['role'] == 'assistant' and isinstance(m['content'], str)
                      and '```tool' not in m['content']), '')[:300]
        tools_used = [re.search(r'"name"\s*:\s*"(\w+)"', m['content']).group(1) for m in messages
                      if m['role'] == 'assistant' and isinstance(m['content'], str) and re.search(r'"name"\s*:\s*"(\w+)"', m['content'])]
        results = ' '.join(m['content'] for m in messages if m['role'] == 'user' and isinstance(m['content'], str)
                           and m['content'].startswith('TOOL_RESULT'))
        num = lambda t: [float(x.replace(',', '')) for x in re.findall(r'(?<![\w.])-?\d[\d,]*\.?\d*', t)]
        cn, tn = num(comment), num(results)
        disagrees = bool(results) and bool(cn) and not all(any(abs(c - t) <= 0.02 * max(abs(c), 1e-9) for t in tn) for c in cn)
        tool = tools_used[-1] if tools_used else None
        words = lambda t: set(re.findall(r'[a-z0-9.]+', t.lower()))
        qw = words(q)
        for m in self.items:                                   # the same kind of correction again -> stronger, latest wording
            mw = words(m.get('question', ''))
            same = bool(qw and mw) and len(qw & mw) / len(qw | mw) >= 0.6
            if not m.get('deleted') and m.get('kind') == 'correction' and m.get('tool') == tool and same:
                m['likes'] = m.get('likes', 0) + 1
                m['count'] = m.get('count', 1) + 1
                m.update(correction=comment, wrong=wrong or m.get('wrong'), disagrees_with_tool=disagrees,
                         text=f'Correction (for questions like "{q}"): {comment}')
                self._save()
                self._index()
                return {'id': m['id'], 'note': f'same correction as before - now given {m["count"]} times, used with more weight'}
        r = self.remember(f'Correction (for questions like "{q}"): {comment}', ['correction'] + ([tool] if tool else []), 'feedback')
        for m in self.items:
            if m['id'] == r['id']:
                m.update(kind='correction', question=q, wrong=wrong, correction=comment, tool=tool, count=1,
                         disagrees_with_tool=disagrees)
        self._save()
        if disagrees:
            r['check'] = 'the correction has numbers the tool did not compute - the model will check before using it'
        return r
