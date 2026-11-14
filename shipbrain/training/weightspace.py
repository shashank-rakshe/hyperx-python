"""
Weight-space tools for the ShipBrain model (open source: PyTorch + Transformers + PEFT + safetensors).

1. merge  - task arithmetic / adapter merging. Train one small LoRA per skill or per new repo (short, cheap runs), then
            fold them all into ONE model: same size and CPU speed as the base, all skills. Methods:
              linear  base + sum(w_i * delta_i)
              ties    trim each delta to its top-k % magnitudes, elect a sign per weight, average the agreeing values
              dare    randomly drop p % of each delta and rescale the rest by 1/(1-p), then add
            (task vectors: Ilharco et al. 2023; TIES: Yadav et al. 2023; DARE: Yu et al. 2024)
     python training/weightspace.py merge --base Qwen/Qwen3-1.7B --adapters lora_mesh lora_fe lora_repos --method ties --out merged

2. edit   - "weight-space programming" style repair (MIT CSAIL 2026 idea; own implementation): find a direction in the
            model's hidden states that separates BAD from GOOD behaviour (e.g. rambling / repeating / breaking the tool
            format vs. clean tool calls), project that direction out of the output matrices of selected layers with a
            strength alpha, and KEEP an edit only if the ShipBrain test set score goes up. Nothing is trained; the patch
            is small and saved separately so it can be undone. Like the original work, it can remove an obstacle but
            cannot add a skill the model does not have.
     python training/weightspace.py edit --model merged --good good.jsonl --bad bad.jsonl --eval data/eval.jsonl --out edited
"""
import argparse, json, os, random


# ====================================================================== 1. merging
def _load_state(path):
    from safetensors.torch import load_file
    import glob
    sd = {}
    for f in sorted(glob.glob(os.path.join(path, '*.safetensors'))):
        sd.update(load_file(f))
    if not sd:
        raise FileNotFoundError(f'no .safetensors in {path}')
    return sd


def lora_delta(adapter_dir):
    """LoRA folder (PEFT) -> {base weight name: delta tensor} = scale * B @ A"""
    import torch
    cfg = json.load(open(os.path.join(adapter_dir, 'adapter_config.json')))
    scale = cfg.get('lora_alpha', 16) / cfg.get('r', 16)
    sd = _load_state(adapter_dir)
    out = {}
    for k, A in sd.items():
        if '.lora_A.' not in k:
            continue
        B = sd[k.replace('.lora_A.', '.lora_B.')]
        name = k.replace('base_model.model.', '').replace('.lora_A.weight', '.weight')
        out[name] = (B.float() @ A.float()) * scale
    return out


def full_delta(model_dir, base_sd):
    """fine-tuned full model folder -> {name: finetuned - base}"""
    sd = _load_state(model_dir)
    return {k: v.float() - base_sd[k].float() for k, v in sd.items() if k in base_sd and v.shape == base_sd[k].shape}


def merge_deltas(deltas, method='ties', weights=None, density=0.2, drop=0.9, seed=0):
    import torch
    weights = weights or [1.0] * len(deltas)
    names = set().union(*[d.keys() for d in deltas])
    g = torch.Generator().manual_seed(seed)
    out = {}
    for n in names:
        ds = [(w, d[n]) for w, d in zip(weights, deltas) if n in d]
        if method == 'linear':
            out[n] = sum(w * t for w, t in ds)
        elif method == 'dare':
            acc = 0
            for w, t in ds:
                keep = (torch.rand(t.shape, generator=g) >= drop).float()
                acc = acc + w * t * keep / (1 - drop)
            out[n] = acc
        elif method == 'ties':
            trimmed = []
            for w, t in ds:
                k = max(1, int(density * t.numel()))
                thr = t.abs().flatten().kthvalue(t.numel() - k + 1).values
                trimmed.append(w * torch.where(t.abs() >= thr, t, torch.zeros_like(t)))
            T = torch.stack(trimmed)
            sign = torch.sign(T.sum(0))
            agree = (torch.sign(T) == sign) & (T != 0)
            cnt = agree.sum(0).clamp(min=1)
            out[n] = (T * agree).sum(0) / cnt
        else:
            raise ValueError('method: linear | ties | dare')
    return out


def merge(base, adapters, method='ties', weights=None, out='merged', density=0.2, drop=0.9):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    model = AutoModelForCausalLM.from_pretrained(base, torch_dtype=torch.float32)
    sd = model.state_dict()
    deltas = []
    for a in adapters:
        deltas.append(lora_delta(a) if os.path.exists(os.path.join(a, 'adapter_config.json')) else full_delta(a, sd))
    md = merge_deltas(deltas, method, weights, density, drop)
    hit = 0
    with torch.no_grad():
        for n, d in md.items():
            if n in sd:
                sd[n].add_(d.to(sd[n].dtype))
                hit += 1
    model.save_pretrained(out)
    AutoTokenizer.from_pretrained(base).save_pretrained(out)
    return {'merged_tensors': hit, 'adapters': len(adapters), 'method': method, 'out': out}


# ====================================================================== 2. evaluation-guided direction edits
def _hidden_means(model, tok, texts, layers):
    """mean last-token hidden state per layer for a list of texts"""
    import torch
    acc = {l: 0 for l in layers}
    with torch.no_grad():
        for t in texts:
            ids = tok(t, return_tensors='pt', truncation=True, max_length=1024)
            hs = model(**ids, output_hidden_states=True).hidden_states
            for l in layers:
                acc[l] = acc[l] + hs[l + 1][0, -1].float()
    return {l: acc[l] / max(1, len(texts)) for l in layers}


def find_direction(model, tok, good, bad, layers):
    g, b = _hidden_means(model, tok, good, layers), _hidden_means(model, tok, bad, layers)
    return {l: (b[l] - g[l]) / ((b[l] - g[l]).norm() + 1e-9) for l in layers}


