"""
AlgoHex checks run on GitHub (.github/workflows/shipbrain-algohex.yml): make the inputs, then report on AlgoHex's outputs.

    python training/algohex_cases.py --prepare --dir /tmp/ah_cases        # tetrahedral inputs (.vtk) + cases.json
    (the workflow runs HexMeshing -i <in> -o <out>.ovm for every case)
    python training/algohex_cases.py --report --dir /tmp/ah_cases --out results.json
Cases: AlgoHex's own demo cylinder (its input as published), and parts meshed by ShipBrain (its own hex mesher, split into tets):
a cylinder of the same size as the demo, a block with a hole, an L-bracket. The exact volume of each is known for the check.
"""
import argparse, json, math, os, shutil, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))


def parts():
    import cadquery as cq
    return {
        'sb_cylinder': (cq.Workplane('XY').circle(10).extrude(30), math.pi * 100 * 30, 1.5),
        'sb_block_hole': (cq.Workplane('XY').box(60, 40, 20).faces('>Z').workplane().hole(16), 60 * 40 * 20 - math.pi * 64 * 20, 3.0),
        'sb_l_bracket': (cq.Workplane('XZ').polyline([(0, 0), (60, 0), (60, 10), (10, 10), (10, 50), (0, 50)]).close().extrude(-30),
                         (60 * 10 + 10 * 40) * 30, 2.5),
    }


def prepare(d):
    from shipbrain import algohex as AH
    os.makedirs(d, exist_ok=True)
    cases = [{'name': 'algohex_demo_cylinder', 'input': 'algohex_demo_cylinder.ovm', 'exact_volume': None,
              'note': "AlgoHex's own demo input"}]
    shutil.copy(os.path.join(os.path.dirname(HERE), 'shipbrain', 'vendor', 'algohex', 'cylinder.ovm'), os.path.join(d, 'algohex_demo_cylinder.ovm'))
    import cadquery as cq
    for name, (wp, vol, size) in parts().items():
        step = os.path.join(d, name + '.step')
        cq.exporters.export(wp, step)
        rep = AH.prepare(step, size, os.path.join(d, name + '.vtk'))
        cases.append({'name': name, 'input': name + '.vtk', 'exact_volume': vol, 'tets': rep['tets'], 'tet_volume': rep['volume'],
                      'note': f'ShipBrain hex mesh {size} mm split into tetrahedra'})
    json.dump(cases, open(os.path.join(d, 'cases.json'), 'w'), indent=1)
    print(json.dumps(cases, indent=1))


def report(d, out):
    from shipbrain import algohex as AH
    cases = json.load(open(os.path.join(d, 'cases.json')))
    res = []
    for c in cases:
        o = os.path.join(d, c['name'] + '_hex.ovm')
        r = dict(c)
        t = os.path.join(d, c['name'] + '.seconds')
        if os.path.exists(t):
            r['seconds'] = float(open(t).read().strip() or 0)
        if os.path.exists(o):
            try:
                r.update(AH.report(o, exact_volume=c.get('exact_volume')))
            except Exception as e:
                r['error'] = f'{type(e).__name__}: {e}'
        else:
            r['error'] = 'AlgoHex wrote no output (see the log)'
        res.append(r)
    json.dump(res, open(out, 'w'), indent=1)
    print(json.dumps(res, indent=1))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--prepare', action='store_true')
    ap.add_argument('--report', action='store_true')
    ap.add_argument('--dir', default='/tmp/ah_cases')
    ap.add_argument('--out', default='/tmp/ah_cases/results.json')
    a = ap.parse_args()
    if a.prepare:
        prepare(a.dir)
    if a.report:
        report(a.dir, a.out)
