"""Benchmark runner (P3/P4/R-PR): run deckrules.run on every page of a benchmark with its reference XML (scoring only),
print the review table and check the floors. Offline.
python tools/benchmark.py benchmarks/bench_1005.json --data DIR_WITH_PDF_AND_XML --out OUTDIR [--max-seconds N]"""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(cfg, data, out):
    rows, t0 = [], time.time()
    for pg in cfg['pages']:
        od = os.path.join(out, f'p{pg}')
        os.makedirs(od, exist_ok=True)
        cmd = [sys.executable, '-m', 'deckrules.run', os.path.join(data, cfg['pdf']), '--page', str(pg),
               '--reference', os.path.join(data, cfg['reference']), '--out', od]
        if cfg.get('settings'):
            cmd += ['--settings', os.path.join(HERE, cfg['settings'])]
        t = time.time()
        r = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True)
        dt = time.time() - t
        if r.returncode:
            print(r.stdout[-2000:], r.stderr[-3000:])
        sm = json.load(open(os.path.join(od, 'summary.json')))
        for deck, v in sm.items():
            s = (v or {}).get('score') or {}
            rows.append({'page': pg, 'deck': deck, 'seconds': round(dt), **s, 'error': (v or {}).get('error')})
    return rows, time.time() - t0


def table(rows):
    L = ['Deck | Found | Found+size | Output real | Out m / Ref m | Footprint | Thickness | Openings | s/page',
         '---|---|---|---|---|---|---|---|---']
    for r in rows:
        L.append(f"{r['deck']} | {r.get('members_found')} | {r.get('members_found_size')} | {r.get('members_real')} | "
                 f"{r.get('members_out_m')} / {r.get('members_ref_m')} | {r.get('footprint_iou')} | {r.get('thickness_agreement')} | "
                 f"{r.get('openings_matched')} | {r['seconds']}" + (f" | ERROR {r['error']}" if r.get('error') else ''))
    return '\n'.join(L)


def check(rows, floors, decks=None):
    bad = []
    for r in rows:
        if decks and r['deck'] not in decks:
            continue
        for k, f in floors.items():
            v = r.get(k)
            if v is None or v < f:
                bad.append(f"{r['deck']}: {k} = {v} < {f}")
    return bad


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('bench'); ap.add_argument('--data', required=True); ap.add_argument('--out', required=True)
    a = ap.parse_args()
    cfg = json.load(open(a.bench))
    rows, T = run(cfg, a.data, a.out)
    t = table(rows)
    bad = check(rows, cfg['floors'], cfg.get('floor_decks'))
    rep = f"# Benchmark: {cfg['name']}\n\n{t}\n\nTotal {T:.0f} s\n\n" + ('FLOORS FAILED:\n' + '\n'.join('- ' + b for b in bad) if bad else 'All floors met.')
    open(os.path.join(a.out, 'BENCHMARK.md'), 'w').write(rep)
    json.dump({'rows': rows, 'failed': bad, 'seconds': T}, open(os.path.join(a.out, 'benchmark.json'), 'w'), indent=1)
    print(rep)
    sys.exit(1 if bad else 0)
