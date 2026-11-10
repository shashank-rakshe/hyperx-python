"""
Fine-tune a small open model on the ShipBrain data (QLoRA) and export a GGUF that runs on a CPU.

Run on a GPU once (free Google Colab T4 is enough for 1.7B-4B; ~1-3 h for 4000 samples x 2 epochs):
    pip install unsloth
    python training/make_dataset.py --n 4000 --out data/train.jsonl --eval-out data/eval.jsonl [--knowledge rules_index.json]
    python training/finetune.py --data data/train.jsonl --base unsloth/Qwen3-4B-Instruct-2507 --out shipbrain_model
Result: shipbrain_model/shipbrain-q4_k_m.gguf   (~2.5 GB for 4B, ~1.1 GB for 1.7B) -> copy to the workstation.

Which base model (CPU only, 16 GB RAM):
    unsloth/Qwen3-1.7B            fast on any CPU (~15-25 tokens/s), weaker reasoning
    unsloth/Qwen3-4B-Instruct-2507  good balance (default, ~6-12 tokens/s on 8 cores)
    unsloth/Qwen3-8B              best answers, ~3-6 tokens/s, needs ~6 GB RAM in q4
To continue from your existing Qwen3-VL ship model, pass its LoRA/merged folder as --base.

Env: EPOCHS, LR, MAX_LEN, LORA_R override the defaults.
"""
import argparse, json, os


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='data/train.jsonl', nargs='+')
    ap.add_argument('--base', default='unsloth/Qwen3-4B-Instruct-2507')
    ap.add_argument('--out', default='shipbrain_model')
    ap.add_argument('--quant', default='q4_k_m', help='GGUF quantisation: q4_k_m (small), q5_k_m, q8_0 (largest, best)')
    ap.add_argument('--no-gguf', action='store_true')
    a = ap.parse_args()

    from unsloth import FastLanguageModel
    from unsloth.chat_templates import train_on_responses_only
    from datasets import Dataset
    from trl import SFTTrainer, SFTConfig

    max_len = int(os.environ.get('MAX_LEN', 4096))
    model, tok = FastLanguageModel.from_pretrained(a.base, max_seq_length=max_len, load_in_4bit=True)
    model = FastLanguageModel.get_peft_model(
        model, r=int(os.environ.get('LORA_R', 32)), lora_alpha=int(os.environ.get('LORA_R', 32)), lora_dropout=0,
        target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'],
        use_gradient_checkpointing='unsloth', random_state=0)

    rows = []
    for path in (a.data if isinstance(a.data, list) else [a.data]):
        for line in open(path, encoding='utf-8'):
            d = json.loads(line)
            rows.append({'text': tok.apply_chat_template(d['messages'], tokenize=False)})
    rows = [r for r in rows if len(tok(r['text']).input_ids) <= max_len]
    print(len(rows), 'samples')
    ds = Dataset.from_list(rows)

    trainer = SFTTrainer(model=model, tokenizer=tok, train_dataset=ds, args=SFTConfig(
        dataset_text_field='text', max_seq_length=max_len, per_device_train_batch_size=2, gradient_accumulation_steps=8,
        num_train_epochs=float(os.environ.get('EPOCHS', 2)), learning_rate=float(os.environ.get('LR', 2e-4)), warmup_ratio=0.03,
        lr_scheduler_type='cosine', logging_steps=10, optim='adamw_8bit', weight_decay=0.01, seed=0, output_dir=a.out + '/ckpt',
        save_strategy='epoch', report_to='none'))
    # learn only the assistant turns (tool calls + answers), not the prompts / tool results
    trainer = train_on_responses_only(trainer, instruction_part='<|im_start|>user\n', response_part='<|im_start|>assistant\n')
    trainer.train()

    model.save_pretrained(a.out + '/lora')
    tok.save_pretrained(a.out + '/lora')
    if not a.no_gguf:
        model.save_pretrained_gguf(a.out, tok, quantization_method=a.quant)
        for f in os.listdir(a.out):
            if f.endswith('.gguf') and 'shipbrain' not in f:
                os.rename(os.path.join(a.out, f), os.path.join(a.out, f'shipbrain-{a.quant}.gguf' if a.quant.upper() in f.upper() else 'shipbrain-' + f))
        print('GGUF written to', a.out)


if __name__ == '__main__':
    main()
