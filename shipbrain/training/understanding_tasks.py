"""
Training conversations that teach the model to understand users and drive the tools well (every tool result is a REAL
run; the wording is deliberately different from training/scorecard.jsonl so the scorecard still measures something):

  ask        a key input is missing -> one short, specific question; the user answers -> tool call -> answer
  assume     only a secondary input is missing -> state the assumption and go on (e.g. friction, fluid, grade)
  messy      feet / inches / psi / bar / kPa / gpm / m3/s / water head / NB sizes / Hinglish -> the tool's units, and
             the answer says how the units were read
  design     multi-step design loops: a result fails or is poor -> change the design -> run again -> conclude
  recover    a tool error -> read it -> fix the input -> run again (or explain what the user must decide)

    python training/understanding_tasks.py --n 400 --out training/data/understanding_train.jsonl.gz
"""
import argparse, gzip, json, math, os, random, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

SW = 1025 * 9.80665 * 1e-6            # MPa per metre of seawater head


def tb(name, args):
    from make_dataset import tool_block
    return tool_block(name, args)


def rm(name, res):
    from make_dataset import result_msg
    return result_msg(name, res)


def U(t):
    return {'role': 'user', 'content': t}


def A(t):
    return {'role': 'assistant', 'content': t}


def plate_answer(a, r):
    u = r.get('utilisation')
    edge = {'simply': 'simply supported', 'clamped': 'clamped'}.get(r.get('boundary'), r.get('boundary', 'given'))
    return (f"The {a['a']:g} x {a['b']:g} x {a['t']:g} mm plate under {a['q']:g} MPa ({edge} edges) reaches "
            f"{r['sigma_max_MPa']:.0f} MPa and deflects {r['w_max_mm']:.2f} mm" + (f" - utilisation {u:.2f}, {'OK' if u <= 1 else 'NOT OK'}" if u is not None else '')
            + '. (Roark hand formula, small deflection; check it against the class rule thickness as well.)')


