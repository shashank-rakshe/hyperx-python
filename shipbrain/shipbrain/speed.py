"""
Speed planner for running ShipBrain's model on a CPU (method from HuggingArch, MIT, https://github.com/shenh10/HuggingArch:
cost from the architecture + a roofline bound by the hardware, calibrated by measurement; here for CPUs, not GPUs).

Two different limits decide how fast the model feels:
  reading  (prompt, retrieved knowledge, images) - compute bound: ~2 x parameters FLOPs per token
  writing  (each answer token)                   - memory bound: every token reads all weights + the KV cache
So the levers are: fewer NEW tokens to read (prompt cache, knowledge at the end, smaller images, short retrieval) and
fewer bytes per written token (4-bit weights, 8-bit KV cache, draft model, GPU layers).

    python -m shipbrain.speed [--model shipbrain-q4_k_m.gguf] [--mmproj shipbrain-mmproj-f16.gguf] [--ctx 8192] [--gpu-mb 4096]
"""
import argparse, math, os, struct, time

import numpy as np

# the fixed base model when no GGUF is given (Qwen3-VL-4B-Instruct, text part; see training/base_model.json)
DEFAULT = {'arch': 'qwen3vl', 'layers': 36, 'embd': 2560, 'heads': 32, 'kv_heads': 8, 'head_dim': 128, 'params': 4.0e9,
           'weights_bytes': 2.5e9, 'vision_params': 0.42e9, 'patch': 16, 'merge': 2}
BPW = {0: 32, 1: 16, 2: 4.5, 3: 5, 7: 8.5, 8: 5.5, 10: 3.35, 12: 4.0, 14: 4.85, 15: 4.85, 16: 5.7, 17: 5.7, 18: 6.6}  # GGUF file types


# ------------------------------------------------------------------ GGUF metadata (header only, no weights read)
def gguf_meta(path):
    """{key: value} of a GGUF file's metadata (strings, numbers; arrays skipped)"""
    out = {}
    with open(path, 'rb') as f:
        if f.read(4) != b'GGUF':
            raise ValueError(f'{path} is not a GGUF file')
        ver, = struct.unpack('<I', f.read(4))
        n_t, n_kv = struct.unpack('<QQ', f.read(16)) if ver >= 2 else struct.unpack('<II', f.read(8))
        fmt = {0: 'B', 1: 'b', 2: 'H', 3: 'h', 4: 'I', 5: 'i', 6: 'f', 7: '?', 10: 'Q', 11: 'q', 12: 'd'}

        def rstr():
            n, = struct.unpack('<Q', f.read(8))
            return f.read(n).decode('utf-8', 'replace')

        def rval(t):
            if t == 8:
                return rstr()
            if t == 9:
                et, n = struct.unpack('<IQ', f.read(12))
                if et in fmt:
                    f.seek(n * struct.calcsize(fmt[et]), 1)
                else:
                    for _ in range(n):
                        rval(et)
                return None
            return struct.unpack('<' + fmt[t], f.read(struct.calcsize(fmt[t])))[0]
        for _ in range(n_kv):
            k = rstr()
            t, = struct.unpack('<I', f.read(4))
            v = rval(t)
            if v is not None:
                out[k] = v
    out['_file_bytes'] = os.path.getsize(path)
    return out