def _out_mats(model, layer):
    m = model.model.layers[layer]
    return [m.self_attn.o_proj.weight, m.mlp.down_proj.weight]


def apply_edit(model, dirs, alpha):
    """W <- W - alpha * d d^T W on the matrices that WRITE into the residual stream: the model can no longer push its
    hidden state along the 'bad' direction d at those layers. Returns the patch (for undo / saving)."""
    import torch
    patch = {}
    with torch.no_grad():
        for l, d in dirs.items():
            d = d.to(model.dtype)
            for k, W in enumerate(_out_mats(model, l)):
                delta = -alpha * torch.outer(d, d @ W)
                W.add_(delta)
                patch[f'{l}.{k}'] = delta
    return patch


def undo(model, dirs, patch):
    import torch
    with torch.no_grad():
        for l in dirs:
            for k, W in enumerate(_out_mats(model, l)):
                W.sub_(patch[f'{l}.{k}'])


def score(model, tok, rows, max_new=200):
    """ShipBrain test score: right tool + exact arguments (tool turns) or bold numbers present (answers), plus brevity"""
    import sys, torch
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    from shipbrain import agent
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from evaluate import args_match
    ok, n, length = 0.0, 0, 0
    for d in rows:
        msgs = d['messages']
        idx = max((j for j, m in enumerate(msgs) if m['role'] == 'assistant' and '```tool' in m['content']), default=len(msgs) - 1)
        ids = tok.apply_chat_template(msgs[:idx], add_generation_prompt=True, return_tensors='pt')
        ids = ids['input_ids'] if not hasattr(ids, 'shape') else ids          # transformers 5 returns a dict
        with torch.no_grad():
            out = model.generate(input_ids=ids, max_new_tokens=max_new, do_sample=False)
        got = tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True)
        length += len(got)
        ref = agent.parse_tool_call(msgs[idx]['content'])
        gc = agent.parse_tool_call(got)
        if ref:
            ok += 0.5 * bool(gc and gc['name'] == ref['name']) + 0.5 * bool(gc and gc['name'] == ref['name'] and args_match(ref['args'], gc['args'])[0])
        n += 1
    return ok / max(1, n), length / max(1, n)


def edit(model_dir, good, bad, eval_rows, out, layers=None, alphas=(0.25, 0.5, 1.0)):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    tok = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForCausalLM.from_pretrained(model_dir, torch_dtype=torch.float32)
    model.eval()
    L = len(model.model.layers)
    layers = layers or sorted({L // 3, L // 2, (2 * L) // 3})
    dirs = find_direction(model, tok, good, bad, layers)
    base_s, base_len = score(model, tok, eval_rows)
    log = [{'edit': 'none', 'score': base_s, 'avg_chars': base_len}]
    best = (base_s, -base_len, None)
    for a in alphas:
        patch = apply_edit(model, dirs, a)
        s, ln = score(model, tok, eval_rows)
        log.append({'edit': f'alpha {a}', 'score': s, 'avg_chars': ln})
        if (s, -ln) > best[:2]:
            best = (s, -ln, a)
        undo(model, dirs, patch)
    if best[2] is not None:
        patch = apply_edit(model, dirs, best[2])
        model.save_pretrained(out)
        tok.save_pretrained(out)
        os.makedirs(out, exist_ok=True)
        torch.save({'layers': layers, 'alpha': best[2], 'dirs': dirs}, os.path.join(out, 'weightspace_patch.pt'))
    changed = sum(p.numel() for l in layers for p in _out_mats(model, l))
    total = sum(p.numel() for p in model.parameters())
    return {'kept': best[2] is not None, 'alpha': best[2], 'layers': layers, 'log': log,
            'touched_weights_pct': round(100 * changed / total, 3), 'out': out if best[2] is not None else None,
            'plain_english': ('Kept the edit with strength %s: test score %.3f -> %.3f, answers %.0f -> %.0f characters.'
                              % (best[2], base_s, best[0], base_len, -best[1])) if best[2] is not None else
                             'No edit improved the test score, so the model was left unchanged.'}


def _texts(path):
    rows = [json.loads(l) for l in open(path, encoding='utf-8')]
    return [r['text'] if 'text' in r else '\n'.join(m['content'] for m in r['messages']) for r in rows]


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    m = sub.add_parser('merge')
    m.add_argument('--base', required=True)
    m.add_argument('--adapters', nargs='+', required=True)
    m.add_argument('--weights', nargs='*', type=float)
    m.add_argument('--method', default='ties', choices=['linear', 'ties', 'dare'])
    m.add_argument('--density', type=float, default=0.2)
    m.add_argument('--drop', type=float, default=0.9)
    m.add_argument('--out', default='merged')
    e = sub.add_parser('edit')
    e.add_argument('--model', required=True)
    e.add_argument('--good', required=True, help='jsonl of good behaviour (clean tool calls / answers)')
    e.add_argument('--bad', required=True, help='jsonl of bad behaviour (rambling, repeating, broken tool format)')
    e.add_argument('--eval', required=True)
    e.add_argument('--limit', type=int, default=40)
    e.add_argument('--out', default='edited')
    a = ap.parse_args(argv)
    if a.cmd == 'merge':
        print(json.dumps(merge(a.base, a.adapters, a.method, a.weights, a.out, a.density, a.drop), indent=1))
    else:
        rows = [json.loads(l) for l in open(a.eval, encoding='utf-8')][:a.limit]
        r = edit(a.model, _texts(a.good), _texts(a.bad), rows, a.out)
        print(json.dumps({k: v for k, v in r.items()}, indent=1, default=str))


if __name__ == '__main__':
    main()
