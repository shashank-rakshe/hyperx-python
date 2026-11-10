"""
Held-out text-to-CAD test: "the model builds X % of unseen parts correctly".

Data: data/cad_eval_oracle.jsonl - parts from solidcraft's oracle set (tests/oracle, MIT OR Apache-2.0) that are NOT among the
ported examples/cadquery/sc_*.py, each with a plain-English prompt and analytic/kernel reference values (bbox, volume, body count).

Per item the model gets exactly what agent.run gives it: system prompt + retrieved context (agent.retrieve) + the user prompt. If its reply
holds a cadquery_build call, the tool runs it and the compact result goes back as "TOOL_RESULT cadquery_build: ..." (like the app); the model
then has up to --repairs more turns. The item PASSES when a build PASSes against the ITEM's expected values (the model's own expect is ignored
for scoring: cadrun.verify is always run with the item's expect).

  python training/cad_eval.py --server http://127.0.0.1:8080 --out cad_eval_result.json
  python training/cad_eval.py --local unsloth/Qwen2.5-Coder-1.5B-Instruct          # in Python (Colab GPU), no server
  python training/cad_eval.py --oracle-reference DIR     # run DIR/<id>.py reference scripts instead of a model (sanity: must be 100 %)

Scores: built (a build produced a valid solid) %, PASS first try %, PASS within 1 + repairs tries %, average code size, seconds per item.
"""
import argparse, json, os, re, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
from shipbrain import agent, cadrun  # noqa: E402

DEFAULT_DATA = os.path.join(HERE, 'data', 'cad_eval_oracle.jsonl')


def load(path, ids=None, limit=0):
    rows = [json.loads(l) for l in open(path, encoding='utf-8') if l.strip()]
    if ids:
        rows = [r for r in rows if r['id'] in ids]
    return rows[:limit] if limit else rows


def item_pass(res, expect):
    """score a cadquery_build result against the item's expected values (never the model's own)"""
    if not isinstance(res, dict) or not res.get('ok'):
        return False, []
    checks = cadrun.verify(res, expect)
    if not res.get('n_solids'):
        checks.append('FAIL n_solids: no solid was produced')
    if not res.get('valid', True):
        checks.append('FAIL valid: not a valid solid')
    return not any(c.startswith('FAIL') for c in checks), checks


def built_ok(res):
    return isinstance(res, dict) and bool(res.get('ok')) and bool(res.get('n_solids')) and bool(res.get('valid', True))


def make_tools(workdir, examples):
    return agent.Tools(workdir, allow_code=True, examples=examples)


def run_item(llm, item, workdir, examples, repairs=2, tok=None):
    """one item through the agent protocol; returns a per-item record"""
    tools = make_tools(workdir, examples)
    msgs = [{'role': 'system', 'content': agent.system_prompt(tools, agent.PROMPT_COMPACT)}]
    ctx, used = agent.retrieve(tools, item['prompt'])
    if ctx:
        msgs.append({'role': 'system', 'content': ctx})
    msgs.append({'role': 'user', 'content': item['prompt']})
    rec = {'id': item['id'], 'context': used, 'builds': [], 'built': False, 'pass_first': False, 'pass': False, 'turns': 0}
    t0 = time.time()
    for turn in range(1 + repairs):
        try:
            text = agent._strip_think(''.join(llm.stream(msgs)))
        except Exception as e:
            rec['error'] = f'{type(e).__name__}: {e}'[:300]
            break
        rec['turns'] += 1
        msgs.append({'role': 'assistant', 'content': text})
        call = agent.parse_tool_call(text)
        if not call:
            rec['final'] = text[:400]
            break
        if call['name'] == '__bad__':
            res = {'error': 'the tool block is not valid JSON: ' + call['raw'][:200] + ' - write it again as JSON'}
        else:
            res = tools.call(call['name'], call['args'])
        if call['name'] == 'cadquery_build':
            code = str((call.get('args') or {}).get('code', ''))
            ok, checks = item_pass(res, item['expect'])
            b = {'ok': bool(res.get('ok')) if isinstance(res, dict) else False, 'pass': ok, 'checks': checks,
                 'code_chars': len(code), 'code_tokens': len(tok.encode(code)) if tok else None,
                 'error': None if (isinstance(res, dict) and res.get('ok')) else
                 (f"{res.get('error_type', '')} {res.get('message', res.get('error', ''))}"[:300] if isinstance(res, dict) else str(res)[:300])}
            for k in ('bbox', 'volume', 'n_solids', 'valid'):
                if isinstance(res, dict) and k in res:
                    b[k] = res[k]
            rec['builds'].append(b)
            rec['built'] = rec['built'] or built_ok(res)
            if ok:
                rec['pass'] = True
                rec['pass_first'] = len(rec['builds']) == 1
                break
        msgs.append({'role': 'user', 'content': f"TOOL_RESULT {call['name']}: " + agent.compact_result(res)})
    rec['seconds'] = round(time.time() - t0, 2)
    return rec


