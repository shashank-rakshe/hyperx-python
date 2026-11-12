"""
Tracing-mode training samples from real runs: thin-line sketches and pipe diagrams (-> centre-lines) and sheets with filled /
thick shapes (-> outlines), traced by the trace_drawing tool. Questions: no mode given (auto picks), "one line per stroke" /
"centre line" (mode centerline), "outline of the shapes" (mode outline).

    python training/centerline_tasks.py --n 60 --out training/data/centerline_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

AUTO = ['Make a DXF from my sketch {f}', 'Vectorise {f}', '{f} is a hand drawing - turn it into CAD lines', 'Sketch {f} ko DXF me convert karo',
        'Trace {f} for me, scale {s:g} mm per pixel', 'Can you digitise {f}?']
CENTER = ['Trace {f} with one line per stroke, not outlines', 'Centre-line trace {f}', 'I need the middle line of every pen stroke in {f}',
          'Centerline vectorise {f} - it is a thin line pipe diagram', '{f}: single lines please, no double outlines']
OUTLINE = ['Trace the outline of the filled shapes in {f}', 'Give me the outline of every black shape in {f}', 'Outline trace {f}']


def thin_sheet(r, path):
    from PIL import Image, ImageDraw, ImageFilter
    W, H = r.choice([(1600, 1100), (2000, 1400), (2400, 1600)])
    im = Image.new('L', (W, H), 255)
    d = ImageDraw.Draw(im)
    w = r.choice([3, 4, 5])
    for _ in range(r.randint(3, 8)):                         # pipe-diagram style runs
        x, y = r.randint(100, W - 300), r.randint(100, H - 300)
        pts = [(x, y)]
        for _ in range(r.randint(2, 4)):
            if len(pts) % 2:
                x = min(W - 60, max(60, x + r.choice([-1, 1]) * r.randint(150, 600)))
            else:
                y = min(H - 60, max(60, y + r.choice([-1, 1]) * r.randint(120, 500)))
            pts.append((x, y))
        d.line(pts, fill=0, width=w, joint='curve')
    for _ in range(r.randint(0, 3)):
        cx, cy, rr = r.randint(200, W - 200), r.randint(200, H - 200), r.randint(30, 90)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=0, width=w)
    im = im.rotate(r.uniform(-0.5, 0.5), fillcolor=255).filter(ImageFilter.GaussianBlur(r.uniform(0.5, 1.2)))
    px = im.load()
    for _ in range(int(W * H * r.uniform(0.0005, 0.003))):
        px[r.randrange(W), r.randrange(H)] = 0
    im.convert('RGB').save(path)


def solid_sheet(r, path):
    from PIL import Image, ImageDraw, ImageFilter
    W, H = r.choice([(1600, 1100), (2000, 1400)])
    im = Image.new('L', (W, H), 255)
    d = ImageDraw.Draw(im)
    for _ in range(r.randint(2, 5)):
        x0, y0 = r.randint(60, W - 500), r.randint(60, H - 400)
        d.rectangle([x0, y0, x0 + r.randint(150, 450), y0 + r.randint(100, 300)], fill=0)
    for _ in range(r.randint(0, 2)):
        cx, cy, rr = r.randint(250, W - 250), r.randint(250, H - 250), r.randint(60, 140)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=0)
    im.filter(ImageFilter.GaussianBlur(r.uniform(0.5, 1.0))).convert('RGB').save(path)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'centerline_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_cl_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []
    try:
        for i in range(a.n):
            kind = r.choice(['thin', 'thin', 'solid'])
            f = r.choice(['sketch', 'pipe_diagram', 'hand_drawing', 'scan', 'bracket_sketch']) + f'_{i:03d}.png'
            (thin_sheet if kind == 'thin' else solid_sheet)(r, os.path.join(work, f))
            s = r.choice([0.5, 1.0, 2.0])
            style = r.choice(['auto', 'auto', 'explicit'])
            args = {'file': f}
            if style == 'auto':
                q = r.choice(AUTO).format(f=f, s=s)
                if 'mm per pixel' in q:
                    args['scale'] = s
            elif kind == 'thin':
                q = r.choice(CENTER).format(f=f)
                args['mode'] = 'centerline'
            else:
                q = r.choice(OUTLINE).format(f=f)
                args['mode'] = 'outline'
            out = T.call('trace_drawing', args)
            if 'error' in out:
                continue
            if style == 'auto':
                ans = out['plain_english'] + (' I chose this mode myself because ' + (
                    'the pen strokes are thin: one line per stroke is cleaner than double outlines.' if kind == 'thin' else
                    'the sheet has filled shapes: their outlines are what you want.') + ' Tell me if you want the other mode.')
            else:
                ans = out['plain_english']
            rows.append({'task': 'trace_mode_' + kind, 'messages': [{'role': 'user', 'content': q},
                                                                  {'role': 'assistant', 'content': tool_block('trace_drawing', args)},
                                                                  result_msg('trace_drawing', out), {'role': 'assistant', 'content': ans}]})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked into the samples'
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    import collections
    print(a.out, len(rows), dict(collections.Counter(x['task'] for x in rows)))


if __name__ == '__main__':
    main()
