"""
cad3dify (copied whole, MIT) -> vision training samples in cad3dify's OWN format, so ShipBrain's model is good at the
exact job cad3dify gives it (shipbrain.cad3dify runs cad3dify with ShipBrain's own model):

  generate   cad3dify's generator prompt (taken from its own class) + a three-view drawing of a verified CAD example
             (front / top / side with overall dimensions) -> that example's CadQuery code, exporting to ${output_filename}
  refine     cad3dify's refiner prompt with a WRONG version of the code (one dimension changed, still builds) + the
             drawing next to cad3dify's own 3D render of the wrong part -> the correct code

The examples are ShipBrain's verified library (examples/cadquery: every one builds and matches its record).

    python training/cad3dify_tasks.py --out data/cad3dify_train.jsonl --img-dir data/cad3dify_images
"""
import argparse, json, os, random, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import cad3dify, examples   # noqa: E402
from shipbrain.cadview import model_segments   # noqa: E402

PX = 1280


def build(code):
    ns = {}
    exec(compile(code, '<example>', 'exec'), ns)
    return ns['result']


def three_view(shape, png, title=''):
    """a simple 2D CAD sheet: front, top and side views with overall dimensions"""
    from PIL import Image, ImageDraw
    import cadquery as cq
    bb = (cq.Compound.makeCompound([v for v in shape.vals() if isinstance(v, cq.Shape)]) if isinstance(shape, cq.Workplane) else shape).BoundingBox()
    L, B, H = bb.xlen, bb.ylen, bb.zlen
    W, Hh = 1600, 1100
    im = Image.new('RGB', (W, Hh), 'white')
    d = ImageDraw.Draw(im)
    cells = {'front': (60, 80, 760, 520), 'side': (840, 80, 1540, 520), 'top': (60, 600, 760, 1040)}
    ext = {'front': (L, H), 'top': (L, B), 'side': (B, H)}
    s = min(min((c[2] - c[0]) / max(ext[v][0], 1e-6), (c[3] - c[1]) / max(ext[v][1], 1e-6)) for v, c in cells.items()) * 0.8
    for view, (x0, y0, x1, y1) in cells.items():
        segs = model_segments(shape, view)
        if not segs:
            continue
        us = [p[0] for sg in segs for p in sg]
        vs = [p[1] for sg in segs for p in sg]
        cu, cv = (min(us) + max(us)) / 2, (min(vs) + max(vs)) / 2
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        for a, b in segs:
            d.line([(cx + (a[0] - cu) * s, cy - (a[1] - cv) * s), (cx + (b[0] - cu) * s, cy - (b[1] - cv) * s)], fill='black', width=2)
        w, h = (max(us) - min(us)), (max(vs) - min(vs))
        left, right, top, bot = cx - w * s / 2, cx + w * s / 2, cy - h * s / 2, cy + h * s / 2
        d.line([(left, bot + 25), (right, bot + 25)], fill='black', width=1)                 # horizontal dimension
        d.text(((left + right) / 2 - 20, bot + 30), f'{w:g}', fill='black')
        d.line([(right + 25, top), (right + 25, bot)], fill='black', width=1)               # vertical dimension
        d.text((right + 30, (top + bot) / 2 - 6), f'{h:g}', fill='black')
        d.text((x0, y0 - 30), view.upper() + ' VIEW', fill='black')
    d.rectangle([5, 5, W - 6, Hh - 6], outline='black', width=2)
    d.text((840, 1000), (title or 'PART')[:80] + '   units: mm', fill='black')
    im.save(png)
    return png


def _with_export(code):
    code = code if 'import cadquery as cq' in code else 'import cadquery as cq\n' + code
    code = '\n'.join(ln for ln in code.splitlines() if not ln.startswith(('# Prompt:', '# Tags:')))
    return code.rstrip() + '\ncq.exporters.export(result, "${output_filename}")'


def mutate(code, r):
    """change one dimension (a number in an assignment) so the part changes but still builds -> (wrong code, what)"""
    nums = [m for m in re.finditer(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])', code)
            if not code[max(0, m.start() - 12):m.start()].rstrip().endswith(('range(', 'n_solids')) and float(m.group(1)) > 2]
    r.shuffle(nums)
    for m in nums[:8]:
        v = float(m.group(1))
        nv = round(v * r.choice([0.5, 0.6, 0.75, 1.3, 1.5, 2.0]), 1)
        nv = int(nv) if nv == int(nv) else nv
        if nv == v:
            continue
        wrong = code[:m.start()] + str(nv) + code[m.end():]
        yield wrong, f'{m.group(1)} -> {nv}'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='data/cad3dify_train.jsonl')
    ap.add_argument('--img-dir', default='data/cad3dify_images')
    ap.add_argument('--refine-per-example', type=int, default=2)
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    gen_prompt, ref_prompt = cad3dify.prompts()
    from cad3dify.render import render_and_export_image
    from cad3dify.image import ImageData
    import cadquery as cq
    from PIL import Image
    os.makedirs(a.img_dir, exist_ok=True)
    out_dir = os.path.dirname(os.path.abspath(a.out))
    tmp = tempfile.mkdtemp(prefix='sb_c3d_')
    rows = []

    def small(src, dst):
        im = Image.open(src).convert('RGB')
        k = PX / max(im.size)
        if k < 1:
            im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
        im.save(dst)
        return os.path.relpath(dst, out_dir)

    for e in examples.Examples().items:
        try:
            shape = build(e['code'])
        except Exception as ex:
            print('skip', e['name'], ex)
            continue
        drawing = three_view(shape, os.path.join(tmp, e['name'] + '_drawing.png'), e['name'].replace('_', ' ').upper())
        good = _with_export(e['code'])
        img = small(drawing, os.path.join(a.img_dir, f"c3d_{e['name']}.png"))
        rows.append({'task': 'cad3dify_generate', 'images': [img], 'messages': [
            {'role': 'user', 'content': gen_prompt}, {'role': 'assistant', 'content': f'```python\n{good}\n```'}]})
        vol = shape.val().Volume() if hasattr(shape, 'val') else shape.Volume()
        made = 0
        for wrong, what in mutate(e['code'], r):
            if made >= a.refine_per_example:
                break
            try:
                ws = build(wrong)
                wv = ws.val().Volume()
            except Exception:
                continue
            if abs(wv - vol) < 0.02 * abs(vol):
                continue
            step = os.path.join(tmp, f"{e['name']}_w{made}.step")
            cq.exporters.export(ws, step)
            rend = os.path.join(tmp, f"{e['name']}_w{made}.png")
            try:
                render_and_export_image(step, rend)
            except Exception as ex:
                print('render failed', e['name'], ex)
                continue
            merged = ImageData.load_from_file(drawing).merge(ImageData.load_from_file(rend))   # cad3dify's own side-by-side
            mp = os.path.join(tmp, f"{e['name']}_m{made}.png")
            import base64
            open(mp, 'wb').write(base64.b64decode(merged.data))
            img2 = small(mp, os.path.join(a.img_dir, f"c3d_{e['name']}_ref{made}.png"))
            rows.append({'task': 'cad3dify_refine', 'images': [img2], 'what_was_wrong': what, 'messages': [
                {'role': 'user', 'content': ref_prompt(_with_export(wrong))}, {'role': 'assistant', 'content': f'```python\n{good}\n```'}]})
            made += 1
    with open(a.out, 'w', encoding='utf-8') as f:
        for x in rows:
            f.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples', sum(x['task'] == 'cad3dify_refine' for x in rows), 'refine')


if __name__ == '__main__':
    main()
