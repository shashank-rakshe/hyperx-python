"""
Training samples from real runs of the tools added late: propeller_bem, propeller_design, blade_geometry, nastran_read, nastran_plate_deck, hull_resistance, gz_curve, stl_stability (after hull_generate),
hull_motions, dbb_blocks, catamaran_hull, pynite_fea, openhcm_read. Every tool result is produced by really calling the tool; missing-input and out-of-range requests teach asking / refusing.

    python training/late_tools_tasks.py --n 260 --out training/data/late_tools_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=260)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'late_tools_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_lt_')
    T = agent.Tools(work, knowledge.load(None))
    for f in ('plate.bdf', 'plate.op2'):
        shutil.copy(os.path.join(ROOT, 'tests', 'data', 'pynastran', f), os.path.join(work, f))
    shutil.copy(os.path.join(ROOT, 'tests', 'data', 'sample_openhcm.xml'), os.path.join(work, 'ship_structure.xml'))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def one(q, tool, args, pre='', answer=None):
        res = T.call(tool, args)
        if 'error' in res:
            return None
        return [U(q), A(pre + tool_block(tool, args)), result_msg(tool, res), A(answer or res['plain_english'])]

    def hull():
        L = r.choice([80, 100, 120, 150, 180])
        B = round(L * r.uniform(0.14, 0.19), 1)
        Tt = round(B * r.uniform(0.33, 0.45), 1)
        D = round(Tt * r.uniform(1.3, 1.5), 1)
        return L, B, D, Tt

    # ---- propellers
    def bem():
        D, Z, pd, ear = r.choice([2, 3, 4, 5, 6]), r.choice([3, 4, 5]), r.choice([0.8, 0.9, 1.0, 1.1, 1.2]), r.choice([0.45, 0.55, 0.65, 0.8])
        rpm, kn = r.choice([90, 120, 150, 200, 250]), r.choice([8, 12, 14, 16, 18])
        return one(f'Open-water curve of a {D} m propeller with {Z} blades, P/D {pd}, EAR {ear}; at {rpm} rpm and {kn} knots give thrust, torque and power.', 'propeller_bem',
                   {'D': D, 'pitch_ratio': pd, 'Z': Z, 'ear': ear, 'rpm': rpm, 'speed_kn': kn})

    def bem_curve():
        pd, Z = r.choice([0.8, 0.9, 1.0, 1.2]), r.choice([3, 4, 5])
        return one(f'KT, KQ and efficiency against J for a {Z}-blade propeller with pitch ratio {pd}', 'propeller_bem', {'D': 3.0, 'pitch_ratio': pd, 'Z': Z},
                   pre='The diameter does not change the open-water curve (it is non-dimensional), so I take 3 m.\n')

    def design():
        D = r.choice([2.0, 3.0, 4.0, 5.0])
        Z, rpm, V = r.choice([4, 5]), r.choice([120, 180, 250, 300]), r.choice([5.0, 6.0, 7.0, 8.0])
        Tn = round(r.choice([60, 100, 150, 200, 300]) * 1000.0)
        q = f'Design a {Z}-blade propeller, {D} m diameter, {rpm} rpm, that gives {Tn // 1000} kN at {V} m/s speed of advance.'
        return one(q + (' Write the blade STL too.' if r.random() < 0.4 else ''), 'propeller_design', {'Z': Z, 'rpm': rpm, 'D': D, 'thrust_N': Tn, 'speed_ms': V} | ({'blade_stl': True} if 'STL' in q else {}))

    def design_missing():
        return [U(r.choice(['Design a propeller for my ship.', 'I need a new propeller, can you design it?'])),
                A('I need five things for a propeller design: the diameter (m), the shaft speed (rpm), the thrust you need (kN, usually the resistance at service speed divided by (1 - thrust deduction)), the speed of '
                  'advance at the propeller (m/s, ship speed times (1 - wake fraction)), and the number of blades. Do you also want a duct? Give me those and I will design it.')]

    def blade():
        n = r.choice([5, 6, 8])
        R = r.choice([0.5, 1.0, 1.5])
        radii = [round(R * x, 3) for x in [0.2 + 0.8 * i / (n - 1) for i in range(n)]]
        chord = [round(R * (0.35 - 0.2 * ((i / (n - 1)) - 0.5) ** 2 * 4 * 0.5 - 0.05 * i / (n - 1)), 3) for i in range(n)]
        pitch = [round(R * 1.8, 3)] * n
        return one(f'Build the blade surface for radii {radii[0]} to {radii[-1]} m, chords {chord[0]}, {chord[n // 2]}, {chord[-1]} m (smooth between), constant pitch {pitch[0]} m, NACA 4412 sections.', 'blade_geometry',
                   {'radii': radii, 'chord_lengths': chord, 'pitch': pitch, 'naca': '4412'})

    # ---- Nastran
    def nread():
        f = r.choice(['plate.bdf', 'plate.op2'])
        return one(r.choice([f'Open {f} and tell me what is in it.', f'Read the Nastran file {f}: sizes and results.']), 'nastran_read', {'file': f})

    def ndeck():
        L, W, t = r.choice([0.5, 1.0, 2.0]), r.choice([0.1, 0.2, 0.5]), r.choice([0.005, 0.01, 0.02])
        F = r.choice([500, 1000, 5000])
        return one(f'Make a Nastran bdf of a cantilever plate {L} m long, {W} m wide, {int(t * 1000)} mm thick, steel, with {F} N at the free end.', 'nastran_plate_deck', {'L': L, 'W': W, 't': t, 'force_N': F, 'name': 'plate_deck'})

    # ---- hull analysis
    def resist():
        L, B, D, Tt = hull()
        kn = sorted(r.sample([8, 10, 12, 14, 16, 18], 3))
        return one(f'Resistance and effective power of a hull {L} x {B} x {D} m, draft {Tt} m, Cb 0.7, at {kn[0]}, {kn[1]} and {kn[2]} knots.', 'hull_resistance',
                   {'L': L, 'B': B, 'D': D, 'T': Tt, 'target_cb': 0.7, 'speeds_kn': kn})

    def resist_range():
        L, B, D, Tt = hull()
        args = {'L': L, 'B': B, 'D': D, 'T': Tt, 'target_cb': 0.7, 'speeds_kn': [40]}
        res = T.call('hull_resistance', args)
        if 'error' not in res:
            return None
        return [U(f'How much power for a {L} m hull ({B} m beam, {Tt} m draft) at 40 knots?'), A(tool_block('hull_resistance', args)), result_msg('hull_resistance', res),
                A('At 40 knots this hull is far above the range of the Holtrop method (Froude number up to about 0.45), so the tool refused instead of giving a number that would be wrong. For a fast hull use a planing or '
                  'high-speed method, model tests or a CFD run; for ordinary displacement speeds I can give the power now.')]

    def gz():
        L, B, D, Tt = hull()
        kg = round(D * r.uniform(0.55, 0.75), 1)
        return one(f'GZ curve and the IMO intact stability criteria for a {L} x {B} x {D} m hull at {Tt} m draft, KG {kg} m.', 'gz_curve', {'L': L, 'B': B, 'D': D, 'T': Tt, 'kg': kg, 'draft': Tt})

    def motions():
        L, B, D, Tt = hull()
        kg = round(D * r.uniform(0.55, 0.75), 1)
        w = r.choice([6, 8, 10, 12])
        return one(f'Natural periods and the response in {w} s waves of a {L} x {B} x {D} m hull at {Tt} m draft, KG {kg} m.', 'hull_motions',
                   {'L': L, 'B': B, 'D': D, 'T': Tt, 'kg': kg, 'wave_period_s': w, 'wave_amplitude_m': 1.0})

    def stlstab():
        L, B, D, Tt = hull()
        kg = round(D * r.uniform(0.55, 0.75), 1)
        g = {'L': L, 'B': B, 'D': D, 'T': Tt, 'name': 'hull_a'}
        h = T.call('hull_generate', g)
        if 'error' in h:
            return None
        fn = next((f for f in h.get('files', []) if f.endswith('.stl')), None)
        if not fn:
            return None
        args = {'file': fn, 'kg': kg, 'draft': Tt}
        s = T.call('stl_stability', args)
        if 'error' in s:
            return None
        q = f'Make a hull {L} x {B} x {D} m at {Tt} m draft and check its intact stability with KG {kg} m.'
        return [U(q), A(tool_block('hull_generate', g)), result_msg('hull_generate', h), A(tool_block('stl_stability', args)), result_msg('stl_stability', s), A(s['plain_english'])]

    def cat():
        lb, bt, tt = r.choice([10, 12, 15]), r.choice([1.5, 2.0, 2.5]), r.choice([0.6, 0.8, 1.0])
        v = r.choice([20.0, 40.0, 80.0])
        return one(f'Slender catamaran demihull, L/B {lb}, B/T {bt}, transom draft ratio {tt}, {v:g} m3 per hull, hulls {r.choice([3.0, 4.0, 5.0])} m apart.', 'catamaran_hull',
                   {'l_to_b': lb, 'b_to_t': bt, 'tt_to_t': tt, 'volume_m3': v, 'separation': 4.0})

    # ---- design blocks, frames, hull condition model
    def dbb():
        n = r.choice([2, 3])
        names = r.sample([('engine', 'machinery', 'box', [6, 3, 3], 3.5), ('tank_a', 'tanks', 'box', [8, 6, 4], 0.85), ('crew', 'accommodation', 'box', [10, 8, 3], 0.25), ('gen', 'machinery', 'cylinder', [2, 2, 3], 4.0)], n)
        blocks = [{'name': a, 'group': g, 'shape': s, 'size': sz, 'density': d, 'cg': [round(r.uniform(5, 60), 1), 0, 2.0]} for a, g, s, sz, d in names]
        req = [{'name': 'weight', 'metric': 'total_weight', 'direction': 'at_most', 'shall': 600.0, 'should': 450.0}]
        return one(f'Early design: {", ".join(b["name"] for b in blocks)} as blocks; total weight must stay under 600 t, ideally under 450 t. Sum them.', 'dbb_blocks', {'blocks': blocks, 'requirements': req})

    def frame():
        span, P = r.choice([4000, 6000, 8000]), r.choice([5000, 10000, 20000])
        model = {'materials': {'steel': {'E': 210000, 'nu': 0.3}}, 'sections': {'ipe': {'A': 3000, 'Iy': 2.0e7, 'Iz': 1.0e6, 'J': 5.0e4}}, 'nodes': {'A': [0, 0, 0], 'B': [span, 0, 0]},
                 'members': [{'name': 'M1', 'i': 'A', 'j': 'B', 'material': 'steel', 'section': 'ipe'}], 'supports': {'A': 'fixed'}, 'node_loads': [{'node': 'B', 'dir': 'FY', 'value': -P}]}
        return one(f'Cantilever beam {span} mm long, section area 3000 mm2, Iy 2e7 mm4, steel, {P} N down at the free end (N, mm, MPa). Deflection and reaction?', 'pynite_fea', {'model': model})

    def hcm():
        return one(r.choice(['Read the hull condition model ship_structure.xml: plates, stiffeners and mass.', 'What is in the OpenHCM file ship_structure.xml?']), 'openhcm_read', {'file': 'ship_structure.xml'})

    def limits():
        q, a_ = r.choice([
            ('Is propeller_bem good enough to choose the final propeller for my ship?', 'No. It is a blade-element-momentum estimate for a constant-pitch propeller and its efficiency is optimistic by about 10 %. Use it for what-if studies and the cavitation number; for the final pitch '
             'and section design use the design tool (lifting line) and then model tests or CFD and the class rules for cavitation and blade strength.'),
            ('Can hull_motions give me the real heave and pitch RAOs of my ship?', 'No. It gives natural periods and a simple regular-wave response from closed-form formulas, without strip theory or forward speed. It tells you whether a wave period is near resonance; '
             'real RAOs need a seakeeping program (strip theory or panel method) with your lines.'),
            ('Does nastran_plate_deck run the Nastran analysis?', 'No. It only writes the bulk data deck (the model). Run it in Nastran, MYSTRAN or another solver that reads this format; I can also solve the same plate with CalculiX in ShipBrain.')])
        return [U(q), A(a_)]

    gens = [(bem, 3), (bem_curve, 2), (design, 4), (design_missing, 1), (blade, 2), (nread, 2), (ndeck, 2), (resist, 3), (resist_range, 1), (gz, 3), (motions, 3), (stlstab, 2), (cat, 2),
            (dbb, 3), (frame, 2), (hcm, 1), (limits, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 5:
        tries += 1
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:120])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'late_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s and 'sb_lt_' not in s
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
