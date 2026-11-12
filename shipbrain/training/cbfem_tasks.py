"""
CBFEM training samples from real runs of the steel_cbfem tool (ShipBrain's own component-based FE on CalculiX): fin plate, base plate and end plate
connections in plain words with shear / moment / axial loads (kN, kNm), results that pass or fail with the governing limit, a failing case
fixed and re-run, missing inputs asked for, and honest answers about what it does not do (welds, buckling, splices, IDEA StatiCa).

    python training/cbfem_tasks.py --fin 10 --base 8 --end 3 --out training/data/cbfem_train.jsonl.gz     (takes about 20 minutes)
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--fin', type=int, default=10)
    ap.add_argument('--base', type=int, default=8)
    ap.add_argument('--end', type=int, default=3)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'cbfem_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_cb_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}
    rows = []

    def slim(res):
        return {k: v for k, v in res.items() if k not in ('curve',)}

    def conv(args, q, pre=''):
        res = T.call('steel_cbfem', args)
        if 'error' in res:
            return None, None
        return res, [U(q), A(pre + tool_block('steel_cbfem', args)), result_msg('steel_cbfem', slim(res)), A(res['plain_english'])]

    def fin():
        b = r.choice(['IPE240', 'IPE270', 'IPE300', 'IPE330', 'IPE360', 'IPE400'])
        c = r.choice(['HEB200', 'HEB240', 'HEB260', 'HEB300'])
        rows_, bolt, V = r.choice([2, 3, 3, 4]), r.choice(['M16-8.8', 'M20-8.8', 'M20-8.8', 'M24-8.8']), r.choice([60, 90, 120, 160, 200])
        q = r.choice([f'CBFEM check of a fin plate: {b} on {c}, {rows_} {bolt.split("-")[0]} bolts, shear {V} kN',
                      f'Shear tab {b} to {c} flange, {rows_} bolts {bolt}, V = {V} kN. Does the plate and bolt group hold (CBFEM)?',
                      f'Fin plate connection, {c} column, {b} beam, {rows_} rows of {bolt}, {V} kN downward. Run the connection FE analysis'])
        args = {'kind': 'fin_plate', 'beam': b, 'column': c, 'bolt': bolt, 'rows': rows_, 'V': float(V), 'size': 40.0, 'lf_max': 3.0}
        res, conv_ = conv(args, q)
        if res is None:
            return None
        if res['capacity_factor'] is not None and res['capacity_factor'] < 1.0 and r.random() < 0.6:
            a2 = dict(args, rows=rows_ + 1, plate_t=12.0)
            res2, c2 = conv(a2, q)
            if res2 is not None and (res2['capacity_factor'] is None or res2['capacity_factor'] >= 1.0):
                return conv_[:3] + [A(res['plain_english'] + f' I add a bolt row and use a 12 mm fin plate and run again.\n' + tool_block('steel_cbfem', a2)),
                                    result_msg('steel_cbfem', slim(res2)), A(res2['plain_english'])]
        return conv_

    def base():
        c = r.choice(['HEB200', 'HEB240', 'HEB260', 'HEB300'])
        bolt = r.choice(['M20-8.8', 'M24-8.8', 'M24-8.8', 'M30-8.8'])
        N, M, V = r.choice([200, 400, 600]), r.choice([40, 80, 120, 160]), r.choice([20, 40, 60])
        q = r.choice([f'Column base {c}: 4 {bolt.split("-")[0]} anchors, axial {N} kN compression, bending moment {M} kNm, shear {V} kN. CBFEM please',
                      f'Base plate and anchor bolts of a {c} column ({bolt}), N = {N} kN down, M = {M} kNm, V = {V} kN: check with the connection FE model'])
        args = {'kind': 'base_plate', 'column': c, 'bolt': bolt, 'V': float(V), 'M': float(M), 'N': float(N), 'size': 50.0, 'lf_max': 2.5, 'column_length': 900.0}
        return conv(args, q)[1]

    def end():
        b, c = r.choice(['IPE270', 'IPE300', 'IPE330']), r.choice(['HEB240', 'HEB260', 'HEB300'])
        V, M = r.choice([40, 60, 90]), r.choice([20, 30, 50])
        q = f'Bolted end plate joint {b} to {c}, {r.choice([15, 20])} mm plate, M20 8.8 bolts. Shear {V} kN and hogging moment {M} kNm at the column face - CBFEM'
        pt = 15.0 if '15 mm' in q else 20.0
        args = {'kind': 'end_plate', 'beam': b, 'column': c, 'bolt': 'M20-8.8', 'plate_t': pt, 'V': float(V), 'M': float(M), 'beam_length': 700.0,
                'column_length': 800.0, 'size': 30.0, 'lf_max': 2.0}
        return conv(args, q)[1]

    def texts():
        return [
            [U('Do a CBFEM analysis of my connection'), A('Which connection: fin plate (shear tab), bolted end plate (moment joint) or column base plate with anchors? '
              'I need the sections (for example beam IPE300, column HEB260), the bolts (size and class, rows), plate thickness if you have it, and the loads at the connection: '
              'shear V in kN, bending moment M in kNm (beams: positive when the top flange is in tension), axial force N in kN.')],
            [U('Is this the same as IDEA StatiCa?'), A('No. IDEA StatiCa is a commercial program and I do not use it or its code. ShipBrain has its own CBFEM, built from the published method: plates as '
              'elastic-plastic shells with the 5 % plastic strain limit, bolts as springs with EN 1993-1-8 tension, shear and bearing capacity, contact between plates, solved with CalculiX. '
              'It is checked against hand formulas (T-stubs within about +20 % / -16 %), so use it to find the weak part and to compare variants, and keep your normal design check.')],
            [U('Does the CBFEM check my welds and plate buckling too?'), A('No. The CBFEM here checks plate plasticity (5 % strain limit), bolt tension, shear and bearing, and contact. '
              'Welds are modelled as shared nodes between plates (no weld strength check), buckling needs a separate analysis, and bolted splices are not available yet. '
              'For welds use a hand check or tell me and I give the stress from the model.')],
        ]

    n = 0
    for gen, cnt in ((fin, a.fin), (base, a.base), (end, a.end)):
        got = 0
        while got < cnt and n < 400:
            n += 1
            try:
                m = gen()
            except Exception as e:
                print('skip', gen.__name__, type(e).__name__, str(e)[:100])
                continue
            if not m:
                continue
            rows.append({'task': 'cbfem_' + gen.__name__, 'messages': m})
            got += 1
            print(gen.__name__, got, '/', cnt, flush=True)
    for m in texts():
        rows.append({'task': 'cbfem_text', 'messages': m})
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows))


if __name__ == '__main__':
    main()