def stiff_answer(a, r):
    u = r.get('utilisation')
    p = a['profile']
    return (f"{p['type']} {p['h']}x{p['t']} on {a['t_plate']:g} mm plate, span {a['span']:g}, spacing {a['spacing']:g}, {a['q']:g} MPa: "
            f"section modulus {r['Z_toe_cm3']:.0f} cm3 at the toe, stress {r['sigma_toe_MPa']:.0f} MPa, deflection {r['deflection_mm']:.1f} mm"
            + (f" - utilisation {u:.2f}, {'OK' if u <= 1 else 'NOT OK'}" if u is not None else '') + '.')


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=400)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'understanding_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from shipbrain import cabledyn
    r = random.Random(a.seed)
    T = agent.Tools(tempfile.mkdtemp(prefix='sb_ut_'), knowledge.load(None))
    have_cd = cabledyn.driver() is not None

    def run(name, args):
        return T.call(name, args)

    # ------------------------------------------------------------------ ask: missing key inputs, then follow through
    def ask_plate():
        A_, B_, t, q = r.choice([2000, 2400, 2800, 3200]), r.choice([600, 700, 800, 900]), r.choice([9, 10, 11, 12, 14]), r.choice([0.03, 0.05, 0.08, 0.1])
        q1 = r.choice(['Can you check this deck plating for me?', 'Plate strength check please', 'Is the tank top plating OK?',
                       'Deck plate check karna hai'])
        ask = r.choice(['Sure - I need the plate field size (stiffener spacing and the span between frames or webs), the thickness and the lateral pressure (or the water head). Are the edges welded to stiffeners (clamped) or should I take them as simply supported?',
                        'Yes. Please give me: the panel size (span x stiffener spacing, mm), plate thickness (mm), and the design pressure (MPa, bar or metres of head).'])
        reply = r.choice([f'{A_} x {B_}, {t} mm, {q} MPa', f'span {A_}, spacing {B_}, t={t}, pressure {q} MPa, clamped',
                          f'{A_/1000:g} m by {B_} mm, {t} mm thick, {q * 10:g} bar'])
        args = {'a': A_, 'b': B_, 't': t, 'q': q, 'boundary': 'clamped' if 'clamped' in reply or r.random() < 0.5 else 'simply'}
        res = run('plate_check', args)
        if 'error' in res:
            return None
        return [U(q1), A(ask), U(reply), A(tb('plate_check', args)), rm('plate_check', res), A(plate_answer(args, res))]

    def ask_mooring():
        if not have_cd:
            return None
        d, h = r.choice([64, 76, 84, 95, 102]), r.choice([60, 100, 150, 200])
        L = round(h * r.uniform(5, 8), -1)
        R = round(math.sqrt((0.9 * L) ** 2 - h ** 2), -1)
        q1 = r.choice([f'What tension will my {d} mm chain see?', 'Need a mooring check', f'Anchor chain {d} mm R3 - is it fine?'])
        ask = ('I can solve the catenary with CableDyn. I still need: the water depth, the total line length, and the '
               'horizontal distance from the fairlead to the anchor' + ('' if str(d) in q1 else ', plus the chain size and grade') + '.')
        reply = r.choice([f'{h} m deep, {L:g} m of chain, anchor {R:g} m away', f'depth {h}, length {L:g}, radius {R:g}'] ) + ('' if str(d) in q1 else f', {d} mm R3')
        args = {'depth': h, 'length': L, 'radius': R, 'd_mm': d, 'grade': 'R3'}
        res = run('mooring', args)
        if 'error' in res:
            return None
        return [U(q1), A(ask), U(reply), A(tb('mooring', args)), rm('mooring', res), A(res['plain_english'])]

    def ask_pipe():
        Q, d, L = r.choice([40, 80, 120, 200]), r.choice([80, 100, 125, 150, 200]), r.choice([20, 30, 50, 80])
        sysname = r.choice(['ballast', 'cooling water', 'fire main', 'bilge'])
        q1 = r.choice([f'How much pressure do we lose in the {sysname} line?', f'Pump size for the {sysname} system?',
                       f'{sysname} line ka head loss chahiye'])
        ask = ('To calculate it I need the flow rate (m3/h), the pipe bore and length of each run, how much it rises, and the '
               'valves / bends on the way. Seawater, I assume?')
        reply = f'{Q} m3/h, {d} mm bore, {L} m, ' + r.choice(['4 bends and a check valve', 'two gate valves, 6 elbows', 'mostly straight'])
        fit = ({'standard_elbow_90_deg': 4, 'swing_check_valve': 1} if 'check' in reply else
               {'gate_valve': 2, 'standard_elbow_90_deg': 6} if 'gate' in reply else {})
        args = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': L, 'fittings': fit}], 'fluid': 'seawater'}
        res = run('pipe_flow', args)
        if 'error' in res:
            return None
        return [U(q1), A(ask), U(reply), A(tb('pipe_flow', args)), rm('pipe_flow', res), A(res['plain_english'])]

    def ask_bolt():
        d, cls = r.choice([12, 16, 20, 24, 30]), r.choice(['8.8', '10.9'])
        q1 = r.choice(['What torque for the foundation bolts?', 'Bolt preload kitna hoga?', 'How tight should the flange bolts be?'])
        ask = 'Which bolt size and property class (e.g. M20, 8.8)? If you know the thread friction (lubricated or dry), give that too - otherwise I take 0.12.'
        reply = r.choice([f'M{d} {cls}', f'M{d}, class {cls}, dry'])
        args = {'d': d, 'cls': cls}
        if 'dry' in reply:
            args['mu_G'] = 0.16
        res = run('bolt', args)
        return [U(q1), A(ask), U(reply), A(tb('bolt', args)), rm('bolt', res), A(res['plain_english'])]

    # ------------------------------------------------------------------ assume: secondary input missing
    def assume_bolt():
        d, cls = r.choice([10, 12, 16, 20, 24]), r.choice(['8.8', '10.9', '12.9'])
        q1 = r.choice([f'M{d} {cls} tightening torque?', f'Preload of an M{d} grade {cls} bolt'])
        args = {'d': d, 'cls': cls}
        res = run('bolt', args)
        return [U(q1), A(tb('bolt', args)), rm('bolt', res),
                A(res['plain_english'] + ' I assumed thread and head friction 0.12 (lightly oiled); tell me if the bolts are dry or greased and I recalculate.')]

    def assume_pipe():
        Q, d, L = r.choice([60, 100, 150]), r.choice([100, 125, 150]), r.choice([30, 40, 60])
        q1 = f'Pressure loss for {Q} m3/h in {L} m of {d} mm pipe?'
        args = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': L}], 'fluid': 'seawater'}
        res = run('pipe_flow', args)
        return [U(q1), A(tb('pipe_flow', args)), rm('pipe_flow', res),
                A(res['plain_english'] + ' I assumed seawater at 20 C in carbon steel pipe with no valves or bends - give me the fittings and the fluid if different.')]

    # ------------------------------------------------------------------ messy units
    def messy_plate():
        ft_a, ft_b = r.choice([6, 7, 8, 9, 10]), r.choice([2, 2.5, 3])
        t_in = r.choice([0.375, 0.5, 0.625])
        how = r.choice(['psi', 'head', 'kpa', 'bar'])
        if how == 'psi':
            p = r.choice([5, 7, 10, 15]); q = p * 0.00689476; ptxt = f'{p} psi'
        elif how == 'head':
            p = r.choice([3, 5, 8, 10]); q = p * SW; ptxt = f'{p} m of seawater head'
        elif how == 'kpa':
            p = r.choice([30, 50, 80]); q = p / 1000; ptxt = f'{p} kPa'
        else:
            p = r.choice([0.5, 1, 1.5]); q = p / 10; ptxt = f'{p} bar'
        t_frac = {0.375: '3/8', 0.5: '1/2', 0.625: '5/8'}[t_in]
        q1 = r.choice([f'plate {ft_a} ft x {ft_b} ft, {t_frac}" thick, {ptxt} - stress?',
                       f'{ft_a}ft by {ft_b}ft panel, {t_frac} inch plate, load {ptxt}. kitna stress?'])
        args = {'a': round(ft_a * 304.8, 1), 'b': round(ft_b * 304.8, 1), 't': round(t_in * 25.4, 2), 'q': round(q, 5)}
        res = run('plate_check', args)
        if 'error' in res:
            return None
        units = (f"(I read {ft_a} ft = {args['a']:g} mm, {ft_b} ft = {args['b']:g} mm, {t_frac} in = {args['t']:g} mm, "
                 f"{ptxt} = {args['q']:.4f} MPa.) ")
        return [U(q1), A(tb('plate_check', args)), rm('plate_check', res), A(units + plate_answer(args, res))]

    def messy_pipe():
        how = r.choice(['gpm', 'm3s', 'lps'])
        if how == 'gpm':
            v = r.choice([200, 400, 600, 900]); Q = v * 0.227125; qt = f'{v} gpm'
        elif how == 'm3s':
            v = r.choice([0.01, 0.02, 0.04]); Q = v * 3600; qt = f'{v} m3/s'
        else:
            v = r.choice([5, 10, 20]); Q = v * 3.6; qt = f'{v} l/s'
        inch = r.choice([3, 4, 6, 8])
        L_ft = r.choice([50, 100, 150])
        q1 = r.choice([f'{qt} through a {inch} inch line, {L_ft} ft long - pressure drop?', f'{inch}" pipe {L_ft} ft, flow {qt}. head loss batao'])
        args = {'flow_m3h': round(Q, 2), 'segments': [{'d_mm': round(inch * 25.4, 1), 'length_m': round(L_ft * 0.3048, 2)}], 'fluid': 'seawater'}
        res = run('pipe_flow', args)
        if 'error' in res:
            return None
        units = (f"({qt} = {args['flow_m3h']:g} m3/h, {inch} in = {args['segments'][0]['d_mm']:g} mm bore - nominal size, "
                 f"the real bore depends on the schedule - {L_ft} ft = {args['segments'][0]['length_m']:g} m; seawater assumed.) ")
        return [U(q1), A(tb('pipe_flow', args)), rm('pipe_flow', res), A(units + res['plain_english'])]

    def messy_mooring():
        if not have_cd:
            return None
        din = r.choice([2.5, 3, 3.5, 4])
        h_ft = r.choice([300, 400, 500])
        h = h_ft * 0.3048
        L = round(h * r.uniform(5, 7), 1)
        R = round(math.sqrt((0.9 * L) ** 2 - h ** 2), 1)
        q1 = f'{din} inch R3 chain, {h_ft} ft of water, {L / 0.3048:.0f} ft of chain, anchor {R / 0.3048:.0f} ft out - tension?'
        args = {'d_mm': round(din * 25.4, 1), 'depth': round(h, 2), 'length': round(L, 1), 'radius': round(R, 1), 'grade': 'R3'}
        res = run('mooring', args)
        if 'error' in res:
            return None
        return [U(q1), A(tb('mooring', args)), rm('mooring', res),
                A(f"({din} in = {args['d_mm']:g} mm, {h_ft} ft = {args['depth']:g} m.) " + res['plain_english'])]

    # ------------------------------------------------------------------ design loops (several tool calls)
    def design_pipe():
        Q = r.choice([120, 200, 300, 450])
        d0 = r.choice([80, 100, 125])
        L = r.choice([40, 60, 80])
        q1 = r.choice([f'Size the seawater line for {Q} m3/h, about {L} m long with 6 bends - start from {d0} mm',
                       f'{Q} m3/h ballast, {L} m route, 6 elbows. Is {d0} mm enough? If not, pick a better size.'])
        msgs = [U(q1)]
        d = d0
        note = ''
        for _ in range(4):
            args = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': L, 'fittings': {'standard_elbow_90_deg': 6}}], 'fluid': 'seawater'}
            res = run('pipe_flow', args)
            msgs += [A(note + tb('pipe_flow', args)), rm('pipe_flow', res)]
            v = res['segments'][0]['velocity_m_s']
            if v <= 3.0:
                break
            nxt = min(x for x in (100, 125, 150, 200, 250, 300, 350) if x > d)
            note = f'At {d} mm the velocity is {v:.1f} m/s - too fast for seawater (about 3 m/s at most). Trying {nxt} mm.\n'
            d = nxt
        if d == d0:
            ans = f'{d0} mm is enough: ' + res['plain_english']
        else:
            ans = f'Use {d} mm (not {d0} mm): ' + res['plain_english']
        msgs.append(A(ans))
        return msgs

    def design_plate():
        A_, B_, q = r.choice([2400, 2800, 3200]), r.choice([700, 800, 900]), r.choice([0.08, 0.12, 0.15, 0.2])
        t = r.choice([8, 9, 10])
        q1 = f'Plate {A_} x {B_} under {q} MPa, clamped - start with {t} mm and give me the thickness that passes (yield 235)'
        msgs, note = [U(q1)], ''
        for _ in range(8):
            args = {'a': A_, 'b': B_, 't': t, 'q': q, 'boundary': 'clamped', 'yield_MPa': 235}
            res = run('plate_check', args)
            if 'error' in res:
                return None
            msgs += [A(note + tb('plate_check', args)), rm('plate_check', res)]
            if res.get('utilisation', 2) <= 1.0:
                break
            note = f"{t} mm: {res['sigma_max_MPa']:.0f} MPa, utilisation {res['utilisation']:.2f} - too high. Trying {t + 1} mm.\n"
            t += 1
        msgs.append(A(f'{t} mm passes: ' + plate_answer(args, res) + ' The class rule minimum thickness can still be higher - check it with class_rule.'))
        return msgs

    def design_mooring():
        if not have_cd:
            return None
        h = r.choice([100, 150, 200])
        L = round(h * 3.2, -1)
        R = round(math.sqrt(L ** 2 - h ** 2) * 0.97, -1)
        msgs, note = [U(f'84 mm R3 chain, {h} m water, {L:g} m line, anchor at {R:g} m. Make sure no uplift at the anchor.')], ''
        for _ in range(5):
            args = {'depth': h, 'length': L, 'radius': R, 'd_mm': 84, 'grade': 'R3'}
            res = run('mooring', args)
            if 'error' in res:
                return None
            msgs += [A(note + tb('mooring', args)), rm('mooring', res)]
            if (res.get('grounded_length_m') or 0) > 0.05 * L:
                break
            note = f"With {L:g} m almost nothing lies on the seabed - the anchor would be pulled up. Lengthening the line by 20 %.\n"
            L = round(L * 1.2, -1)
        msgs.append(A(res['plain_english'] + f' A {L:g} m line keeps {res.get("grounded_length_m", 0):.0f} m on the bottom, so the anchor is not lifted.'))
        return msgs

    # ------------------------------------------------------------------ recover from tool errors
    def recover_fitting():
        Q, d = r.choice([60, 100, 150]), r.choice([100, 125, 150])
        bad, good = r.choice([('non_return_valve', 'swing_check_valve'), ('nrv', 'swing_check_valve'), ('elbow', 'standard_elbow_90_deg'),
                              ('bend_90', 'standard_elbow_90_deg'), ('ball', 'ball_valve'), ('tee', 'standard_tee_through_flow')])
        q1 = f'{Q} m3/h seawater, {d} mm, 30 m, with a {bad.replace("_", " ")} and 3 bends'
        a1 = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': 30, 'fittings': {bad: 1, 'standard_elbow_90_deg': 3}}], 'fluid': 'seawater'}
        e1 = run('pipe_flow', a1)
        a2 = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': 30, 'fittings': {good: 1 if good != 'standard_elbow_90_deg' else 4, **({} if good == 'standard_elbow_90_deg' else {'standard_elbow_90_deg': 3})}}], 'fluid': 'seawater'}
        res = run('pipe_flow', a2)
        return [U(q1), A(tb('pipe_flow', a1)), rm('pipe_flow', e1),
                A(f'"{bad}" is not a fitting name the tool knows; the matching one is {good}. Running again.\n' + tb('pipe_flow', a2)),
                rm('pipe_flow', res), A(res['plain_english'])]

    def recover_short_line():
        h, d = r.choice([150, 200, 300]), r.choice([76, 84])
        R = round(h * 2.5, -1)
        L = round(math.hypot(R, h) * 0.95, -1)
        args = {'depth': h, 'length': L, 'radius': R, 'd_mm': d}
        e1 = run('mooring', args)
        if 'error' not in e1:
            return None
        return [U(f'{d} mm chain, depth {h} m, {L:g} m long, anchor {R:g} m - check it'), A(tb('mooring', args)), rm('mooring', e1),
                A(f'That geometry is impossible: the straight distance from the fairlead to the anchor is about {math.hypot(R, h):.0f} m, '
                  f'longer than the {L:g} m line, so it would have to stretch. Either the line is longer (typically 4-8 x the depth for '
                  f'a catenary, e.g. {round(h * 5, -1):g} m), or the anchor is closer. Which one should I use?')]

    def recover_grade():
        d = r.choice([16, 20, 24])
        args = {'d': d, 'cls': '9.8'}
        e1 = run('bolt', args)
        a2 = {'d': d, 'cls': '8.8'}
        res = run('bolt', a2)
        return [U(f'M{d} grade 9.8 bolt torque?'), A(tb('bolt', args)), rm('bolt', e1),
                A('9.8 is not a standard ISO 898-1 class for this size - the usual ones are 8.8, 10.9 and 12.9. I take 8.8 (the most common); '
                  'tell me if it is 10.9.\n' + tb('bolt', a2)), rm('bolt', res), A(res['plain_english'])]

    # ------------------------------------------------------------------ memory: follow a user's earlier correction
    def mem_ctx(q_old, wrong, corr, count=1, disagrees=False):
        return (f'[memory m{r.randint(1, 40)}] Earlier a similar request ("{q_old}") was answered wrongly ("{wrong}"); the user '
                f'corrected it: {corr}' + (f' (corrected {count} times)' if count > 1 else '')
                + ('. NOTE: this correction does not match what the tool computed then - follow the tool\'s result and ask the '
                   'user if it matters.' if disagrees else '. Do it this way now.'))

    def memory_edges():
        A_, B_, t, q = r.choice([2400, 2800]), r.choice([700, 800]), r.choice([10, 12]), r.choice([0.05, 0.08])
        ctx = mem_ctx(f'Plate {A_ + 400} x {B_} x {t} at {q} MPa', 'I took simply supported edges',
                      'our deck plating is welded to the stiffeners - use clamped edges', r.choice([1, 2, 3]))
        args = {'a': A_, 'b': B_, 't': t, 'q': q, 'boundary': 'clamped'}
        res = run('plate_check', args)
        if 'error' in res:
            return None
        from shipbrain import agent as ag
        msgs = ag.attach_context([U(f'Plate field {A_} x {B_}, {t} mm, {q} MPa - stress?')], ctx)
        return msgs + [A(tb('plate_check', args)), rm('plate_check', res),
                       A(plate_answer(args, res) + ' (Clamped edges, as you corrected me before.)')]

    def memory_units():
        Q, d, L = r.choice([60, 100, 150]), r.choice([100, 125, 150]), r.choice([30, 40])
        ctx = mem_ctx(f'Pressure drop {Q + 20} m3/h in {d} mm pipe', 'answered in kPa only', 'always give pressure drop in bar and m head')
        args = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': L}], 'fluid': 'seawater'}
        res = run('pipe_flow', args)
        from shipbrain import agent as ag
        msgs = ag.attach_context([U(f'{Q} m3/h seawater through {L} m of {d} mm - pressure drop?')], ctx)
        return msgs + [A(tb('pipe_flow', args)), rm('pipe_flow', res), A(res['plain_english'])]

    def memory_disagrees():
        Q, d, L = r.choice([80, 120]), r.choice([100, 125]), r.choice([30, 50])
        args = {'flow_m3h': Q, 'segments': [{'d_mm': d, 'length_m': L}], 'fluid': 'seawater'}
        res = run('pipe_flow', args)
        claimed = round(res['pressure_drop_bar'] * r.choice([2.0, 2.5, 3.0]), 2)
        ctx = mem_ctx(f'{Q} m3/h in {d} mm pipe, {L} m', f"{res['pressure_drop_bar']:.2f} bar", f'it should be {claimed} bar', disagrees=True)
        from shipbrain import agent as ag
        msgs = ag.attach_context([U(f'Pressure drop for {Q} m3/h seawater, {d} mm pipe, {L} m?')], ctx)
        return msgs + [A(tb('pipe_flow', args)), rm('pipe_flow', res),
                       A(res['plain_english'] + f" Earlier you told me {claimed} bar for a line like this. The calculation for the pipe "
                         f"itself gives {res['pressure_drop_bar']:.2f} bar; the difference may be a strainer, cooler or valves that "
                         "were not in the description. Which items are in the line? I add them and run it again.")]

    gens = [(memory_edges, 3), (memory_units, 2), (memory_disagrees, 3), (ask_plate, 6), (ask_mooring, 4), (ask_pipe, 5), (ask_bolt, 3), (assume_bolt, 3), (assume_pipe, 3), (messy_plate, 7),
            (messy_pipe, 6), (messy_mooring, 3), (design_pipe, 5), (design_plate, 5), (design_mooring, 3), (recover_fitting, 4),
            (recover_short_line, 3), (recover_grade, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds = [], {}
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
        rows.append({'task': 'understand_' + g.__name__.split('_')[0], 'messages': m})
    for x in rows:                                        # a valid conversation: roles alternate
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), (x['task'], roles)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'conversations', kinds)


if __name__ == '__main__':
    main()
