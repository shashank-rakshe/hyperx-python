"""
Rhino .3dm training samples from real conversions: random ship-like Rhino models are written with McNeel's rhino3dm
(plates as boxes, pipes as cylinders, L / T / flat-bar stiffeners as extruded profiles, outlines as curves, on named
layers, in mm or m), read back by ShipBrain's own reader through the native_cad / file_info tools, and each
question -> tool call -> result -> plain answer is written. Needs rhino3dm + cadquery (the result is committed).

    python training/rhino_tasks.py --n 60 --out training/data/rhino_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

ASK = ['Import {f}', 'I made this in Rhino: {f}. Convert it to STEP.', 'What is in the Rhino file {f}?',
       '{f} ko open karke STEP banao', 'Read {f} and tell me the solids and layers', 'Can you use my Rhino model {f} for FEA?']


def model(r, path):
    import rhino3dm as R
    m = R.File3dm()
    unit, k = r.choice([('Millimeters', 1.0), ('Millimeters', 1.0), ('Meters', 1000.0)])
    m.Settings.ModelUnitSystem = getattr(R.UnitSystem, unit)
    lay = {}
    for name in r.sample(['Deck', 'Bulkhead', 'Shell', 'Stiffeners', 'Girders', 'Piping', 'Outline'], r.randint(2, 4)):
        L = R.Layer()
        L.Name = name
        lay[name] = m.Layers.Add(L)
    names = list(lay)

    def attr(name):
        a = R.ObjectAttributes()
        a.LayerIndex = lay[name]
        return a
    for _ in range(r.randint(1, 3)):                                     # plates
        L, B, t = r.choice([2000, 3000, 4000]), r.choice([1000, 1500, 2000]), r.choice([8, 10, 12, 15])
        x0 = r.choice([0, 500, 1000])
        m.Objects.AddBrep(R.Brep.CreateFromBox(R.Box(R.BoundingBox(R.Point3d(x0 / k, 0, 0), R.Point3d((x0 + L) / k, B / k, t / k)))),
                          attr(r.choice(names)))
    for _ in range(r.randint(0, 3)):                                     # stiffener profiles (extruded sections)
        h, tw, b, tf = r.choice([(200, 10, 90, 14), (250, 11, 90, 16), (150, 10, 0, 0), (300, 12, 100, 15)])
        L = r.choice([1500, 2000, 3000])
        y = r.choice([300, 600, 900])
        pts = [(0, 0), (tw, 0), (tw, h - tf), (b, h - tf), (b, h), (0, h)] if b else [(0, 0), (tw, 0), (tw, h), (0, h)]
        pl = R.Polyline([R.Point3d(0, (y + px) / k, (12 + py) / k) for px, py in pts] + [R.Point3d(0, y / k, 12 / k)])
        crv = pl.ToNurbsCurve()
        ex = R.Extrusion.Create(crv, -L / k, True)
        if ex:
            ex.Translate(R.Vector3d(0, 0, 0))
            m.Objects.AddExtrusion(ex, attr(r.choice(names)))
    for _ in range(r.randint(0, 2)):                                     # pipes
        D, Lp = r.choice([60, 114, 168]), r.choice([800, 1500])
        m.Objects.AddBrep(R.Cylinder(R.Circle(R.Point3d(r.choice([500, 1500]) / k, 400 / k, 50 / k), D / 2 / k), Lp / k).ToBrep(True, True),
                          attr(r.choice(names)))
    if r.random() < 0.5:
        m.Objects.AddCurve(R.LineCurve(R.Point3d(0, 0, 0), R.Point3d(3000 / k, 0, 0)), attr(r.choice(names)))
    m.Write(path, 7)
    return unit


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'rhino_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_rh_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []
    try:
        for i in range(a.n):
            f = r.choice(['hull_block', 'deck_panel', 'bulkhead', 'grillage', 'foundation', 'model']) + f'_{i:03d}.3dm'
            model(r, os.path.join(work, f))
            q = r.choice(ASK).format(f=f)
            name, args = ('file_info', {'file': f}) if 'What is in' in q or 'tell me' in q else ('native_cad', {'file': f, 'op': 'convert'})
            out = T.call(name, args)
            if 'error' in out:
                print('skip', f, out['error'][:200])
                continue
            out = json.loads(json.dumps(out).replace(work + os.sep, '').replace(work, '.'))
            ans = out['plain_english'] + (' The STEP can now go to cad_mesh / surface_extract for an FE model.' if 'FEA' in q else '')
            rows.append({'task': 'rhino_import', 'messages': [
                {'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block(name, args)},
                result_msg(name, out), {'role': 'assistant', 'content': ans}]})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked into the samples'
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
