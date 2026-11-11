"""
Download every outside data source ShipBrain trains on, ONCE, into one folder - meant for the Kaggle data notebook
(training/kaggle/data_kernel.py), whose output you then attach to the training notebook as a dataset. Each part is
independent: one failing source does not stop the others; manifest.json says what came and what did not.

    python training/fetch_data.py --out /kaggle/working/shipbrain_data

  pid2graph/     PID2Graph real + synthetic P&IDs with symbol / line graphs (CC BY-SA 4.0, Zenodo)
  cubicasa5k/    CubiCasa5K floor plans, svg + picture, a subset (CC BY-NC 4.0, Zenodo)
  pidqa/         PIDQA question / answer pairs on P&IDs (CC0, GitHub)
  floorplancad/  FloorPlanCAD drawings, if its download links work (CC BY-NC 4.0)
  class_rules/   free rule books of IACS + 12 class societies, <society>/*.pdf (copyright of each society: keep this
                 dataset PRIVATE on Kaggle - the default)
  packs/         class_rules_<society>.private.sbpack built from them
"""
import argparse, json, os, sys, time, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def _size(path):
    tot = n = 0
    for dp, _, fs in os.walk(path):
        for f in fs:
            tot += os.path.getsize(os.path.join(dp, f))
            n += 1
    return n, round(tot / 1e6, 1)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', required=True)
    ap.add_argument('--only', nargs='*', help='pid2graph cubicasa5k pidqa floorplancad class_rules')
    ap.add_argument('--cubicasa-plans', type=int, default=2000)
    ap.add_argument('--rules-per-society', type=int, default=150)
    a = ap.parse_args(argv)
    import construct_real as cr
    from shipbrain import classrules
    os.makedirs(a.out, exist_ok=True)
    steps = [('pid2graph', lambda d: cr.fetch_pid2graph(d)),
             ('cubicasa5k', lambda d: cr.fetch_cubicasa(d, a.cubicasa_plans)),
             ('pidqa', lambda d: cr.fetch_pidqa(d)),
             ('floorplancad', lambda d: cr._fetch_floorplancad(os.makedirs(d, exist_ok=True) or d)),
             ('class_rules', lambda d: classrules.download(d, max_files=a.rules_per_society))]
    man = {'made': time.strftime('%Y-%m-%d %H:%M'), 'sources': {}}
    mp = os.path.join(a.out, 'manifest.json')
    if os.path.exists(mp):
        man = json.load(open(mp))
    for name, fn in steps:
        if a.only and name not in a.only:
            continue
        d = os.path.join(a.out, name)
        t0 = time.time()
        print(f'== {name}', flush=True)
        try:
            fn(d)
            n, mb = _size(d)
            man['sources'][name] = {'ok': n > 0, 'files': n, 'MB': mb, 'seconds': round(time.time() - t0)}
        except Exception as e:
            traceback.print_exc()
            man['sources'][name] = {'ok': False, 'error': f'{type(e).__name__}: {str(e)[:300]}'}
        print(name, man['sources'][name], flush=True)
        json.dump(man, open(mp, 'w'), indent=1)
    if os.path.isdir(os.path.join(a.out, 'class_rules')):
        try:
            made = classrules.build(os.path.join(a.out, 'class_rules'), os.path.join(a.out, 'packs'))
            man['sources']['class_rule_packs'] = {'ok': bool(made), 'packs': [os.path.basename(m) for m in made]}
        except Exception as e:
            man['sources']['class_rule_packs'] = {'ok': False, 'error': f'{type(e).__name__}: {str(e)[:300]}'}
    json.dump(man, open(mp, 'w'), indent=1)
    print(json.dumps(man, indent=1))


if __name__ == '__main__':
    main()