def run_reference(item, workdir, ref_dir):
    """--oracle-reference: run the stored reference script through the same tool and scoring"""
    tools = make_tools(workdir, None)
    rec = {'id': item['id'], 'builds': [], 'built': False, 'pass_first': False, 'pass': False, 'turns': 1}
    t0 = time.time()
    path = os.path.join(ref_dir, item['id'] + '.py')
    if not os.path.exists(path):
        rec['error'] = 'no reference script ' + path
    else:
        code = open(path, encoding='utf-8').read()
        res = tools.call('cadquery_build', {'code': code, 'name': item['id']})
        ok, checks = item_pass(res, item['expect'])
        rec['builds'].append({'ok': bool(res.get('ok')), 'pass': ok, 'checks': checks, 'code_chars': len(code), 'code_tokens': None,
                              'error': None if res.get('ok') else f"{res.get('error_type', '')} {res.get('message', res.get('error', ''))}"[:300],
                              'volume': res.get('volume'), 'bbox': res.get('bbox')})
        rec.update(built=built_ok(res), pass_first=ok, **{'pass': ok})
    rec['seconds'] = round(time.time() - t0, 2)
    return rec


def summarize(details, repairs):
    n = len(details) or 1
    codes = [b for d in details for b in d['builds']]
    toks = [b['code_tokens'] for b in codes if b.get('code_tokens') is not None]
    s = {'n': len(details),
         'built_pct': round(100 * sum(d['built'] for d in details) / n, 1),
         'pass_first_pct': round(100 * sum(d['pass_first'] for d in details) / n, 1),
         f'pass_within_{1 + repairs}_pct': round(100 * sum(d['pass'] for d in details) / n, 1),
         'called_build_pct': round(100 * sum(bool(d['builds']) for d in details) / n, 1),
         'avg_code_chars': round(sum(b['code_chars'] for b in codes) / len(codes), 1) if codes else 0,
         'avg_code_tokens': round(sum(toks) / len(toks), 1) if toks else (round(sum(b['code_chars'] for b in codes) / len(codes) / 4, 1)
                                                                          if codes else 0),
         'avg_code_tokens_is_estimate': not toks,
         'seconds_per_item': round(sum(d['seconds'] for d in details) / n, 2)}
    return s


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[1], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--server', default='http://127.0.0.1:8080', help='OpenAI-compatible endpoint (llama-server, vLLM, ...)')
    ap.add_argument('--model', default='local')
    ap.add_argument('--local', help='score this model directly in Python (HF name or LoRA folder) instead of a server')
    ap.add_argument('--oracle-reference', metavar='DIR', help='run DIR/<id>.py reference solutions instead of a model (sanity check)')
    ap.add_argument('--data', default=DEFAULT_DATA)
    ap.add_argument('--out', default='cad_eval_result.json')
    ap.add_argument('--ids', help='comma-separated item ids to run')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--repairs', type=int, default=2, help='extra turns after the first reply (default 2 -> up to 3 tries)')
    ap.add_argument('--max-tokens', type=int, default=1500)
    ap.add_argument('--examples', help='CAD example folder for retrieval (default: the built-in library)')
    ap.add_argument('--no-examples', action='store_true', help='no retrieved CAD examples in the context')
    ap.add_argument('--workdir', help='where builds are written (default: a temp folder)')
    a = ap.parse_args(argv)

    rows = load(a.data, set(a.ids.split(',')) if a.ids else None, a.limit)
    work = a.workdir or tempfile.mkdtemp(prefix='sb_cadeval_')
    llm = tok = examples = None
    if not a.oracle_reference:
        if a.local:
            sys.path.insert(0, HERE)
            from evaluate import LocalModel
            llm = LocalModel(a.local, max_new_tokens=a.max_tokens)
            tok = getattr(llm, 'tok', None)
        else:
            llm = agent.LLM(a.server, a.model, temperature=0.0, max_tokens=a.max_tokens)
        if not a.no_examples:
            from shipbrain.examples import Examples
            examples = Examples(a.examples)
    details = []
    t0 = time.time()
    for i, it in enumerate(rows):
        wd = os.path.join(work, re.sub(r'[^A-Za-z0-9_\-]', '_', it['id']))
        rec = run_reference(it, wd, a.oracle_reference) if a.oracle_reference else run_item(llm, it, wd, examples, a.repairs, tok)
        details.append(rec)
        print(f"{i + 1}/{len(rows)} {it['id']:34s} {'PASS' if rec['pass'] else ('built' if rec['built'] else 'FAIL'):5s} "
              f"builds {len(rec['builds'])}  {rec['seconds']:.1f}s  total {time.time() - t0:.0f}s", flush=True)
    summary = summarize(details, a.repairs)
    summary['backend'] = ('oracle-reference ' + a.oracle_reference) if a.oracle_reference else (('local ' + a.local) if a.local else a.server)
    json.dump({'summary': summary, 'details': details}, open(a.out, 'w'), indent=1)
    print(json.dumps(summary, indent=1))
    print(f"-> the model builds {summary[f'pass_within_{1 + a.repairs}_pct']} % of {summary['n']} unseen parts correctly "
          f"({summary['pass_first_pct']} % first try); details -> {a.out}")
    return summary


if __name__ == '__main__':
    main()
