"""
Steel-connection training samples from real runs of the steel_connection tool: end plate / fin plate / base plate / splice from plain
words (sections, bolts, plate thickness), shell and hex mesh requests, runs with a load, spacing warnings explained and fixed,
missing inputs asked for, and honest answers when the user asks for a resistance check (not done by this tool).

    python training/connection_tasks.py --n 70 --out training/data/connection_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

BEAMS = ['IPE240', 'IPE270', 'IPE300', 'IPE330', 'IPE360', 'IPE400', 'IPE450', 'IPE500', 'HEA240', 'HEA300']
COLS = ['HEB200', 'HEB240', 'HEB260', 'HEB300', 'HEB320', 'HEB360', 'HEA300', 'HEB400']
BOLTS = ['M16-8.8', 'M20-8.8', 'M20-10.9', 'M24-8.8', 'M22-10.9']


def words(sec):
    return r_choice([sec, sec.replace('IPE', 'IPE '), sec.replace('HEB', 'HEB ').replace('HEA', 'HEA ')])


def main(argv=None):
    global r_choice
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=70)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'connection_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    r_choice = r.choice
    work = tempfile.mkdtemp(prefix='sb_cn_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}
    rows, kinds = [], {}

    def ok(res):
        return 'error' not in res

    def end_plate():
        b, c, bt = r.choice(BEAMS), r.choice(COLS), r.choice(BOLTS)
        ext = r.choice([0, 0, 50, 60, 80])
        tp = r.choice([15, 20, 25])
        what = 'extended end plate' if ext else r.choice(['flush end plate', 'end plate'])
        q = r.choice([f'{words(b)} beam on a {words(c)} column with a {what}, {bt.split("-")[0]} bolts, {tp} mm plate',
                      f'Make a bolted moment connection: beam {b}, column {c}, {what} {tp} thick, bolts {bt}',
                      f'{c} column, {b} beam, {what}. {bt.split("-")[0]} {bt.split("-")[1]} bolts. 3D model please'])
        args = {'kind': 'end_plate', 'beam': b, 'column': c, 'bolt': bt, 'plate_t': tp, 'name': 'end_plate_joint'}
        if ext:
            args['ext'] = ext
        res = T.call('steel_connection', args)
        return None if not ok(res) else [U(q), A(tool_block('steel_connection', args)), result_msg('steel_connection', res), A(res['plain_english'])]

    def fin():
        b, c, bt = r.choice(BEAMS[:6]), r.choice(COLS), r.choice(['M16-8.8', 'M20-8.8'])
        rows_ = r.choice([2, 3, 3, 4])
        q = r.choice([f'Shear tab for {b} to {c}, {rows_} bolts {bt.split("-")[0]}', f'Simple fin plate connection, beam {b}, column {c}, {rows_} rows of {bt} bolts',
                      f'fin plate {b} on {c} flange, {rows_} bolts'])
        args = {'kind': 'fin_plate', 'beam': b, 'column': c, 'bolt': bt, 'rows': rows_, 'name': 'fin_joint'}
        res = T.call('steel_connection', args)
        return None if not ok(res) else [U(q), A(tool_block('steel_connection', args)), result_msg('steel_connection', res), A(res['plain_english'])]

    def base():
        c, bt = r.choice(COLS), r.choice(['M20-8.8', 'M24-8.8', 'M30-8.8'])
        ribs = r.choice([True, False])
        tp = r.choice([25, 30, 40])
        q = r.choice([f'Column base for {c}: {tp} mm base plate, 4 {bt.split("-")[0]} anchor bolts' + (', with ribs' if ribs else ''),
                      f'Base plate and anchors for a {c} column, plate {tp}' + (' and stiffener ribs' if ribs else ''),
                      f'I need a {c} column foot with anchor bolts {bt}, plate thickness {tp}'])
        args = {'kind': 'base_plate', 'column': c, 'bolt': bt, 'plate_t': tp, 'name': 'column_base'}
        if ribs:
            args['ribs'] = True
        res = T.call('steel_connection', args)
        return None if not ok(res) else [U(q), A(tool_block('steel_connection', args)), result_msg('steel_connection', res), A(res['plain_english'])]

    def splice():
        b, bt = r.choice(BEAMS[:7]), r.choice(['M16-8.8', 'M20-8.8', 'M20-10.9'])
        q = r.choice([f'Bolted splice for {b} with cover plates, {bt.split("-")[0]} bolts', f'Beam splice {b}, flange and web plates, bolts {bt}',
                      f'Join two {b} beams with a bolted splice'])
        args = {'kind': 'splice', 'beam': b, 'bolt': bt, 'name': 'beam_splice'}
        res = T.call('steel_connection', args)
        return None if not ok(res) else [U(q), A(tool_block('steel_connection', args)), result_msg('steel_connection', res), A(res['plain_english'])]

    def shell_run():
        b, c = r.choice(BEAMS[3:]), r.choice(COLS[2:])
        load = r.choice([50, 80, 100, 150])
        size = r.choice([20, 25, 30])
        q = r.choice([f'{b} beam on {c} column, extended end plate. Shell mesh at {size} mm, {load} kN at the beam end, and run it',
                      f'End plate joint {b} / {c}: make the FE model ({size} mm shells) with {load} kN downward at the free end and solve',
                      f'Build the connection {b} to {c} with end plate, mesh it with shells ({size} mm), load {load} kN, run CalculiX'])
        args = {'kind': 'end_plate', 'beam': b, 'column': c, 'ext': 60, 'mesh': 'shell', 'size': size, 'load_kn': load, 'solve': True, 'name': 'ep_fe'}
        res = T.call('steel_connection', args)
        return None if not ok(res) else [U(q), A(tool_block('steel_connection', args)), result_msg('steel_connection', res), A(res['plain_english'])]

    def hex_run():
        c = r.choice(COLS[2:])
        q = r.choice([f'Base plate for {c} and hex mesh the plate and the ribs', f'Column base {c} with ribs, give me hexahedral meshes of the plates'])
        args = {'kind': 'base_plate', 'column': c, 'ribs': True, 'mesh': 'hex', 'name': 'base_hex'}
        res = T.call('steel_connection', args)
        return None if not ok(res) else [U(q), A(tool_block('steel_connection', args)), result_msg('steel_connection', res), A(res['plain_english'])]

    def warn_fix():
        b = r.choice(['IPE200', 'IPE240'])
        c = r.choice(['HEB200', 'HEB240'])
        q = f'Fin plate for {b} on {c} with 7 bolt rows M20'
        a1 = {'kind': 'fin_plate', 'beam': b, 'column': c, 'rows': 7, 'name': 'fin_tall'}
        r1 = T.call('steel_connection', a1)
        if not ok(r1) or not r1['spacing_warnings']:
            return None
        a2 = {'kind': 'fin_plate', 'beam': b, 'column': c, 'rows': 3, 'name': 'fin_tall'}
        r2 = T.call('steel_connection', a2)
        if not ok(r2):
            return None
        return [U(q), A(tool_block('steel_connection', a1)), result_msg('steel_connection', r1),
                A(f'Seven rows do not fit: {r1["spacing_warnings"][0]}. The web of the {b} is too short for that many bolts. I try 3 rows.\n' + tool_block('steel_connection', a2)),
                result_msg('steel_connection', r2), A(r2['plain_english'])]

    def ask():
        q = r.choice(['Make me a steel connection', 'I need a beam to column joint', 'Design a connection for my frame', 'Connection 3D model karna hai'])
        return [U(q), A('Sure. Which kind: end plate (bolted moment joint), fin plate / shear tab, base plate with anchor bolts, or a beam splice? '
                        'And the sections: for example beam IPE400 on column HEB300 (or h, b, web and flange thickness in mm). '
                        'Bolts default to M20-8.8; I can also mesh it (shell or hex) and run a load.')]

    def resistance():
        q = r.choice(['Is this end plate connection strong enough for 200 kNm?', 'Check the bolt resistance and weld strength of the fin plate',
                      'Does the base plate pass the Eurocode check?'])
        return [U(q), A('I cannot do a full code resistance check (bolt bearing, weld strength, column web panel, plate bending) - ShipBrain builds the '
                        'connection, checks the bolt spacing and clashes, meshes it and can run a finite element model for a load you give me. '
                        'For the bolts I can do more: the bolt_group tool checks a bolt group under shear and eccentric load (elastic and AISC instant-centre '
                        'methods, bolt shear only), and the bolt tool checks one bolt for preload and fatigue. Give me the bolt layout, size and class, and the load with its '
                        'eccentricity and I run that. A full resistance check of the whole joint needs a code program or an engineer.')]

    gens = [(end_plate, 8), (fin, 6), (base, 6), (splice, 4), (shell_run, 5), (hex_run, 2), (warn_fix, 2), (ask, 2), (resistance, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    while len(rows) < a.n:
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:120])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'connection_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked'
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
