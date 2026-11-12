"""
Connection-check training samples from real runs of the connection_check tool (Osoconn, AISC 360): clip angle shear connections and
extended end plate moment connections in kN / mm, vertical and horizontal brace gusset connections in kip / inch, with the plain-words
request turned into Osoconn keywords (unstated grades default to A36 steel, E70 welds, A325 bolts, said in the answer), NOT OK results fixed
and re-run, wrong inputs corrected from the error text, and missing inputs asked for.

    python training/osoconn_tasks.py --n 60 --out training/data/osoconn_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

SC = dict(MODULUS_OF_ELASTICITY=200000, POISSON_RATIO=0.3, STEEL_GRADE_OF_ANGLE='A36', STEEL_GRADE_OF_BEAM='A36', STEEL_GRADE_OF_SUPPORT='A36',
          WELD_ELECTRODE='E70', BOLT_GRADE='A325', TRANSFER_FORCE=15000, SHEAR_FORCE=200000, BOLT_DIAMETER='M22', BOLT_TYPE='BEARING',
          NUMBER_OF_BOLTS_PER_ROW=3, BOLT_GAGE=90, BOLT_SPACING=70, THICKNESS_OF_WELD=6, CLIP_ANGLE='L102X76X9.5', OUTSTANDING_LEG='LONG_LEG',
          CLIP_ANGLE_LENGTH=210, CLIP_ANGLE_TOP=47, BEAM_SECTION='W310X74', CONNECTION_SETBACK=12, COPE_LENGTH=100, TOP_COPE_DEPTH=35,
          BOTTOM_COPE_DEPTH=0, SUPPORT_SECTION='W460X74', SUPPORT_TYPE='BEAM', BACKING_BEAM='NO')
MC = dict(SHEAR_FORCE=150000, COLUMN_AXIAL_FORCE=600000, MODULUS_OF_ELASTICITY=200000, STEEL_GRADE_OF_PLATE='A36', STEEL_GRADE_OF_BEAM='A36',
          STEEL_GRADE_OF_COLUMN='A36', WELD_ELECTRODE='E70', BOLT_GRADE='A325', PLATE_WIDTH=300, PLATE_HEIGHT=550, PLATE_THICKNESS=25,
          CONFIGURATION='4_BOLTS', BEAM_SECTION='W360X44', COLUMN_SECTION='W410X149', BOLT_DIAMETER='M30', BOLT_GAGE=140, INNER_BOLT_TO_FLANGE=45,
          OUTER_BOLT_TO_FLANGE=45, WEB_WELD=6, FLANGE_WELD_REINFORCEMENT=4, COLUMN_STIFFENER='YES', DOUBLER_PLATE='NO',
          COLUMN_STIFFENER_THICKNESS=25, COLUMN_STIFFENER_WIDTH=100, COLUMN_STIFFENER_CLIP=25, COLUMN_STIFFENER_TO_FLANGE_WELD=16,
          COLUMN_STIFFENER_TO_WEB_WELD=6, DISTANCE_TO_COLUMN_TOP=75)


def cin_params(O, folder, code, n):
    P = {}
    for ln in open(os.path.join(O.CLA, 'examples', folder, code, f'{folder}_{n}.cin')):
        w = ln.split()
        if len(w) >= 2 and not ln.startswith('*') and w[0] not in ('CONNECTION_CODE', 'CONNECTION_ID', 'METHOD', 'UNITS'):
            P[w[0]] = w[1]
    return P


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'osoconn_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge, osoconn as O
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_oc_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}
    rows, kinds = [], {}
    DEF = ' (Not stated: I take A36 steel, E70 welds and A325 bolts, E = 200 GPa.)'

    def call(kind, P, units='NEWTON_MM', method='LRFD'):
        args = {'kind': kind, 'params': P, 'units': units}
        if method != 'LRFD':
            args['method'] = method
        return args, T.call('connection_check', args)

    def conv(res):
        return result_msg('connection_check', {k: v for k, v in res.items() if k != 'checks'} | ({'checks': res['checks'][:6]} if 'checks' in res else {}))

    def sc(fix=False):
        P = dict(SC)
        nb = r.choice([2, 2, 3, 3])
        P.update(SHEAR_FORCE=r.choice([60, 100, 150, 200, 300, 400]) * 1000, TRANSFER_FORCE=r.choice([0, 10, 15, 30]) * 1000,
                 NUMBER_OF_BOLTS_PER_ROW=nb, BOLT_DIAMETER=r.choice(['M20', 'M22', 'M24']), THICKNESS_OF_WELD=r.choice([5, 6, 8]),
                 CLIP_ANGLE_LENGTH=70 * nb)
        q = (f"Clip angle shear connection: W310X74 beam framing into the web of a W460X74 girder. Shear {P['SHEAR_FORCE'] / 1000:g} kN"
             f"{', axial ' + format(P['TRANSFER_FORCE'] / 1000, 'g') + ' kN' if P['TRANSFER_FORCE'] else ''}. {nb} {P['BOLT_DIAMETER']} bearing bolts per row, "
             f"gauge 90, pitch 70, angles L102X76X9.5 {P['CLIP_ANGLE_LENGTH']} mm long, {P['THICKNESS_OF_WELD']} mm welds. AISC check please")
        args, res = call('shear_clip_angle', P)
        if 'error' in res:
            return None
        m = [U(q), A('Units N and mm.' + DEF + '\n' + tool_block('connection_check', args)), conv(res)]
        if not res['ok'] and fix and nb == 2:
            P2 = dict(P, NUMBER_OF_BOLTS_PER_ROW=3, CLIP_ANGLE_LENGTH=210)
            args2, res2 = call('shear_clip_angle', P2)
            if 'error' in res2 or not res2['ok']:
                return None
            return m + [A(res['plain_english'] + ' I add a third bolt per row (clip angles 210 mm long).\n' + tool_block('connection_check', args2)),
                        conv(res2), A(res2['plain_english'])]
        return m + [A(res['plain_english'])]

    def mc(fix=False):
        P = dict(MC)
        P.update(SHEAR_FORCE=r.choice([80, 120, 150, 200]) * 1000, COLUMN_AXIAL_FORCE=r.choice([200, 400, 600, 800]) * 1000,
                 PLATE_THICKNESS=r.choice([25, 28, 32]), BOLT_DIAMETER=r.choice(['M27', 'M30', 'M30', 'M36']))
        q = (f"Extended end plate moment connection, W360X44 beam on a W410X149 column: plate 300 x 550 x {P['PLATE_THICKNESS']} mm, 4 {P['BOLT_DIAMETER']} bolts, "
             f"gauge 140, 45 mm from the flanges, 6 mm web weld, 4 mm flange weld reinforcement, column stiffener 25 x 100 mm. "
             f"Shear {P['SHEAR_FORCE'] / 1000:g} kN, column axial {P['COLUMN_AXIAL_FORCE'] / 1000:g} kN. Is it OK?")
        args, res = call('moment_end_plate', P)
        if 'error' in res:
            return None
        m = [U(q), A('Units N and mm.' + DEF + '\n' + tool_block('connection_check', args)), conv(res)]
        if not res['ok'] and fix:
            P2 = dict(P, PLATE_THICKNESS=32 if P['PLATE_THICKNESS'] < 32 else P['PLATE_THICKNESS'] + 4)
            args2, res2 = call('moment_end_plate', P2)
            if 'error' in res2 or not res2['ok']:
                return None
            return m + [A(res['plain_english'] + f" I thicken the end plate to {P2['PLATE_THICKNESS']} mm.\n" + tool_block('connection_check', args2)),
                        conv(res2), A(res2['plain_english'])]
        return m + [A(res['plain_english'])]

    def imperial(kind, folder, code, force_keys, lab):
        n = r.choice([1, 2, 3, 4, 5])
        P = cin_params(O, folder, code, n)
        for k in force_keys:
            P[k] = round(float(P[k]) * r.choice([0.5, 0.8, 1.0, 1.2, 1.5]), 1)
        text = {'vertical_brace': 'Vertical brace gusset connection (AISC)', 'horizontal_brace': 'Horizontal brace gusset connection (AISC)',
                'moment_end_plate': 'Extended end plate moment connection (AISC)'}[kind]
        d = ', '.join(f'{k.replace("_", " ").lower()} {P[k]}' for k in P if k in ('BRACE_FORCE', 'SHEAR_FORCE', 'COLUMN_AXIAL_FORCE', 'BEAM_SHEAR_FORCE',
                                                                              'BEAM_TRANSFER_FORCE') and k in force_keys)
        sect = ', '.join(f'{k.replace("_", " ").lower()} {P[k]}' for k in P if k.endswith('SECTION') or k in ('BOLT_DIAMETER', 'GUSSET_THICKNESS', 'PLATE_THICKNESS'))
        q = f'{text} in kip and inch. {d}. {sect}. All other details as in the standard example. Check it'
        args, res = call(kind, P, units='KIP_IN')
        if 'error' in res:
            return None
        return [U(q), A('Units kip and inch; the remaining inputs I keep as in the standard example.\n' + tool_block('connection_check', args)), conv(res), A(res['plain_english'])]

    def recover():
        P = dict(SC)
        P['BOLT_DIAMETER'] = r.choice(['M21', 'M23', 'M25'])
        args, res = call('shear_clip_angle', P)
        if 'error' not in res:
            return None
        P2 = dict(P, BOLT_DIAMETER='M22')
        args2, res2 = call('shear_clip_angle', P2)
        if 'error' in res2:
            return None
        q = f"Clip angle shear connection W310X74 on W460X74 web, {P['BOLT_DIAMETER']} bolts, 200 kN. Check"
        return [U(q), A(tool_block('connection_check', args)), result_msg('connection_check', res),
                A(f"{P['BOLT_DIAMETER']} is not a size Osoconn knows (M16 M20 M22 M24 M27 M30 M36). I use the nearest standard size, M22.\n" + tool_block('connection_check', args2)),
                conv(res2), A(res2['plain_english'])]

    def ask():
        q = r.choice(['Check my connection to AISC', 'Is my gusset connection strong enough?', 'Is the beam end connection OK? Eurocode or AISC, whatever'])
        return [U(q), A('I can check these to AISC 360 (LRFD or ASD): a double clip angle shear connection, an extended end plate moment connection, '
                        'and vertical or horizontal brace gusset connections. Which one is it? Then I need the loads (kN or kip), the sections (for example beam W310X74, '
                        'support W460X74), the bolts (size, grade, number, gauge, pitch) and the plate or angle sizes and weld sizes. For a Eurocode check I do not have a '
                        'tool yet: I can only check bolt shear to EN 1993-1-8 with the bolt group tool.')]

    gens = [(lambda: sc(True), 5), (lambda: sc(False), 3), (lambda: mc(True), 5), (lambda: mc(False), 3),
            (lambda: imperial('vertical_brace', 'VB001', 'VB001AM10', ['BRACE_FORCE', 'BEAM_SHEAR_FORCE', 'BEAM_TRANSFER_FORCE'], 'vb'), 3),
            (lambda: imperial('horizontal_brace', 'HB001', 'HB001AM10', ['BRACE_FORCE'], 'hb'), 3),
            (lambda: imperial('moment_end_plate', 'MC001', 'MC001AM10', ['SHEAR_FORCE', 'COLUMN_AXIAL_FORCE'], 'mc'), 2),
            (recover, 1), (ask, 1)]
    names = ['sc_fix', 'sc', 'mc_fix', 'mc', 'vb', 'hb', 'mc_imperial', 'recover', 'ask']
    pool = [(nm, g) for (g, w), nm in zip(gens, names) for _ in range(w)]
    tries = 0
    while len(rows) < a.n and tries < a.n * 6:
        tries += 1
        nm, g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', nm, type(e).__name__, str(e)[:100])
            continue
        if not m:
            continue
        kinds[nm] = kinds.get(nm, 0) + 1
        rows.append({'task': 'osoconn_' + nm, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
