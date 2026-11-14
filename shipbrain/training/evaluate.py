"""
Score a model served on an OpenAI-compatible endpoint against data/eval.jsonl (run before AND after fine-tuning).

  python training/evaluate.py --server http://127.0.0.1:8080 --data data/eval.jsonl --out eval_after.json

Per sample, the model gets the system prompt + user request (and, for multi-step samples, the turns before the last tool call)
and must reply with the right tool call. Scores:
  tool_ok    the reply contains a valid ```tool block naming the expected tool
  args_ok    every numeric argument within 1 % of the reference and every text argument equal (name ignored)
  final_ok   (chat / answer turns) the reference's bold numbers appear in the model's answer
"""
import argparse, json, os, re, sys, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from shipbrain import agent  # noqa: E402


def flat(d, p=''):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flat(v, f'{p}.{k}' if p else k))
    else:
        out[p] = d
    return out


def args_match(ref, got, ignore=('name', 'k', 'query')):
    fr, fg = flat(ref), flat(got or {})
    bad = []
    for k, v in fr.items():
        if k.split('.')[-1] in ignore or v is None:
            continue
        g = fg.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            try:
                if abs(float(g) - v) > max(1e-6, 0.01 * abs(v)):
                    bad.append(k)
            except (TypeError, ValueError):
                bad.append(k)
        elif str(g).lower() != str(v).lower():
            bad.append(k)
    return not bad, bad


class LocalModel:
    """score a model inside Python (Colab GPU) without a server: base name or a LoRA / merged folder"""
    def __init__(self, name, max_new_tokens=700):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from model_io import load
        self.model, self.tok, self.proc = load(name, 6144, train=False)      # text or vision base, same way
        self.n = max_new_tokens

    def stream(self, messages):
        try:
            ids = self.tok.apply_chat_template(messages, add_generation_prompt=True, return_tensors='pt')
        except Exception:                                  # vision processor: content lists
            msgs = [{'role': m['role'], 'content': [{'type': 'text', 'text': m['content']}]} for m in messages]
            ids = self.proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_tensors='pt')
        ids = (ids['input_ids'] if not hasattr(ids, 'shape') else ids).to(self.model.device)    # transformers 4 and 5
        out = self.model.generate(input_ids=ids, max_new_tokens=self.n, do_sample=False)
        yield self.tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--server', default='http://127.0.0.1:8080')
    ap.add_argument('--model', default='local')
    ap.add_argument('--data', default='data/eval.jsonl')
    ap.add_argument('--out', default='eval_result.json')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--local', help='score this model directly in Python (HF name or LoRA folder) instead of a server')
    a = ap.parse_args()
    llm = LocalModel(a.local) if a.local else agent.LLM(a.server, a.model, temperature=0.0, max_tokens=700)
    rows = [json.loads(l) for l in open(a.data, encoding='utf-8')]
    rows = rows[:a.limit] if a.limit else rows
    per, details = {}, []
    t0 = time.time()
    for i, d in enumerate(rows):
        msgs = d['messages']
        # the target = the LAST assistant tool call (after any earlier failed call + error), else the final answer
        idx = max((j for j, m in enumerate(msgs) if m['role'] == 'assistant' and '```tool' in m['content']), default=None)
        target_i = idx if idx is not None else len(msgs) - 1
        prompt, ref = msgs[:target_i], msgs[target_i]['content']
        try:                                               # the app's per-question system prompt (same as in training)
            from finetune import with_system
            prompt = with_system(prompt)
        except Exception:
            pass
        try:
            got = ''.join(llm.stream(prompt))
        except Exception as e:
            got = f'ERROR {e}'
        s = per.setdefault(d['task'], {'n': 0, 'tool_ok': 0, 'args_ok': 0, 'final_ok': 0})
        s['n'] += 1
        rec = {'task': d['task'], 'user': next(m['content'] for m in msgs if m['role'] == 'user')[:200], 'got': got[:600]}
        rc = agent.parse_tool_call(ref)
        if rc:
            gc = agent.parse_tool_call(got)
            if gc and gc['name'] == rc['name']:
                s['tool_ok'] += 1
                ok, bad = args_match(rc['args'], gc['args'])
                s['args_ok'] += ok
                rec['bad_args'] = bad
        else:
            nums = re.findall(r'\*\*([^*]+)\*\*', ref)
            s['final_ok'] += all(n.split()[0] in got for n in nums) if nums else (len(got) > 20)
        details.append(rec)
        print(f'{i + 1}/{len(rows)} {d["task"]:12s} {time.time() - t0:.0f}s', end='\r')
    total = {k: sum(s[k] for s in per.values()) for k in ('n', 'tool_ok', 'args_ok', 'final_ok')}
    res = {'server': a.server, 'per_task': per, 'total': total, 'details': details}
    json.dump(res, open(a.out, 'w'), indent=1)
    print()
    for t, s in sorted(per.items()):
        print(f"{t:12s} n={s['n']:3d}  tool {s['tool_ok']:3d}  args {s['args_ok']:3d}  final {s['final_ok']:3d}")
    print('total', total, '->', a.out)


if __name__ == '__main__':
    main()
