"""
Fine-tune a small open model on the ShipBrain data (QLoRA) and export a GGUF that runs on a CPU.

Run on a GPU (free Kaggle / Colab 16 GB is enough; ~2-4 h for 4000 samples x 2 epochs on the 4B model):
    pip install unsloth
    python training/make_dataset.py --n 4000 --out data/train.jsonl --eval-out data/eval.jsonl [--knowledge rules_index.json]
    python training/finetune.py --data data/train.jsonl --out shipbrain_model
Result: shipbrain_model/shipbrain-q4_k_m.gguf (~2.5 GB) + shipbrain-mmproj-f16.gguf (~0.8 GB) -> copy both to the workstation.

Base model: FIXED in training/base_model.json (Qwen3-VL-4B-Instruct: text, tools, code and drawings in one model).
Samples may carry pictures: {"messages": [...], "images": ["page.png", ...]} -> the images go before the first user text.
Export: shipbrain-q4_k_m.gguf + shipbrain-mmproj-f16.gguf (the image part; llama.cpp loads both as one model).

Env: EPOCHS, LR, MAX_LEN, LORA_R override the defaults.
DPO (after the fine-tune, before the export): preference pairs from training/dpo_pairs.py in DPO_DATA
(default data/dpo_pairs.jsonl; DPO=0 skips it; DPO_BETA 0.1, DPO_LR 5e-6, DPO_EPOCHS 1). If the step fails for any
reason the fine-tuned model is kept and exported as usual.
"""
import argparse, json, os


def _vl_messages(d, root):
    """chat messages -> the content-list form of vision models; images (paths) go before the first user text"""
    from PIL import Image
    imgs = [Image.open(p if os.path.isabs(p) else os.path.join(root, p)).convert('RGB') for p in d.get('images', [])]
    out, first = [], True
    for m in d['messages']:
        content = [{'type': 'text', 'text': m['content']}]
        if m['role'] == 'user' and first and imgs:
            content = [{'type': 'image', 'image': im} for im in imgs] + content
            first = False
        out.append({'role': m['role'], 'content': content})
    return {'messages': out}


def _find_llama_cpp():
    import glob as _g, subprocess
    for d in [os.path.expanduser('~/.unsloth/llama.cpp'), 'llama.cpp', '/kaggle/working/llama.cpp'] + _g.glob('/**/llama.cpp', recursive=False):
        if os.path.exists(os.path.join(d, 'convert_hf_to_gguf.py')):
            return d
    d = os.path.abspath('llama.cpp')
    subprocess.run(['git', 'clone', '-q', '--depth', '1', 'https://github.com/ggml-org/llama.cpp', d], check=True)
    subprocess.run(['pip', '-q', 'install', 'gguf', 'sentencepiece', 'mistral-common'], check=False)
    return d


def _export_vision(model, proc, out, quant):
    """GGUF for a vision model: text part (quantised) + mmproj (image part). Unsloth first, llama.cpp converter as fallback"""
    import glob as _g, shutil as _sh, subprocess
    try:
        model.save_pretrained_gguf(out, proc, quantization_method=quant)
    except Exception as e:
        print('(Unsloth GGUF export failed, using the llama.cpp converter:', e, ')')
    have = _g.glob(out + '*/**/*.gguf', recursive=True) + _g.glob(out + '/*.gguf')
    text = [f for f in have if 'mmproj' not in os.path.basename(f).lower()]
    mm = [f for f in have if 'mmproj' in os.path.basename(f).lower()]
    if text and mm:
        return
    merged = out + '/merged'
    model.save_pretrained_merged(merged, proc, save_method='merged_16bit')
    conv = os.path.join(_find_llama_cpp(), 'convert_hf_to_gguf.py')
    if not mm:
        subprocess.run(['python', conv, merged, '--mmproj', '--outtype', 'f16', '--outfile', os.path.join(out, 'shipbrain-mmproj-f16.gguf')],
                       check=True)
    if not text:                                          # no llama-quantize needed: q8_0 straight from the converter
        subprocess.run(['python', conv, merged, '--outtype', 'q8_0', '--outfile', os.path.join(out, 'shipbrain-q8_0.gguf')], check=True)
    _sh.rmtree(merged, ignore_errors=True)