def model_info(path=None, mmproj=None):
    if not path:
        return dict(DEFAULT, name='Qwen3-VL-4B-Instruct (fixed base, q4_k_m)')
    m = gguf_meta(path)
    a = m.get('general.architecture', 'llama')
    g = lambda k, d=None: m.get(f'{a}.{k}', d)
    embd, heads = g('embedding_length', 2560), g('attention.head_count', 32)
    bpw = BPW.get(m.get('general.file_type', 15), 4.85)
    info = {'arch': a, 'layers': g('block_count', 36), 'embd': embd, 'heads': heads, 'kv_heads': g('attention.head_count_kv', heads),
            'head_dim': g('attention.key_length', embd // heads), 'weights_bytes': m['_file_bytes'],
            'params': m['_file_bytes'] * 8 / bpw, 'name': m.get('general.name', os.path.basename(path)), 'patch': 16, 'merge': 2,
            'vision_params': 0.0}
    if mmproj and os.path.exists(mmproj):
        mm = gguf_meta(mmproj)
        info['vision_params'] = mm['_file_bytes'] / 2                     # f16 = 2 bytes per parameter
        info['patch'] = mm.get('clip.vision.patch_size', 16)
        info['merge'] = mm.get('clip.vision.spatial_merge_size', 2) or 2
    return info


# ------------------------------------------------------------------ the machine
def bench_cpu(mb=256):
    """memory bandwidth (GB/s, read + write of a large array) and matrix compute (GFLOP/s, float32 BLAS)"""
    from concurrent.futures import ThreadPoolExecutor
    try:
        import psutil
        cores = psutil.cpu_count(logical=False) or os.cpu_count()
    except ImportError:
        cores = max(1, (os.cpu_count() or 2) // 2)
    a = np.ones(mb * 2 ** 20 // 8)
    b = np.empty_like(a)
    parts = np.array_split(np.arange(a.size), cores)                       # all cores, like llama.cpp
    sl = [(p[0], p[-1] + 1) for p in parts]

    def cp(r):
        np.copyto(b[r[0]:r[1]], a[r[0]:r[1]])
    with ThreadPoolExecutor(cores) as ex:
        list(ex.map(cp, sl))
        t = time.perf_counter()
        for _ in range(4):
            list(ex.map(cp, sl))
        bw = 4 * 2 * a.nbytes / (time.perf_counter() - t) / 1e9
    n = 1536
    x = np.random.rand(n, n).astype(np.float32)
    x @ x
    t = time.perf_counter()
    for _ in range(4):
        x @ x
    gflops = 4 * 2 * n ** 3 / (time.perf_counter() - t) / 1e9
    return {'bandwidth_GBs': round(bw, 1), 'gflops': round(gflops, 1), 'physical_cores': cores}


# ------------------------------------------------------------------ the estimate (roofline + efficiency factors)
def image_tokens(px_long, aspect=1.414, patch=16, merge=2):
    w, h = px_long, px_long / aspect
    return int(math.ceil(w / (patch * merge)) * math.ceil(h / (patch * merge)))


def estimate(info, hw, ctx=8192, kv_bits=8, draft=True, gpu_mb=0, rag_tokens=450, image_px=1024, gpu_bw=100.0):
    """predicted reading / writing speed and waiting times; efficiencies are typical llama.cpp CPU values"""
    kv_per_token = 2 * info['layers'] * info['kv_heads'] * info['head_dim'] * kv_bits / 8          # bytes, K + V
    eff_bw = hw['bandwidth_GBs'] * 1e9 * 0.75
    gpu_share = 0.0
    if gpu_mb:
        fit = max(0.0, gpu_mb * 1e6 * 0.85 - kv_per_token * ctx)               # leave room for the KV cache
        gpu_share = min(1.0, fit / info['weights_bytes'])
    cpu_bytes = info['weights_bytes'] * (1 - gpu_share)

    def write_speed(used_ctx):                     # CPU part from RAM + GPU part from the card's memory (old 4 GB card ~100 GB/s)
        gpu_bytes = info['weights_bytes'] * gpu_share + kv_per_token * used_ctx * gpu_share
        t = (cpu_bytes + kv_per_token * used_ctx * (1 - gpu_share)) / eff_bw + gpu_bytes / (gpu_bw * 1e9 * 0.7) + (0.002 if gpu_share else 0)
        return 1 / t
    # reading: llama.cpp's quantised matmuls run near the float32 BLAS rate on x86 (AVX2 / AVX-512); GPU share is ~free
    cpu_read = hw['gflops'] * 1e9 * 0.8 / (2 * info['params'])
    read_tps = 1 / ((1 - gpu_share) / cpu_read + gpu_share / 1500.0)       # an old card reads ~1500 tokens/s of a 4B model
    img_tok = image_tokens(image_px, patch=info['patch'], merge=info['merge'])
    vision_s = (2 * info['vision_params'] * img_tok * info['merge'] ** 2) / (hw['gflops'] * 1e9 * 0.6) if info['vision_params'] else 0
    w_short, w_long = write_speed(1500), write_speed(ctx * 0.8)
    spec = 1.6 if draft else 1.0                                              # typical gain with a fine-tuned draft model
    return {'kv_cache_MB_full_ctx': round(kv_per_token * ctx / 1e6), 'gpu_share_of_weights': round(gpu_share, 2),
            'write_tokens_per_s_short_chat': round(w_short * spec, 1), 'write_tokens_per_s_long_chat': round(w_long * spec, 1),
            'read_tokens_per_s': round(read_tps), 'wait_new_question_s': round(rag_tokens / read_tps + 0.3, 1),
            'wait_first_question_s': round((900 + rag_tokens) / read_tps, 1),
            'image_tokens': img_tok, 'wait_image_s': round(img_tok / read_tps + vision_s, 1) if info['vision_params'] or True else None}


def advice(info, hw, est, gpu_mb):
    tips = [f"threads: -t {hw['physical_cores']} (physical cores; extra hyper-threads slow the CPU path down)",
            'flash attention + 8-bit KV cache: -fa on -ctk q8_0 -ctv q8_0 (halves the bytes read per token from the cache; '
            'ShipBrain sets these by itself and drops them if your llama-server is too old)',
            'prompt cache: ShipBrain keeps the system prompt + earlier turns as one fixed prefix and adds the retrieved knowledge '
            'at the end, so each turn only reads its new tokens',
            f"draft model: --draft shipbrain-draft-q8_0.gguf (about 1.5-2x faster writing, same answers)"]
    if gpu_mb:
        tips.append(f"GPU ({gpu_mb} MB): {int(est['gpu_share_of_weights'] * 100)} % of the weights fit next to an 8-bit KV cache; "
                    "--gpu auto puts them there")
    if est['wait_image_s'] and est['wait_image_s'] > 20:
        tips.append(f"pictures: a {est['image_tokens']}-token image costs ~{est['wait_image_s']} s to read; look() sends 1024 px "
                    "(use crops of the part you need for detail; asking several questions about the same picture reuses the cache)")
    if est['write_tokens_per_s_long_chat'] < 0.6 * est['write_tokens_per_s_short_chat']:
        tips.append('long chats slow writing down (the KV cache grows): ShipBrain folds old turns into notes at the context limit; '
                    'keep --ctx 8192 unless you need more')
    return tips


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--model')
    ap.add_argument('--mmproj')
    ap.add_argument('--ctx', type=int, default=8192)
    ap.add_argument('--gpu-mb', type=int, default=0)
    ap.add_argument('--gpu-bw', type=float, default=100.0, help='graphics card memory bandwidth, GB/s (old 4 GB cards ~80-200)')
    ap.add_argument('--no-draft', action='store_true')
    a = ap.parse_args(argv)
    info = model_info(a.model, a.mmproj)
    hw = bench_cpu()
    est = estimate(info, hw, ctx=a.ctx, draft=not a.no_draft, gpu_mb=a.gpu_mb, gpu_bw=a.gpu_bw)
    print(f"model: {info['name']}: {info['layers']} layers, {info['params'] / 1e9:.1f} B parameters, "
          f"{info['weights_bytes'] / 1e9:.2f} GB of weights")
    print(f"this PC: memory {hw['bandwidth_GBs']} GB/s, compute {hw['gflops']} GFLOP/s, {hw['physical_cores']} physical cores")
    for k, v in est.items():
        print(f'  {k:32s} {v}')
    print('fastest settings:')
    for t in advice(info, hw, est, a.gpu_mb):
        print('  -', t)
    return est


if __name__ == '__main__':
    main()
