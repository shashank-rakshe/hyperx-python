"""
VTracer training samples from real runs: synthetic scanned drawing sheets (plate outlines, stiffener lines, holes,
frame ticks, title text, with blur, a slight rotation and scan dust) traced by VTracer through the trace_drawing tool.
Each question -> tool call -> result -> plain answer is written. Needs vtracer 1.0.0a4 + Pillow; the result is committed.

    python training/vtracer_tasks.py --n 30 --out training/data/vtracer_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

ASK = ['Convert this scanned drawing {f} to DXF', 'I only have a scan ({f}). Make a vector copy.', '{f} is a photo of an old drawing - trace it',
       'Scan {f} ko DXF me badlo', 'Vectorise {f}; the sheet is at {s:g} mm per pixel', 'Get lines out of the scanned PDF page {f}']


def sheet(r, path):
    from PIL import Image, ImageDraw, ImageFilter
    W, H = r.choice([(2000, 1400), (2400, 1600), (3000, 2000)])
    im = Image.new('L', (W, H), 255)
    d = ImageDraw.Draw(im)
    x0, y0, x1, y1 = int(W * 0.08), int(H * 0.1), int(W * 0.92), int(H * 0.85)
    d.rectangle([x0, y0, x1, y1], outline=0, width=r.choice([4, 6, 8]))
    for _ in range(r.randint(1, 4)):
        y = r.randint(y0 + 50, y1 - 50)
        d.line([x0, y, x1, y], fill=0, width=r.choice([3, 4, 5]))
    for _ in range(r.randint(0, 3)):
        cx, cy, rr = r.randint(x0 + 150, x1 - 150), r.randint(y0 + 150, y1 - 150), r.randint(40, 120)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=0, width=4)
    for x in range(x0 + 200, x1, r.choice([200, 300, 400])):
        d.line([x, y1, x, y1 + 60], fill=0, width=3)
    d.text((x0 + 40, y1 + 80), r.choice(['FR 40  PL 12', 'DECK 2  FB 150x12', 'BHD FR 55', 'WEB 400x12 / FL 150x15']), fill=0)
    im = im.rotate(r.uniform(-0.6, 0.6), fillcolor=255).filter(ImageFilter.GaussianBlur(r.uniform(0.6, 1.5)))
    px = im.load()
    for _ in range(int(W * H * r.uniform(0.002, 0.01))):
        px[r.randrange(W), r.randrange(H)] = 0
    im.convert('RGB').save(path)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=30)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'vtracer_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_vt_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []
    try:
        for i in range(a.n):
            f = r.choice(['scan', 'old_drawing', 'midship_section_scan', 'deck_plan_photo']) + f'_{i:03d}.png'
            sheet(r, os.path.join(work, f))
            s = r.choice([0.5, 1.0, 2.0, 2.5])
            q = r.choice(ASK).format(f=f, s=s)
            args = {'file': f}
            if 'mm per pixel' in q:
                args['scale'] = s
            out = T.call('trace_drawing', args)
            if 'error' in out:
                continue
            ans = out['plain_english'] + (' Open the DXF in AutoCAD / LibreCAD; to compare it with another revision, use '
                                          'compare_drawings on the two scans (it overlays them).')
            rows.append({'task': 'vtracer', 'messages': [{'role': 'user', 'content': q},
                                                         {'role': 'assistant', 'content': tool_block('trace_drawing', args)},
                                                         result_msg('trace_drawing', out), {'role': 'assistant', 'content': ans}]})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked into the samples'
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
