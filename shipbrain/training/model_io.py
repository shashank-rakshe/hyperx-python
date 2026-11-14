"""
One place that loads the base model for training and scoring, text-only or vision (Qwen3-VL), the same way everywhere.

    from model_io import BASE, DRAFT, is_vision, load
    model, tok, proc = load(name, max_len, train=True)    # tok = text tokenizer, proc = processor (vision) or tok
The fixed base model is in training/base_model.json.
"""
import json, os

_CFG = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'base_model.json')))
BASE, DRAFT = _CFG['base'], _CFG.get('draft', '')


def is_vision(name):
    """a vision model: its name (or the folder it was saved from) says VL"""
    n = str(name)
    if '-VL' in n.upper().replace('_', '-') or 'VISION' in n.upper():
        return True
    cfg = os.path.join(n, 'adapter_config.json') if os.path.isdir(n) else None
    if cfg and os.path.exists(cfg):
        base = json.load(open(cfg)).get('base_model_name_or_path', '')
        return '-VL' in base.upper()
    return False


def load(name, max_len=4096, train=True):
    if is_vision(name):
        from unsloth import FastVisionModel
        model, proc = FastVisionModel.from_pretrained(name, load_in_4bit=True, use_gradient_checkpointing='unsloth' if train else False)
        if not train:
            FastVisionModel.for_inference(model)
        return model, getattr(proc, 'tokenizer', proc), proc
    from unsloth import FastLanguageModel
    model, tok = FastLanguageModel.from_pretrained(name, max_seq_length=max_len, load_in_4bit=True)
    if not train:
        FastLanguageModel.for_inference(model)
    return model, tok, tok