def make_config(cls, **kw):
    """a TRL / transformers config that works across versions: renamed settings are translated (warmup_ratio ->
    warmup_steps as a ratio, max_seq_length -> max_length) and settings this version does not know are left out"""
    import inspect
    names = set(inspect.signature(cls.__init__).parameters)
    if 'warmup_ratio' in kw and 'warmup_ratio' not in names and 'warmup_steps' in names:
        kw['warmup_steps'] = kw.pop('warmup_ratio')          # transformers 5: a float below 1 is a ratio of the steps
    if 'max_seq_length' in kw and 'max_seq_length' not in names and 'max_length' in names:
        kw['max_length'] = kw.pop('max_seq_length')
    dropped = sorted(k for k in kw if k not in names)
    for k in dropped:
        kw.pop(k)
    if dropped:
        print(f'{cls.__name__}: not in this version, left out:', dropped)
    return cls(**kw)


def run_dpo(model, proc, vision, path, max_len, out):
    """DPO after the fine-tune (TRL DPOTrainer; the LoRA model with its adapters switched off is the reference, so no
    second copy of the model is loaded). Pairs: training/dpo_pairs.py. Small learning rate, one epoch: it only nudges
    the model towards the chosen turns (tool calls, the tool's exact numbers, the caveats, the users' corrections)."""
    from datasets import Dataset
    from trl import DPOTrainer, DPOConfig
    try:
        from unsloth import PatchDPOTrainer
        PatchDPOTrainer()
    except Exception:
        pass
    tok = getattr(proc, 'tokenizer', proc)                 # vision models: the text part of the processor
    rows = []
    for line in open(path, encoding='utf-8'):
        d = json.loads(line)
        msgs = [{'role': m['role'], 'content': m['content'] if isinstance(m['content'], str) else json.dumps(m['content'])}
                for m in d['prompt']]
        prompt = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        end = tok.eos_token or ''
        rows.append({'prompt': prompt, 'chosen': d['chosen'] + end, 'rejected': d['rejected'] + end})
    limit = max_len * 3.2
    rows = [x for x in rows if len(x['prompt']) + max(len(x['chosen']), len(x['rejected'])) < limit]
    print(len(rows), 'DPO pairs')
    if not rows:
        return
    if vision:
        from unsloth import FastVisionModel
        FastVisionModel.for_training(model)
    kw = dict(beta=float(os.environ.get('DPO_BETA', 0.1)), learning_rate=float(os.environ.get('DPO_LR', 5e-6)),
              num_train_epochs=float(os.environ.get('DPO_EPOCHS', 1)), per_device_train_batch_size=1,
              gradient_accumulation_steps=8, warmup_ratio=0.1, lr_scheduler_type='linear', optim='adamw_8bit',
              logging_steps=10, seed=0, output_dir=out + '/dpo_ckpt', save_strategy='no', report_to='none')
    import torch
    if not torch.cuda.is_available():                      # CPU (tests): no bf16
        kw.update(use_cpu=True, bf16=False, fp16=False, optim='adamw_torch')
    cfg = make_config(DPOConfig, max_length=max_len, max_prompt_length=max_len - 768, **kw)
    try:
        t = DPOTrainer(model=model, ref_model=None, args=cfg, train_dataset=Dataset.from_list(rows), processing_class=tok)
    except TypeError:                                      # older TRL: tokenizer=
        t = DPOTrainer(model=model, ref_model=None, args=cfg, train_dataset=Dataset.from_list(rows), tokenizer=tok)
    t.train()
    print('DPO done:', {k: round(v, 4) for k, v in (t.state.log_history[-1] or {}).items() if isinstance(v, float)})


