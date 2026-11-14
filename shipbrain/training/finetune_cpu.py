"""
Fine-tune WITHOUT a GPU (any PC, no account): plain PyTorch + Hugging Face Transformers + PEFT LoRA, all open source.

It is slow: practical only for small models. Rough guide on an 8-core desktop:
    Qwen3-0.6B, 1000 samples x 1 epoch  -> several hours
    Qwen3-1.7B, 1000 samples x 1 epoch  -> about a day (leave it running overnight / over a weekend)
For bigger models / more data use the free Kaggle or Colab GPU (training/kaggle_run.py, ShipBrain_train_colab.ipynb).

    pip install torch transformers peft
    python training/finetune_cpu.py --data data/train.jsonl --base Qwen/Qwen3-0.6B --out shipbrain_cpu --max-samples 1000
Then make the CPU model file with llama.cpp (open source, MIT):
    python llama.cpp/convert_hf_to_gguf.py shipbrain_cpu/merged --outfile shipbrain.gguf --outtype q8_0
"""
import argparse, json, math, os, random, time


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='data/train.jsonl')
    ap.add_argument('--base', default='Qwen/Qwen3-0.6B')
    ap.add_argument('--out', default='shipbrain_cpu')
    ap.add_argument('--max-samples', type=int, default=1000)
    ap.add_argument('--max-len', type=int, default=3072)
    ap.add_argument('--epochs', type=float, default=1.0)
    ap.add_argument('--lr', type=float, default=2e-4)
    ap.add_argument('--rank', type=int, default=16)
    ap.add_argument('--grad-accum', type=int, default=8)
    ap.add_argument('--threads', type=int, default=0)
    ap.add_argument('--save-every', type=int, default=50, help='optimizer steps between checkpoints (resume after a stop)')
    a = ap.parse_args(argv)

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from peft import LoraConfig, get_peft_model, PeftModel
    if a.threads:
        torch.set_num_threads(a.threads)
    tok = AutoTokenizer.from_pretrained(a.base)
    model = AutoModelForCausalLM.from_pretrained(a.base, torch_dtype=torch.float32)
    lora_dir = os.path.join(a.out, 'lora')
    if os.path.isdir(lora_dir):                                    # resume
        model = PeftModel.from_pretrained(model, lora_dir, is_trainable=True)
        print('resumed from', lora_dir)
    else:
        model = get_peft_model(model, LoraConfig(r=a.rank, lora_alpha=a.rank, lora_dropout=0.0, task_type='CAUSAL_LM',
                                                 target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj']))
    model.print_trainable_parameters()

    # tokenise: loss only on assistant turns (the tool calls and answers), never on prompts / tool results
    rows = [json.loads(l) for l in open(a.data, encoding='utf-8')]
    random.Random(0).shuffle(rows)
    samples = []
    for r in rows:
        msgs = r['messages']
        ids, labels = [], []
        for i in range(len(msgs)):
            full = tok.apply_chat_template(msgs[:i + 1], tokenize=False)
            prev = tok.apply_chat_template(msgs[:i], tokenize=False) if i else ''
            piece = tok(full[len(prev):], add_special_tokens=False).input_ids
            ids += piece
            labels += piece if msgs[i]['role'] == 'assistant' else [-100] * len(piece)
        if len(ids) <= a.max_len and any(x != -100 for x in labels):
            samples.append((ids, labels))
        if len(samples) >= a.max_samples:
            break
    print(len(samples), 'samples')
    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=a.lr)
    total = math.ceil(len(samples) * a.epochs / a.grad_accum)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / 10) * max(0.05, 1 - s / max(1, total)))
    model.train()
    step, t0, run = 0, time.time(), 0.0
    order = [samples[i % len(samples)] for i in range(int(len(samples) * a.epochs))]
    for k, (ids, labels) in enumerate(order, 1):
        x = torch.tensor([ids])
        y = torch.tensor([labels])
        loss = model(input_ids=x, labels=y).loss / a.grad_accum
        loss.backward()
        run += loss.item()
        if k % a.grad_accum == 0 or k == len(order):
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            opt.zero_grad()
            step += 1
            el = time.time() - t0
            print(f'step {step}/{total} loss {run:.4f}  {el / 60:.1f} min, ~{el / step * (total - step) / 3600:.1f} h left', flush=True)
            run = 0.0
            if step % a.save_every == 0:
                model.save_pretrained(lora_dir)
    os.makedirs(a.out, exist_ok=True)
    model.save_pretrained(lora_dir)
    merged = model.merge_and_unload()
    merged.save_pretrained(os.path.join(a.out, 'merged'))
    tok.save_pretrained(os.path.join(a.out, 'merged'))
    print('done ->', os.path.join(a.out, 'merged'), '(convert to GGUF with llama.cpp convert_hf_to_gguf.py)')


if __name__ == '__main__':
    main()
