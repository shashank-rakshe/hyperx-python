"""
Measure the model speed on THIS PC: time to read the ShipBrain prompt and tokens per second when writing.

    python -m shipbrain.bench --server http://127.0.0.1:8081
Uses llama.cpp's own timings (llama-server / llamafile). Prints a plain-English verdict and tips.
"""
import argparse, json, os, time, urllib.request

from . import agent


def once(base, messages, n=128):
    body = {'messages': messages, 'max_tokens': n, 'temperature': 0, 'cache_prompt': True, 'stream': False}
    req = urllib.request.Request(base.rstrip('/') + '/v1/chat/completions', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    t = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read())
    return d.get('timings', {}), time.time() - t, d.get('usage', {})


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--server', default='http://127.0.0.1:8081')
    a = ap.parse_args(argv)
    tools = agent.Tools(os.path.join(os.getcwd(), 'shipbrain_work'), allow_code=True)
    q = 'Mesh a deck panel 4800 x 3200 mm, plate 12 mm, FB 150x12 stiffeners at 800 mm, clamped edges'
    msgs = [{'role': 'system', 'content': agent.system_prompt(tools)}, {'role': 'user', 'content': q}]
    first, t1, u1 = once(a.server, msgs)
    second, t2, u2 = once(a.server, msgs[:1] + [{'role': 'user', 'content': q.replace('4800', '6000')}])
    pp = first.get('prompt_per_second') or 0
    tg = second.get('predicted_per_second') or first.get('predicted_per_second') or 0
    cached = second.get('prompt_n', 0) < first.get('prompt_n', 1)
    res = {'prompt_tokens': u1.get('prompt_tokens'), 'prompt_read_tokens_per_s': round(pp, 1), 'write_tokens_per_s': round(tg, 1),
           'first_question_s': round(t1, 1), 'next_question_s': round(t2, 1), 'prompt_cache_works': cached}
    txt = (f"Reading the prompt: {pp:.0f} tokens/s; writing: {tg:.1f} tokens/s. First question took {t1:.0f} s, the next one "
           f"{t2:.0f} s" + (' (the system prompt was re-used from the cache).' if cached else '.'))
    tips = []
    if tg < 8:
        tips.append('use a smaller model (Qwen3-1.7B or 0.6B, q4_k_m) or add a draft model (--draft) for speculative decoding')
    if not cached:
        tips.append('use llama-server / llamafile (prompt cache) and keep one chat session open')
    if pp < 60:
        tips.append('set --threads to the number of PHYSICAL cores and close other heavy programs')
    res['plain_english'] = txt + (' Tips: ' + '; '.join(tips) + '.' if tips else ' Speed is fine.')
    print(json.dumps(res, indent=1))


if __name__ == '__main__':
    main()