def main():
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from model_io import BASE, is_vision, load
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='data/train.jsonl', nargs='+')
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--out', default='shipbrain_model')
    ap.add_argument('--quant', default='q4_k_m', help='GGUF quantisation: q4_k_m (small), q5_k_m, q8_0 (largest, best)')
    ap.add_argument('--no-gguf', action='store_true')
    a = ap.parse_args()

    from trl import SFTTrainer, SFTConfig
    max_len = int(os.environ.get('MAX_LEN', 4096))
    vision = is_vision(a.base)
    model, tok, proc = load(a.base, max_len, train=True)
    r = int(os.environ.get('LORA_R', 32))
    data = []
    for path in (a.data if isinstance(a.data, list) else [a.data]):
        if not os.path.exists(path) or not os.path.getsize(path):
            continue
        for line in open(path, encoding='utf-8'):
            d = json.loads(line)
            if 'good' in d and not d['good']:              # the app's thumbs-down records: never imitate them (DPO uses them)
                continue
            if 'chosen' in d and 'rejected' in d:          # preference pairs belong to the DPO step, not here
                continue
            d['_root'] = os.path.dirname(os.path.abspath(path))
            data.append(d)
    with_images = sum(1 for d in data if d.get('images'))
    cfg = dict(per_device_train_batch_size=2 if not with_images else 1, gradient_accumulation_steps=8 if not with_images else 16,
               num_train_epochs=float(os.environ.get('EPOCHS', 2)), learning_rate=float(os.environ.get('LR', 2e-4)), warmup_ratio=0.03,
               lr_scheduler_type='cosine', logging_steps=10, optim='adamw_8bit', weight_decay=0.01, seed=0, output_dir=a.out + '/ckpt',
               save_strategy='epoch', report_to='none')

    def sft_config(**kw):
        return make_config(SFTConfig, max_seq_length=max_len, **cfg, **kw)

    if vision:
        from unsloth import FastVisionModel
        from unsloth.trainer import UnslothVisionDataCollator
        model = FastVisionModel.get_peft_model(model, finetune_vision_layers=with_images > 0, finetune_language_layers=True,
                                               finetune_attention_modules=True, finetune_mlp_modules=True, r=r, lora_alpha=r,
                                               lora_dropout=0, bias='none', random_state=0)
        rows = []
        for d in data:
            try:
                rows.append(_vl_messages(d, d['_root']))
            except Exception as e:
                print('(sample skipped:', e, ')')
        rows = [x for x in rows if sum(len(c.get('text', '')) for m in x['messages'] for c in m['content']) < max_len * 3.2]
        print(len(rows), 'samples', f'({with_images} with images)')
        FastVisionModel.for_training(model)
        try:                                               # learn only the assistant turns (tool calls + answers)
            coll = UnslothVisionDataCollator(model, proc, train_on_responses_only=True,
                                             instruction_part='<|im_start|>user\n', response_part='<|im_start|>assistant\n')
        except TypeError:
            coll = UnslothVisionDataCollator(model, proc)
        trainer = SFTTrainer(model=model, tokenizer=proc, data_collator=coll, train_dataset=rows,
                             args=sft_config(remove_unused_columns=False, dataset_text_field='',
                                             dataset_kwargs={'skip_prepare_dataset': True}))
    else:
        from unsloth import FastLanguageModel
        from unsloth.chat_templates import train_on_responses_only
        from datasets import Dataset
        model = FastLanguageModel.get_peft_model(
            model, r=r, lora_alpha=r, lora_dropout=0,
            target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'],
            use_gradient_checkpointing='unsloth', random_state=0)
        rows = [{'text': tok.apply_chat_template(d['messages'], tokenize=False)} for d in data if not d.get('images')]
        rows = [x for x in rows if len(tok(x['text']).input_ids) <= max_len]
        print(len(rows), 'samples')
        trainer = SFTTrainer(model=model, tokenizer=tok, train_dataset=Dataset.from_list(rows), args=sft_config(dataset_text_field='text'))
        trainer = train_on_responses_only(trainer, instruction_part='<|im_start|>user\n', response_part='<|im_start|>assistant\n')
    trainer.train()

    dpo = os.environ.get('DPO_DATA', 'data/dpo_pairs.jsonl')
    if os.environ.get('DPO', '1') != '0' and os.path.exists(dpo) and os.path.getsize(dpo):
        try:                                               # never lose the fine-tune because of this optional step
            run_dpo(model, proc if vision else tok, vision, dpo, max_len, a.out)
        except Exception as e:
            import traceback
            traceback.print_exc()
            print(f'DPO step skipped ({type(e).__name__}: {e}); the fine-tuned model is kept as it is')

    model.save_pretrained(a.out + '/lora')
    proc.save_pretrained(a.out + '/lora')
    if not a.no_gguf:
        import glob as _g, shutil as _sh
        if vision:
            _export_vision(model, proc, a.out, a.quant)
        else:
            model.save_pretrained_gguf(a.out, tok, quantization_method=a.quant)
        for f in _g.glob(a.out + '_gguf/**/*.gguf', recursive=True) + _g.glob(a.out + '/*/**/*.gguf', recursive=True):
            _sh.move(f, os.path.join(a.out, os.path.basename(f)))      # newer Unsloth writes into <out>_gguf/
        for f in os.listdir(a.out):
            if f.endswith('.gguf') and 'shipbrain' not in f:
                new = ('shipbrain-mmproj-f16.gguf' if 'mmproj' in f.lower() else
                       f'shipbrain-{a.quant}.gguf' if a.quant.upper() in f.upper() else 'shipbrain-' + f)
                os.rename(os.path.join(a.out, f), os.path.join(a.out, new))
        print('GGUF written to', a.out, sorted(f for f in os.listdir(a.out) if f.endswith('.gguf')))


if __name__ == '__main__':
    main()
