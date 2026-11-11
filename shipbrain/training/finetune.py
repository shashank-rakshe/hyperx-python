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
            d['_root'] = os.path.dirname(os.path.abspath(path))
            data.append(d)
    with_images = sum(1 for d in data if d.get('images'))
    cfg = dict(per_device_train_batch_size=2 if not with_images else 1, gradient_accumulation_steps=8 if not with_images else 16,
               num_train_epochs=float(os.environ.get('EPOCHS', 2)), learning_rate=float(os.environ.get('LR', 2e-4)), warmup_ratio=0.03,
               lr_scheduler_type='cosine', logging_steps=10, optim='adamw_8bit', weight_decay=0.01, seed=0, output_dir=a.out + '/ckpt',
               save_strategy='epoch', report_to='none')

    def sft_config(**kw):
        try:
            return SFTConfig(max_seq_length=max_len, **cfg, **kw)
        except TypeError:                                  # newer TRL: max_length
            return SFTConfig(max_length=max_len, **cfg, **kw)

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
