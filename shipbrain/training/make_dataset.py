"""
Make fine-tuning data for ShipBrain (chat JSONL, one conversation per line: {"messages": [...]}).

Every sample uses the SAME system prompt and tool-call format as the app, and every tool result and number in the
final answer is produced by running the real tool - nothing is written by hand, so the model cannot learn wrong numbers.

  python training/make_dataset.py --n 4000 --out data/train.jsonl --eval-out data/eval.jsonl
  python training/make_dataset.py --n 4000 --knowledge D:\\ship_src\\rules_index.json ...   # + rule-book retrieval tasks (private: keep the output private)

Task families (weights in TASKS):
  mesh       natural-language panel request (m / mm, FB / T / L / HP notation, water head, edges) -> panel_mesh(spec) -> summary
  mesh_fix   request with an impossible value -> tool error -> corrected call -> summary   (teaches recovery)
  mesh_assume request missing values -> defaults stated as assumptions
  plate      plate field under pressure -> plate_check
  stiff      stiffener check -> stiffener_check
  buckle     plate buckling -> plate_buckling
  section    section modulus -> section_props
  calc       arithmetic -> calc
  rules      rule question -> knowledge_search -> answer citing ids     (only with --knowledge)
  chat       short explanation questions answered without tools (method knowledge)
"""
import argparse, json, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import math   # noqa: E402
from shipbrain import agent, mesh, fea, knowledge   # noqa: E402
from shipbrain.examples import Examples   # noqa: E402

R = random.Random(0)


# ------------------------------------------------------------------ phrasing helpers
def mm_or_m(v, r):
    if v >= 1000 and r.random() < 0.5:
        return f'{v / 1000:g} m'
    return f'{v:g} mm' if r.random() < 0.7 else f'{v:g}'


def prof_text(p, r):
    t = p['type']
    if t == 'FlatBar':
        return r.choice([f"FB {p['h']:g}x{p['t']:g}", f"flat bar {p['h']:g}x{p['t']:g}", f"FB{p['h']:g}*{p['t']:g}"])
    if t == 'TBar':
        return r.choice([f"T {p['h']:g}x{p['t']:g}/{p['bf']:g}x{p['tf']:g}", f"T-bar {p['h']:g}x{p['t']:g} + {p['bf']:g}x{p['tf']:g}",
                         f"tee web {p['h']:g}x{p['t']:g} flange {p['bf']:g}x{p['tf']:g}"])
    if t == 'LBar':
        return r.choice([f"L {p['h']:g}x{p['bf']:g}x{p['t']:g}/{p['tf']:g}", f"angle {p['h']:g}x{p['bf']:g} web {p['t']:g} flange {p['tf']:g}"])
    return r.choice([f"HP {p['h']:g}x{p['t']:g}", f"bulb flat {p['h']:g}x{p['t']:g}"])


def rand_profile(r, big=False):
    if big:
        h = r.choice([300, 350, 400, 450, 500, 600, 700, 800])
        return {'type': 'TBar', 'h': float(h), 't': float(r.choice([9, 10, 11, 12])), 'bf': float(r.choice([100, 120, 150, 200])),
                'tf': float(r.choice([12, 14, 15, 16, 18, 20]))}
    t = r.choice(['FlatBar', 'FlatBar', 'HP', 'LBar', 'TBar'])
    if t == 'FlatBar':
        return {'type': t, 'h': float(r.choice([75, 100, 125, 150, 180, 200])), 't': float(r.choice([8, 10, 12, 15]))}
    if t == 'HP':
        return {'type': t, 'h': float(r.choice([120, 140, 160, 180, 200, 220, 240, 260])), 't': float(r.choice([8, 9, 10, 11, 12]))}
    if t == 'LBar':
        return {'type': t, 'h': float(r.choice([150, 200, 250, 300])), 't': float(r.choice([9, 10, 11])), 'bf': float(r.choice([75, 90, 100])),
                'tf': float(r.choice([10, 12, 14]))}
    return {'type': t, 'h': float(r.choice([200, 250, 300])), 't': float(r.choice([9, 10])), 'bf': float(r.choice([80, 100])),
            'tf': float(r.choice([10, 12]))}


def tool_block(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}, separators=(', ', ': ')) + '\n```'


def _q(x):
    """a number as the model sees it in the shortened tool result (5 significant digits)"""
    return f'{float(f"{x:.5g}"):g}'


def result_msg(name, res):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(res)}       # same as at run time


# ------------------------------------------------------------------ tasks
def t_mesh(r, tools, mode='plain'):
    L = float(r.choice([2400, 3200, 3600, 4000, 4800, 5600, 6000, 7200, 8000, 9600]))
    B = float(r.choice([1600, 2000, 2400, 2800, 3200, 3600, 4000, 4800]))
    t = float(r.choice([6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20]))
    s_sp = float(r.choice([500, 600, 650, 700, 750, 800, 850, 900]))
    f_sp = float(r.choice([1600, 2000, 2400, 2800, 3200, 0]))
    sp, fp = rand_profile(r), rand_profile(r, big=True)
    e = float(r.choice([50, 75, 100, 125, 150]))
    while (L / e) * (B / e) > 4000:
        e += 25
    head = r.choice([0, 0, 2, 3, 5, 8, 10, 12])
    bc = r.choice(['simply', 'clamped', 'simply'])
    model = r.choice(['shell', 'shell', 'beam'])
    direction = r.choice(['x', 'x', 'x', 'y'])
    kind = r.choice(['deck', 'bulkhead', 'side shell', 'bottom', 'deck'])
    spec = {'name': f"{kind.replace(' ', '_')}_{int(L)}x{int(B)}", 'length': L, 'width': B, 'thickness': t,
            'stiffeners': {'direction': direction, 'spacing': s_sp, 'profile': sp},
            'frames': ({'spacing': f_sp, 'profile': fp} if f_sp else None),
            'element_size': e, 'stiffener_model': model, 'pressure': round(head * 0.01005, 5), 'boundary': bc}
    parts = [r.choice(['Mesh a', 'Make an FE mesh of a', 'Create a', 'Build me a', 'Please model a', 'Generate the mesh for a',
                       'mesh banao ek', 'I need a mesh of a']),
             f"{kind} panel {mm_or_m(L, r)} x {mm_or_m(B, r)},",
             r.choice([f'plate {t:g} mm', f't={t:g}', f'{t:g} mm plating', f'thickness {t:g}']) + ',',
             f"{prof_text(sp, r)} stiffeners at {s_sp:g}" + (' along the length' if direction == 'x' and r.random() < .3 else
                                                            (' running across (along Y)' if direction == 'y' else '')) + ',']
    if f_sp:
        parts.append(f"{r.choice(['web frames', 'frames', 'transverses', 'girders'])} {prof_text(fp, r)} every {mm_or_m(f_sp, r)},")
    else:
        parts.append(r.choice(['no frames,', 'no web frames inside,', '']))
    parts.append(f'element size {e:g}' + ('' if r.random() < .7 else ' mm') + ',')
    if model == 'beam':
        parts.append(r.choice(['stiffeners as beams,', 'beam elements for stiffeners,', 'CBAR stiffeners,']))
    if head:
        parts.append(r.choice([f'{head} m water head,', f'{head} m head of sea water,', f'pressure {spec["pressure"]:g} MPa,']))
    parts.append(r.choice([f'{bc} supported edges', f'{bc} edges', 'edges ' + bc]) if bc == 'simply' else r.choice(['clamped edges', 'fixed edges', 'all edges clamped']))
    if mode == 'assume':                      # drop thickness + element size: the model must assume and say so
        parts = [p for p in parts if not any(k in p for k in ('plate ', 't=', 'plating', 'thickness', 'element size'))]
        spec['thickness'], spec['element_size'] = 12.0, 100.0
        while (L / spec['element_size']) * (B / spec['element_size']) > 4000:
            spec['element_size'] += 25
    user = ' '.join(parts).rstrip(',')
    msgs = [{'role': 'user', 'content': user}]
    if mode == 'fix':                         # first call has a bad value, tool says why, model corrects
        bad = json.loads(json.dumps(spec))
        bad['stiffeners']['profile'] = dict(bad['stiffeners']['profile'], t=0) if r.random() < .5 else bad['stiffeners']['profile']
        if bad['stiffeners']['profile']['t'] != 0:
            bad['boundary'] = 'fixed'
        err = tools.call('panel_mesh', bad)
        if 'error' not in err:
            return None
        msgs += [{'role': 'assistant', 'content': tool_block('panel_mesh', bad)}, result_msg('panel_mesh', err)]
    pre = ''
    if mode == 'assume':
        pre = f"Plate thickness and element size were not given - I assume t = 12 mm and element size {spec['element_size']:g} mm.\n"
    res = tools.call('panel_mesh', json.loads(json.dumps(spec)))
    if 'error' in res:
        return None
    msgs += [{'role': 'assistant', 'content': pre + tool_block('panel_mesh', spec)}, result_msg('panel_mesh', res)]
    fr = f"frames at {', '.join(f'{x:g}' for x in res['frames_at_mm'])} mm" if res['frames_at_mm'] else 'no frames'
    ans = (f"Mesh **{res['name']}** is ready: {res['nodes']} nodes, {res['elements']} elements "
           f"({res['quads']} CQUAD4" + (f", {res['bars']} CBAR" if res['bars'] else '') + ").\n\n"
           f"- Stiffeners at {', '.join(f'{x:g}' for x in res['stiffeners_at_mm'])} mm; {fr}.\n"
           f"- Boundary: {res['boundary']}; pressure {res['pressure_MPa']:g} MPa on the plate (-Z).\n"
           f"- Quality: max aspect ratio {res['quality']['max_aspect_ratio']:g}.\n"
           f"- Files: {', '.join(res['files'].values())}.\n")
    chk = [c for c in res['checks'] if c != 'ok']
    ans += ('\nWarnings: ' + ' '.join(chk)) if chk else '\nChecks: ok.'
    if mode == 'assume':
        ans += f"\nAssumed: t = 12 mm, element size {spec['element_size']:g} mm - tell me if they differ."
    msgs.append({'role': 'assistant', 'content': ans})
    return msgs


def t_plate(r, tools):
    a, b = float(r.choice([1600, 2000, 2400, 2800, 3200])), float(r.choice([500, 600, 700, 800, 900]))
    t, q = float(r.choice([6, 8, 9, 10, 11, 12, 14])), round(r.choice([0.02, 0.03, 0.05, 0.06, 0.08, 0.1, 0.15]), 3)
    bc = r.choice(['simply', 'clamped'])
    user = r.choice([f'Check a plate field {a:g} x {b:g} x {t:g} mm under {q:g} MPa, {bc} supported',
                     f'What is the max stress in a {t:g} mm plate, {b:g} mm stiffener spacing, {a:g} mm span, pressure {q:g} MPa ({bc})?',
                     f'plate {a:g}x{b:g} t{t:g}, q={q:g} N/mm2, edges {bc}: stress and deflection?'])
    args = {'a': a, 'b': b, 't': t, 'q': q, 'boundary': bc}
    res = tools.call('plate_check', args)
    ans = (f"Max bending stress **{_q(res['sigma_max_MPa'])} MPa**, max deflection **{_q(res['w_max_mm'])} mm** "
           f"(Roark, {bc} edges, a/b = {res['aspect']:g}, beta = {res['beta']:g}). Utilisation vs 235 MPa: {res['utilisation']:g}."
           + (' ' + res['note'].split('; ', 1)[1] + '.' if '; ' in res['note'] else ''))
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('plate_check', args)},
            result_msg('plate_check', res), {'role': 'assistant', 'content': ans}]


def t_stiff(r, tools):
    p = rand_profile(r)
    span, s, t = float(r.choice([1600, 2000, 2400, 2800, 3200])), float(r.choice([600, 700, 800, 900])), float(r.choice([8, 10, 12, 14]))
    q, end = round(r.choice([0.03, 0.05, 0.08, 0.1]), 3), r.choice(['clamped', 'simply'])
    user = f"Check stiffener {prof_text(p, r)}, span {span:g}, spacing {s:g}, plate {t:g} mm, pressure {q:g} MPa, {end} ends"
    args = {'span': span, 'spacing': s, 't_plate': t, 'profile': p, 'q': q, 'end': end}
    res = tools.call('stiffener_check', args)
    ans = (f"Section modulus with {res['effective_breadth_mm']:g} mm plating: Z_toe = {res['Z_toe_cm3']:g} cm3, Z_plate = {res['Z_plate_cm3']:g} cm3.\n"
           f"Stress at toe **{_q(res['sigma_toe_MPa'])} MPa**, at plate {res['sigma_plate_MPa']:g} MPa, deflection {res['deflection_mm']:g} mm "
           f"({end} ends). Utilisation {res['utilisation']:g} " + ('- OK.' if res['utilisation'] <= 1 else '- **exceeds yield, increase the profile**.'))
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('stiffener_check', args)},
            result_msg('stiffener_check', res), {'role': 'assistant', 'content': ans}]


def t_buckle(r, tools):
    a, b, t = float(r.choice([2400, 3200, 4000])), float(r.choice([600, 700, 800, 900])), float(r.choice([8, 10, 12, 14, 16]))
    args = {'a': a, 'b': b, 't': t}
    res = tools.call('plate_buckling', args)
    return [{'role': 'user', 'content': f'Buckling stress of plate {a:g} x {b:g} x {t:g} in longitudinal compression?'},
            {'role': 'assistant', 'content': tool_block('plate_buckling', args)}, result_msg('plate_buckling', res),
            {'role': 'assistant', 'content': f"Elastic buckling stress {res['sigma_E_MPa']:g} MPa (k = 4, b/t = {res['b_over_t']:g}); "
                                             f"critical stress after Johnson-Ostenfeld **{res['sigma_cr_MPa']:g} MPa**."}]


def t_section(r, tools):
    p = rand_profile(r)
    t, be = float(r.choice([8, 10, 12, 14])), float(r.choice([500, 600, 700, 800]))
    args = {'profile': p, 't_plate': t, 'b_eff': be}
    res = tools.call('section_props', args)
    w = res['with_plate']
    return [{'role': 'user', 'content': f'Section modulus of {prof_text(p, r)} with {be:g} mm of {t:g} mm plating?'},
            {'role': 'assistant', 'content': tool_block('section_props', args)}, result_msg('section_props', res),
            {'role': 'assistant', 'content': f"Profile alone: A = {res['A']:g} mm2. With plating: I = {w['I_cm4']:g} cm4, "
                                             f"Z at toe **{w['Z_toe_cm3']:g} cm3**, Z at plate {w['Z_plate_cm3']:g} cm3, neutral axis "
                                             f"{w['z_na_mm']:g} mm below plate mid-plane."}]


def t_calc(r, tools):
    """small engineering arithmetic through the calc tool (the answer quotes the tool's value, never re-computes it)"""
    v = lambda x: format(float('%.5g' % x), 'g')
    if r.random() < 0.5:
        h = round(r.uniform(0.5, 25), r.choice([0, 1]))
        expr = f'1.025*9.81*{h:g}/1000'
        q = r.choice([f'Pressure in MPa of {h:g} m sea water head?', f'What is {h:g} m of sea water in MPa?',
                      f'{h:g} m head ka pressure kitna MPa?', f'Convert a {h:g} m sea water head to pressure'])
        res = tools.call('calc', {'expression': expr})
        ans = 'p = rho g h = 1.025 t/m3 x 9.81 x %s m = **%s MPa** (value from calc).' % (f'{h:g}', v(res['value']))
    else:
        L, B, t = r.choice(range(500, 12001, 100)), r.choice(range(300, 4001, 50)), r.choice([6, 8, 10, 12, 14, 15, 16, 18, 20, 25])
        expr = f'{L}*{B}*{t}*7.85e-6'
        q = r.choice([f'Weight of a steel plate {L} x {B} x {t} mm in kg?', f'How heavy is a {t} mm plate of {L} x {B} mm (steel)?',
                      f'steel plate {L}x{B}x{t} weight?'])
        res = tools.call('calc', {'expression': expr})
        ans = 'm = L x B x t x 7.85e-6 kg/mm3 = **%s kg** (value from calc).' % v(res['value'])
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('calc', {'expression': expr})},
            result_msg('calc', res), {'role': 'assistant', 'content': ans}]


def t_plates(r, tools):
    """grillage: deck + longitudinal girders + transverse web frames (+ optional opening) -> plates_mesh"""
    L = float(r.choice([4000, 4800, 6000, 7200, 8000]))
    B = float(r.choice([2400, 3000, 3200, 4000]))
    t = float(r.choice([8, 10, 12, 14]))
    ng, nf = r.choice([1, 2, 3]), r.choice([0, 1, 2])
    hg, hf = float(r.choice([400, 500, 600, 800])), float(r.choice([600, 800, 1000]))
    tg, tf = float(r.choice([10, 11, 12])), float(r.choice([9, 10, 12]))
    h = float(r.choice([150, 200, 250]))
    ys = [round(B * (k + 1) / (ng + 1)) for k in range(ng)]
    xs = [round(L * (k + 1) / (nf + 1)) for k in range(nf)]
    deck = {'id': 'DECK', 't': t, 'outline': [[0, 0, 0], [L, 0, 0], [L, B, 0], [0, B, 0]]}
    hole = None
    if r.random() < 0.4 and ng >= 1:
        y0 = ys[0] + 150 if ng == 1 else (ys[0] + ys[1]) / 2 - 300
        x0 = (xs[0] + 400) if xs else L / 2 - 500
        w, d = 800.0, 500.0
        if y0 + d < (ys[1] if ng > 1 else B) - 100 and x0 + w < L - 200:
            hole = [x0, y0, w, d]
            deck['holes'] = [[[x0, y0, 0], [x0 + w, y0, 0], [x0 + w, y0 + d, 0], [x0, y0 + d, 0]]]
    plates = [deck]
    plates += [{'id': f'GIR{k + 1}', 't': tg, 'outline': [[0, y, 0], [L, y, 0], [L, y, -hg], [0, y, -hg]]} for k, y in enumerate(ys)]
    plates += [{'id': f'WEB{k + 1}', 't': tf, 'outline': [[x, 0, 0], [x, B, 0], [x, B, -hf], [x, 0, -hf]]} for k, x in enumerate(xs)]
    head = r.choice([0, 3, 5, 8])
    args = {'name': f'grillage_{int(L)}x{int(B)}', 'element_size': h, 'plates': plates,
            'loads': [{'plates': ['DECK'], 'pressure': round(head * 0.01005, 5)}] if head else [],
            'fix': [{'x': 0}, {'x': L}]}
    user = (f"{r.choice(['Mesh a grillage:', 'Model this deck structure:', 'Create FE mesh -', 'grillage mesh banao:'])} deck {mm_or_m(L, r)} x "
            f"{mm_or_m(B, r)}, t={t:g}; {ng} longitudinal girder{'s' if ng > 1 else ''} {hg:g}x{tg:g} at y = {', '.join(f'{y:g}' for y in ys)}"
            + (f"; {nf} transverse web frame{'s' if nf > 1 else ''} {hf:g}x{tf:g} at x = {', '.join(f'{x:g}' for x in xs)}" if nf else '; no web frames')
            + (f"; opening {hole[2]:g}x{hole[3]:g} with corner at ({hole[0]:g}, {hole[1]:g})" if hole else '')
            + (f'; {head} m head on the deck' if head else '') + f'; ends x=0 and x={L:g} clamped; element size {h:g}')
    res = tools.call('plates_mesh', json.loads(json.dumps(args)))
    if 'error' in res:
        return None
    c = res['check']
    ans = (f"Mesh **{res['name']}**: {res['nodes']} nodes, {res['elements']} elements ({res['quads']} quads, {res['trias']} trias), "
           f"{res['plates']} plates joined along {res['joint_segments']} joint segments.\n\n"
           f"- Connectivity: {c['parts']} part, {c['free_nodes']} free nodes, {c['duplicate_nodes']} duplicate nodes.\n"
           f"- Quality: max aspect {c['quality']['max_aspect']}, corner angles {c['quality']['min_angle']}-{c['quality']['max_angle']} deg.\n"
           f"- Files: {', '.join(res['files'].values())}.\n\nCheck verdict: {c['verdict']}.")
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('plates_mesh', args)},
            result_msg('plates_mesh', res), {'role': 'assistant', 'content': ans}]


CAD_FAMILIES = [
    ('flat bar {h:g}x{t:g}, {L:g} long', lambda r: dict(L=float(r.choice([1200, 2000, 2400, 3200])), h=float(r.choice([100, 150, 200])), t=float(r.choice([8, 10, 12]))),
     'L, h, t = {L:g}, {h:g}, {t:g}\nresult = cq.Workplane("YZ").rect(t, h, centered=(True, False)).extrude(L)',
     lambda p: ([p['L'], p['t'], p['h']], p['L'] * p['h'] * p['t'])),
    ('plate {L:g} x {B:g} x {t:g} with a {d:g} mm hole in the middle', lambda r: dict(L=float(r.choice([800, 1000, 1500])), B=float(r.choice([600, 800, 1000])), t=float(r.choice([8, 10, 12, 15])), d=float(r.choice([100, 150, 219, 273]))),
     'L, B, t, d = {L:g}, {B:g}, {t:g}, {d:g}\nresult = cq.Workplane("XY").rect(L, B).extrude(t).faces(">Z").workplane().hole(d)',
     lambda p: ([p['L'], p['B'], p['t']], (p['L'] * p['B'] - math.pi * p['d'] ** 2 / 4) * p['t'])),
    ('box girder {L:g} long, {B:g} wide, {H:g} high, plates {t:g} thick', lambda r: dict(L=float(r.choice([3000, 6000])), B=float(r.choice([600, 800])), H=float(r.choice([500, 600, 800])), t=float(r.choice([10, 12, 14]))),
     'L, B, H, t = {L:g}, {B:g}, {H:g}, {t:g}\nresult = cq.Workplane("YZ").rect(B, H).rect(B - 2 * t, H - 2 * t).extrude(L)',
     lambda p: ([p['L'], p['B'], p['H']], p['L'] * (p['B'] * p['H'] - (p['B'] - 2 * p['t']) * (p['H'] - 2 * p['t'])))),
    ('T-bar web {hw:g}x{tw:g} flange {bf:g}x{tf:g}, {L:g} long', lambda r: dict(L=float(r.choice([2000, 3200])), hw=float(r.choice([300, 400, 500])), tw=float(r.choice([9, 10, 12])), bf=float(r.choice([100, 150, 200])), tf=float(r.choice([12, 15, 20]))),
     'L, hw, tw, bf, tf = {L:g}, {hw:g}, {tw:g}, {bf:g}, {tf:g}\nweb = cq.Workplane("XY").box(L, tw, hw - tf, centered=(False, True, False)).translate((0, 0, -(hw - tf)))\nflange = cq.Workplane("XY").box(L, bf, tf, centered=(False, True, False)).translate((0, 0, -hw))\nresult = web.union(flange)',
     lambda p: ([p['L'], p['bf'], p['hw']], p['L'] * ((p['hw'] - p['tf']) * p['tw'] + p['bf'] * p['tf']))),
]


def t_cad(r, tools):
    """text -> CadQuery script -> cadquery_build with the user's sizes as expect -> verified answer"""
    desc, gen, code, exp = r.choice(CAD_FAMILIES)
    p = gen(r)
    bbox, vol = exp(p)
    user = r.choice(['Make a 3D model of a ', 'CAD model: ', 'Create STEP for a ', 'Model a ']) + desc.format(**p)
    args = {'name': desc.split()[0].replace('-', '_') + '_part', 'code': 'import cadquery as cq\n' + code.format(**p),
            'expect': {'bbox': bbox, 'volume': round(vol, 1)}}
    res = tools.call('cadquery_build', json.loads(json.dumps(args)))
    if not res.get('ok') or not res.get('pass'):
        return None
    ans = (f"Built and checked: bbox {res['bbox']} mm, volume {res['volume']:g} mm3, {res['n_solids']} solid - "
           + '; '.join(res['checks']) + f".\nFiles: {', '.join(res['files'])}.")
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('cadquery_build', args)},
            result_msg('cadquery_build', res), {'role': 'assistant', 'content': ans}]


def t_program(r, tools):
    """natural-language structure request -> build_structure with a SHORT building-block program (CAD2Program lesson)"""
    L = float(r.choice([4000, 4800, 6000, 7200, 8000, 9600]))
    B = float(r.choice([2400, 3000, 3200, 4000, 4800]))
    t = float(r.choice([8, 10, 12, 14]))
    ng, nw = r.choice([0, 1, 2]), r.choice([0, 1, 2])
    hg, tg, hw, tw = float(r.choice([400, 600, 800])), float(r.choice([10, 12])), float(r.choice([600, 800, 1000])), float(r.choice([9, 10, 12]))
    ys = [round(B * (k + 1) / (ng + 1)) for k in range(ng)]
    xs = [round(L * (k + 1) / (nw + 1)) for k in range(nw)]
    sp = float(r.choice([500, 600, 700, 800]))
    prof = r.choice(['FB150x12', 'FB120x10', 'HP200x10', 'HP180x9', 'L200x90x10/14', 'T300x10/100x12'])
    lines = [f'deck L={L:g} B={B:g} t={t:g}'] + [f'girder y={y:g} h={hg:g} t={tg:g}' for y in ys] + [f'web x={x:g} h={hw:g} t={tw:g}' for x in xs]
    words = [f"{r.choice(['Deck', 'deck panel', 'Deck structure'])} {mm_or_m(L, r)} x {mm_or_m(B, r)}, {t:g} mm plate"]
    if ys:
        words.append(f"{len(ys)} girder{'s' if len(ys) > 1 else ''} {hg:g}x{tg:g} at y = {', '.join(f'{y:g}' for y in ys)}")
    if xs:
        words.append(f"web frame{'s' if len(xs) > 1 else ''} {hw:g}x{tw:g} at x = {', '.join(f'{x:g}' for x in xs)}")
    if r.random() < 0.4 and L >= 4800:
        ox, oy = round(L * 0.65), round(B * 0.35)
        w, h = 800.0, 600.0
        if all(not (oy < y < oy + h) for y in ys) and all(not (ox < x < ox + w) for x in xs):
            lines.append(f'opening x={ox:g} y={oy:g} w={w:g} h={h:g}')
            words.append(f'an opening {w:g}x{h:g} at ({ox:g}, {oy:g})')
    lines.append(f'stiffeners spacing={sp:g} profile={prof}')
    words.append(f'{prof} stiffeners every {sp:g}')
    if r.random() < 0.6:
        head = r.choice([3, 5, 8])
        lines.append(f'load p={round(head * 0.01005, 4):g}')
        words.append(f'{head} m water head')
    lines += ['fix x=0', 'fix x=L']
    words.append('ends clamped')
    prog = '; '.join(lines)
    user = r.choice(['Build ', 'Model ', 'Mesh this: ', 'Create FE model - ', 'structure banao: ']) + ', '.join(words)
    args = {'program': prog, 'name': f'deck_{int(L)}x{int(B)}'}
    res = tools.call('build_structure', dict(args))
    if 'error' in res:
        return None
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('build_structure', args)},
            result_msg('build_structure', res), {'role': 'assistant', 'content': res['plain_english'] + f"\nFiles: {', '.join(res['files'].values())}."}]


_BANK = None


def _bank():
    """verified text-to-CAD items (training/cad_families.py): built and size-checked; read without CadQuery"""
    global _BANK
    if _BANK is None:
        import gzip
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'cad_bank.jsonl.gz')
        _BANK = [json.loads(l) for l in gzip.open(p, 'rt', encoding='utf-8')] if os.path.exists(p) else []
    return _BANK


def t_cad_bank(r, tools):
    """user asks for a part -> CadQuery script with the user's sizes as expect -> checked result; with a repair item the first
    script has a typical mistake, the tool says what is wrong, and the model fixes it"""
    b = _bank()
    if not b:
        return None
    it = r.choice(b)
    args = {'name': it['name'], 'code': it['code'], 'expect': it['expect']}
    res = it['result']
    msgs = [{'role': 'user', 'content': it['prompt']}]
    rep = it.get('repair')
    if rep and r.random() < 0.6:
        bad = dict(args, code=rep['bad_code'])
        msgs += [{'role': 'assistant', 'content': tool_block('cadquery_build', bad)}, result_msg('cadquery_build', rep['bad_result'])]
        why = {'size': 'one size did not match the request, corrected it', 'api': 'a CadQuery call was misspelt, corrected it',
               'result': 'the script did not set result, fixed it'}[rep['kind']]
        lead = f"First try failed ({why}). "
    else:
        lead = ''
    msgs += [{'role': 'assistant', 'content': tool_block('cadquery_build', args)}, result_msg('cadquery_build', res),
             {'role': 'assistant', 'content': lead + f"Built and checked: {res['n_solids']} solid, bounding box {res['bbox']} mm, "
                                                     f"volume {res['volume']:g} mm3 - " + '; '.join(res['checks'])
                                                     + f". Files: {', '.join(res['files'])}."}]
    return msgs


def _small_model(r, tools):
    L, B = float(r.choice([2000, 3000, 4000])), float(r.choice([1000, 1500, 2000]))
    name = f'model_{int(L)}x{int(B)}_{r.randint(100, 999)}'
    res = tools.call('plates_mesh', {'name': name, 'element_size': 250, 'plates': [
        {'id': 'P', 't': float(r.choice([8, 10, 12])), 'outline': [[0, 0, 0], [L, 0, 0], [L, B, 0], [0, B, 0]]},
        {'id': 'W', 't': 10.0, 'outline': [[0, B / 2, 0], [L, B / 2, 0], [L, B / 2, -400], [0, B / 2, -400]]}],
        'fix': [{'x': 0}], 'loads': [{'plates': ['P'], 'pressure': 0.02}]})
    return name, res


def t_fileinfo(r, tools):
    name, res = _small_model(r, tools)
    f = name + r.choice(['.bdf', '.inp'])
    q = r.choice([f'What is in {f}?', f'Explain the uploaded file {f} in simple words', f'{f} check karo - kya hai isme?', f'Tell me about {f}'])
    out = tools.call('file_info', {'file': f})
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('file_info', {'file': f})},
            result_msg('file_info', out), {'role': 'assistant', 'content': out['plain_english']}]


def t_convert(r, tools):
    name, res = _small_model(r, tools)
    src = name + '.bdf'
    to = r.choice([['inp'], ['mac'], ['inp', 'mac'], ['bdf', 'inp', 'mac']])
    words = {'inp': 'Abaqus/CalculiX', 'mac': 'ANSYS', 'bdf': 'Nastran'}
    q = f"Convert {src} to {' and '.join(words[t] for t in to)}"
    out = tools.call('fe_convert', {'file': src, 'to': to})
    if 'error' in out:
        return None
    ans = out['plain_english'] + (' The ANSYS file runs in MAPDL as it is; the _pymapdl.py script runs it from Python (needs an ANSYS licence).' if 'mac' in to else '')
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('fe_convert', {'file': src, 'to': to})},
            result_msg('fe_convert', out), {'role': 'assistant', 'content': ans}]


def t_edit(r, tools):
    name, res = _small_model(r, tools)
    src = name + '.bdf'
    choice = r.choice([
        ('Mirror {f} about the centre line y=0 to get the full breadth', [{'op': 'mirror', 'axis': 'y', 'value': 0}]),
        ('Refine the mesh in {f} (split every element)', [{'op': 'refine'}]),
        ('Make a solid (3D) model from the shells in {f}, 2 layers through the thickness', [{'op': 'shell_to_solid', 'layers': 2}]),
        ('Merge coincident nodes in {f} and renumber from 1001', [{'op': 'equivalence', 'tol': 0.1}, {'op': 'renumber', 'node_start': 1001, 'elem_start': 1001}]),
        ('Add beams on all free edges of {f}', [{'op': 'edges_to_beams', 'which': 'free'}])])
    q, ops = choice[0].format(f=src), choice[1]
    out = tools.call('fe_edit', {'file': src, 'ops': ops})
    if 'error' in out:
        return None
    s = out['model']
    ans = (f"Done. Saved as {out['file']}: {s['nodes']} nodes, {s['elements']} elements "
           f"({', '.join(f'{v} {k}' for k, v in s['by_dimension'].items() if v)}). The model is in {out['parts']} connected part(s); "
           f"mesh check: {out['check']}.")
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('fe_edit', {'file': src, 'ops': ops})},
            result_msg('fe_edit', out), {'role': 'assistant', 'content': ans}]


def t_clean(r, tools):
    L = float(r.choice([3000, 4000, 6000]))
    off = round(r.uniform(0.3, 1.5), 1)
    plates = [{'id': 'DECK', 't': 12.0, 'outline': [[0, 0, 0], [L, 0, 0], [L, 2000, 0], [0, 2000, 0]]},
              {'id': 'GIR', 't': 12.0, 'outline': [[0, 1000 + off, off], [L / 2, 1000, 0], [L, 1000, 0], [L, 1000, -500], [0, 1000, -500]]}]
    if r.random() < 0.5:
        plates.append(dict(plates[1], id='GIR_copy'))
    q = r.choice(['Clean this geometry before meshing: ', 'The CAD is dirty, fix it: ', 'Check and clean these plates: ']) + json.dumps(plates)
    out = tools.call('geometry_clean', {'plates': plates})
    ans = 'Cleaned. What I changed:\n' + '\n'.join('- ' + a for a in out['actions']) + f"\n{len(out['plates'])} plate(s) are ready to mesh."
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('geometry_clean', {'plates': plates})},
            result_msg('geometry_clean', out), {'role': 'assistant', 'content': ans}]


_REPAIR_ASK = {
    'holes_below': ['holes smaller than {v:g} mm', 'holes below {v:g}', 'bolt holes dia {v:g}', 'all holes up to {v:g} mm', 'openings < {v:g} mm'],
    'fillets_below': ['fillets below R{v:g}', 'rounds smaller than {v:g} mm', 'fillets up to r{v:g}', 'blends below {v:g} mm radius'],
    'chamfers_below': ['chamfers below {v:g}', 'chamfers under {v:g} mm', 'bevels up to {v:g} mm'],
    'bosses_below': ['pins under {v:g} mm', 'small bosses below dia {v:g}', 'studs smaller than {v:g} mm'],
}


def t_repair(r, tools):
    """uploaded CAD part + the user's clean-up words -> repair_model with the sizes read from the words -> verified result"""
    import cadquery as cq
    L, B, T = float(r.choice([160, 200, 240, 300])), float(r.choice([80, 100, 120])), float(r.choice([12, 16, 20]))
    hd, big, fr, ch, bd = (float(r.choice([10, 12, 14, 18, 22])), float(r.choice([40, 50, 60])), float(r.choice([5, 6, 8])),
                           float(r.choice([1.5, 2])), float(r.choice([8, 10])))
    b = cq.Workplane('XY').box(L, B, T).edges('|Z').fillet(fr)
    if r.random() < 0.6:
        b = b.edges('>Z').chamfer(ch)
    b = b.faces('<Z').workplane().pushPoints([(-L / 3, 0), (L / 3, 0)]).hole(hd)
    b = b.faces('<Z').workplane().hole(big)
    if r.random() < 0.5:
        b = b.faces('>Z').workplane().center(0, B / 3.5).circle(bd / 2).extrude(T * 0.6)
    from shipbrain import brep
    ext = '.stl' if brep.built() and r.random() < 0.3 else '.step'     # meshes (scans, print files) go through stl2step
    name = r.choice(['bracket', 'lug', 'foundation_plate', 'pad', 'insert']) + f'_{r.randint(100, 999)}{ext}'
    if ext == '.stl':
        cq.exporters.export(b, os.path.join(tools.workdir, name), tolerance=0.05, angularTolerance=0.1)
    else:
        cq.exporters.export(b, os.path.join(tools.workdir, name))
    lim = {'holes_below': hd + r.choice([2, 5, 8]), 'fillets_below': fr + r.choice([2, 4]), 'chamfers_below': ch + r.choice([1, 3]),
           'bosses_below': bd + r.choice([2, 4])}
    keys = r.sample(list(lim), r.choice([1, 2, 2, 3]))
    parts = [r.choice(_REPAIR_ASK[k]).format(v=lim[k]) for k in keys]
    head = r.choice(['Clean up {f} for FEA: remove ', 'Defeature {f} - remove ', 'Prepare {f} for meshing, take out ',
                     'I uploaded {f}. Please remove ', '{f}: simplify for FE, remove '])
    q = head.format(f=name) + (', '.join(parts[:-1]) + ' and ' + parts[-1] if len(parts) > 1 else parts[0])
    mesh = r.random() < 0.25
    if mesh:
        q += r.choice([', then mesh it at 20 mm', ' and mesh with 20 mm elements'])
    args = {'file': name, **{k: lim[k] for k in keys}}
    if mesh:
        args['mesh_size'] = 20.0
    out = tools.call('repair_model', args)
    if 'error' in out or not out.get('summary', {}).get('valid'):
        return None
    ans = out['plain_english']
    if mesh and isinstance(out.get('mesh'), dict) and 'error' not in out['mesh']:
        ans += ' ' + str(out['mesh'].get('plain_english') or f"Mesh: {out['mesh'].get('nodes')} nodes, {out['mesh'].get('elements')} elements.")
    if any('could not be removed' in a for a in out['actions']):
        ans += ' The features that were kept would break the solid if removed; remove them by hand in CAD, or mesh them as they are.'
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('repair_model', args)},
            result_msg('repair_model', out), {'role': 'assistant', 'content': ans}]


def t_fe_repair(r, tools):
    """dirty FE mesh (duplicates, a loose bit, a collapsed node) -> repair_model -> what was fixed"""
    from shipbrain.femodel import FEModel
    name, res = _small_model(r, tools)
    src = name + r.choice(['.bdf', '.inp'])
    m = FEModel.read(os.path.join(tools.workdir, src))
    eids = list(m.elems)
    for eid in r.sample(eids, min(len(eids), r.randint(1, 4))):
        m.add_elem(m.elems[eid]['type'], list(m.elems[eid]['nodes']), m.elems[eid]['pid'], 'DUP')
    if r.random() < 0.6:
        pid = next(p for p, v in m.props.items() if v.get('kind') == 'shell')
        a, b, c = (m.add_node([-900, 0, 0]), m.add_node([-800, 0, 0]), m.add_node([-800, 100, 0]))
        m.add_elem('tria', [a, b, c], pid, 'LOOSE')
    for n in r.sample(list(m.nodes), 2):
        m.add_node(m.nodes[n] + 0.001)                               # near-coincident free nodes
    m.write(os.path.join(tools.workdir, src))
    q = r.choice(['Repair the mesh {f} before solving', '{f} has duplicates and loose elements, clean it',
                  'Fix the FE model {f}: merge nodes, remove bad elements', 'Clean up {f} for FEA', 'Check and repair {f}']).format(f=src)
    out = tools.call('repair_model', {'file': src})
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('repair_model', {'file': src})},
            result_msg('repair_model', out), {'role': 'assistant', 'content': out['plain_english']}]


def t_surface(r, tools):
    """thin-solid model -> surface_extract (mid or outer) -> thickness groups"""
    import cadquery as cq
    parts, n = [], r.randint(2, 5)
    for k in range(n):
        t = float(r.choice([6, 8, 10, 12, 14, 16, 20]))
        L, B = float(r.choice([600, 800, 1200, 1600])), float(r.choice([300, 400, 600]))
        if r.random() < 0.3:                                   # bent plate (angle)
            p = cq.Workplane('XZ').polyline([(0, 0), (L / 2, 0), (L / 2, B / 2), (L / 2 - t, B / 2), (L / 2 - t, t), (0, t)]).close().extrude(B).val()
        else:
            p = cq.Workplane('XY').box(L, B, t).val()
        parts.append(p.translate(cq.Vector(0, k * 1500.0, 0)))
    if r.random() < 0.4:
        parts.append(cq.Workplane('XY').box(150, 150, 150).val().translate(cq.Vector(5000, 0, 0)))   # a block: not thin
    name = r.choice(['deck_panel', 'tank_top', 'foundation', 'web_frame', 'casing']) + f'_{r.randint(100, 999)}.step'
    cq.exporters.export(cq.Compound.makeCompound(parts), os.path.join(tools.workdir, name))
    kind = r.choice(['mid', 'mid', 'outer'])
    q = r.choice({'mid': ['Extract the mid surface of {f}', 'Make a mid-surface model from {f} for shell meshing',
                          '{f}: midsurface extraction please', 'Get mid surfaces with thickness from {f}'],
                  'outer': ['Extract the outer surface of {f}', 'Give me the outer skin surfaces of {f}',
                            '{f}: outer surface extraction']}[kind]).format(f=name)
    args = {'file': name, 'kind': kind}
    mesh = kind == 'mid' and r.random() < 0.3
    if mesh:
        q += ' and mesh it at 100 mm'
        args['mesh_size'] = 100.0
    out = tools.call('surface_extract', args)
    if 'error' in out:
        return None
    ans = out['plain_english']
    if mesh and isinstance(out.get('mesh'), dict) and 'nodes' in out['mesh']:
        ans += f" Mesh: {out['mesh']['nodes']} nodes, {out['mesh'].get('elements')} elements."
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('surface_extract', args)},
            result_msg('surface_extract', out), {'role': 'assistant', 'content': ans}]


def t_pipes(r, tools):
    """piping model (straights, elbows, tee, bolts) -> pipe_extract -> sizes, runs, 1D FE model"""
    import cadquery as cq
    od, w = r.choice([(60.3, 3.912), (88.9, 5.486), (114.3, 6.02), (168.275, 7.112), (219.075, 8.179)])
    L1, L2, R = float(r.choice([400, 600, 900])), float(r.choice([300, 500, 800])), round(od * r.choice([1.0, 1.5]), 1)
    hollow = r.random() < 0.5
    path = cq.Workplane('XY').moveTo(0, 0).lineTo(L1, 0).radiusArc((L1 + R, R), -R).lineTo(L1 + R, R + L2)
    prof = cq.Workplane('YZ').circle(od / 2)
    if hollow:
        prof = prof.circle(od / 2 - w)
    parts = [prof.sweep(path, transition='round').val()]
    for k in range(r.randint(0, 3)):
        parts.append(cq.Solid.makeCylinder(8, 50, cq.Vector(-300.0 - 40 * k, 300, 0)))   # bolts: left out
    name = r.choice(['pump_skid', 'cooling_line', 'fuel_pipe', 'ballast_line']) + f'_{r.randint(100, 999)}.step'
    cq.exporters.export(cq.Compound.makeCompound(parts), os.path.join(tools.workdir, name))
    sch = r.choice(['SCH40', 'SCH40', 'SCH80'])
    q = r.choice(['Find the pipes in {f}', 'Extract the piping from {f} and make a beam model', 'Pipe structure of {f}: sizes and bends?',
                  '{f}: recognise pipes, wall {s}', 'Make a 1D pipe FE model from {f} ({s})']).format(f=name, s=sch)
    args = {'file': name}
    if sch in q:
        args['schedule'] = sch
    out = tools.call('pipe_extract', args)
    if 'error' in out:
        return None
    b = out['bends'][0] if out['bends'] else None
    ans = out['plain_english'] + (f" Bend: OD {b['od']:g} mm, radius {b['bend_radius']:g} mm, {b['angle_deg']:g} deg." if b else '')
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('pipe_extract', args)},
            result_msg('pipe_extract', out), {'role': 'assistant', 'content': ans}]


_UNIT_SETS = {
    'in-lbf-psi': {'len': 'in', 'p': 'psi', 'stress': 'psi', 'defl': 'in', 'L': (60, 120), 'B': (20, 36), 't': (0.25, 0.75), 'q': (5, 25)},
    'm-kN-kPa': {'len': 'm', 'p': 'kPa', 'stress': 'MPa', 'defl': 'mm', 'L': (1.6, 3.2), 'B': (0.5, 0.9), 't': (0.008, 0.016), 'q': (20, 120)},
    'ft-kip-ksi': {'len': 'ft', 'p': 'psi', 'stress': 'ksi', 'defl': 'in', 'L': (5, 10), 'B': (2, 3), 't': (0.03, 0.06), 'q': (5, 20)},
}


def t_units(r, tools):
    """a user working in other units: convert in -> plate_check in mm/MPa -> convert out -> answer in the user's units"""
    system = r.choice(list(_UNIT_SETS))
    U = _UNIT_SETS[system]
    L, B = round(r.uniform(*U['L']), 2), round(r.uniform(*U['B']), 2)
    t, q = round(r.uniform(*U['t']), 3), round(r.uniform(*U['q']), 1)
    bc = r.choice(['simply', 'clamped'])
    with_profile = r.random() < 0.5
    if with_profile:                                         # the profile says the units: the question may omit them
        tools.profile.update(units=system)
        user = r.choice([f'Check a plate {L:g} x {B:g}, {t:g} thick, pressure {q:g}, {bc} edges',
                         f'Stress and deflection of a {bc} plate {L:g} by {B:g}, t = {t:g}, q = {q:g}?'])
    else:
        lu, pu = U['len'], U['p']
        user = r.choice([f'Check a plate {L:g} {lu} x {B:g} {lu}, {t:g} {lu} thick, under {q:g} {pu}, {bc} edges',
                         f'My plate is {L:g}x{B:g} {lu}, thickness {t:g} {lu}, pressure {q:g} {pu} ({bc}). Max stress and deflection?'])
    cin = {'values': [{'value': L, 'from': U['len'], 'to': 'mm'}, {'value': B, 'from': U['len'], 'to': 'mm'},
                      {'value': t, 'from': U['len'], 'to': 'mm'}, {'value': q, 'from': U['p'], 'to': 'MPa'}]}
    r1 = tools.call('convert_units', cin)
    a_, b_, t_, q_ = (c['result'] for c in r1['converted'])
    if b_ > a_:
        a_, b_ = b_, a_
    args = {'a': a_, 'b': b_, 't': t_, 'q': q_, 'boundary': bc}
    r2 = tools.call('plate_check', args)
    outs = [(r2['sigma_max_MPa'], 'MPa', U['stress']), (r2['w_max_mm'], 'mm', U['defl'])]
    need = [{'value': v, 'from': f, 'to': t_} for v, f, t_ in outs if f != t_]
    conv = {}
    tail = []
    if need:
        cout = {'values': need}
        r3 = tools.call('convert_units', cout)
        conv = {c['from']: c['result'] for c in r3['converted']}
        tail = [{'role': 'assistant', 'content': tool_block('convert_units', cout)}, result_msg('convert_units', r3)]
    s_u = _q(conv.get('MPa', r2['sigma_max_MPa']))
    w_u = _q(conv.get('mm', r2['w_max_mm']))
    extra_s = f" ({_q(r2['sigma_max_MPa'])} MPa)" if U['stress'] != 'MPa' else ''
    extra_w = f" ({_q(r2['w_max_mm'])} mm)" if U['defl'] != 'mm' else ''
    ans = (f"Max bending stress **{s_u} {U['stress']}**{extra_s}, max deflection **{w_u} {U['defl']}**{extra_w}, Roark, {bc} edges. "
           f"Utilisation vs 235 MPa: {r2['utilisation']:g}.")
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('convert_units', cin)},
            result_msg('convert_units', r1), {'role': 'assistant', 'content': tool_block('plate_check', args)},
            result_msg('plate_check', r2)] + tail + [{'role': 'assistant', 'content': ans}]


def t_profile(r, tools):
    """the user tells how they work -> set_profile"""
    units = r.choice(list(_UNIT_SETS) + ['mm-N-MPa'])
    mat = r.choice([('ASTM A36', 250), ('S355', 355), ('AH36', 355), ('S235', 235), ('6061-T6 aluminium', 240), ('316L stainless', 170)])
    code = r.choice(['AISC 360', 'Eurocode 3', 'DNV', 'ABS', 'Lloyd\'s Register', 'ASME VIII', None])
    field = r.choice(['offshore structures', 'pressure vessels', 'machine design', 'bridges', 'ship structures', 'automotive', None])
    lang = r.choice([None, None, 'Hindi', 'German', 'Spanish'])
    bits = [{'in-lbf-psi': 'I work in inches, pounds and psi', 'm-kN-kPa': 'we use metres, kN and kPa',
             'ft-kip-ksi': 'our drawings are in feet, kips and ksi', 'mm-N-MPa': 'I use mm and MPa'}[units],
            f'our material is {mat[0]} (yield {mat[1]} MPa)']
    if code:
        bits.append(f'we design to {code}')
    if field:
        bits.append(f'I work on {field}')
    if lang:
        bits.append(f'please answer in {lang}')
    r.shuffle(bits)
    q = r.choice(['FYI: ', 'Please remember: ', 'For all my questions: ', '']) + ', '.join(bits)
    args = {'units': units, 'material': mat[0], 'yield_MPa': float(mat[1])}
    if code:
        args['design_code'] = code
    if field:
        args['field'] = field
    if lang:
        args['language'] = lang
    out = tools.call('set_profile', args)
    tools.profile.data.clear()                               # samples after this one must not see this profile
    tools.profile.update()
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('set_profile', args)},
            result_msg('set_profile', out), {'role': 'assistant', 'content': out['plain_english']}]


_TEACH = [
    ('monthly-tank-check', 'monthly tank wall check', ['plate_check for each tank wall plate with 0.15 MPa', 'stiffener_check for the vertical stiffeners',
                                                       'list any utilisation above 0.9'], 'monthly tank'),
    ('new-bracket-model', 'make and check a new bracket model', ['cadquery_build the bracket from the sizes given', 'repair_model to remove holes below 15 mm',
                                                                 'cad_mesh at 10 mm'], 'new bracket'),
    ('hatch-report', 'hatch cover result report', ['result_insight on the latest .frd with yield 355', 'compare with the baseline run',
                                                   'write a three-line summary'], 'hatch report'),
    ('pipe-skid-check', 'check a pipe skid model', ['pipe_extract with SCH80', 'surface_extract mid for the frame', 'tell how many pipe runs there are'],
     'skid check'),
]


def t_add_skill(r, tools):
    """the user teaches a workflow in the chat -> add_skill (saved, used from then on)"""
    name, desc, steps, when = r.choice(_TEACH)
    lead = r.choice(['Whenever I say "{w}", do this: ', 'Remember this workflow for "{w}": ', 'New procedure - when I ask for a {w}: ',
                     'From now on, for a {w}: ']).format(w=when)
    q = lead + '; '.join(f'{i + 1}) {s}' for i, s in enumerate(steps))
    args = {'name': name, 'description': desc, 'steps': steps, 'when': when}
    out = tools.call('add_skill', args)
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('add_skill', args)},
            result_msg('add_skill', out), {'role': 'assistant', 'content': out['plain_english']}]


def t_frame(r, tools):
    """beam / portal / pipe-support questions -> frame_solve (Awatif's solver) -> governing member, PASS/FAIL"""
    from shipbrain import awatif
    if not awatif.available():
        return None
    kind = r.choice(['cantilever', 'beam', 'portal'])
    sec = r.choice([{'I': [300, 150, 7, 11]}, {'I': [400, 200, 8, 13]}, {'box': [200, 200, 8]}, {'pipe': [168.3, 7.1]},
                    {'rect': [100, 200]}])
    stxt = {'I': 'I {0}x{1}x{2}x{3}', 'box': 'box {0}x{1}x{2}', 'pipe': 'pipe OD {0} x {1}', 'rect': 'rectangle {0} x {1}'}
    k0 = next(iter(sec))
    st = stxt[k0].format(*sec[k0])
    if kind == 'cantilever':
        L, P = float(r.choice([1500, 2000, 3000])), float(r.choice([2000, 5000, 10000]))
        args = {'name': 'cantilever', 'nodes': {'A': [0, 0, 0], 'B': [L, 0, 0]}, 'members': [{'id': 'M1', 'n1': 'A', 'n2': 'B', 'section': sec}],
                'supports': {'A': 'fixed'}, 'loads': {'Q': [{'node': 'B', 'F': [0, 0, -P]}]}, 'combinations': {'ULS': {'Q': 1.5}, 'SLS': {'Q': 1.0}}}
        q = r.choice([f'Cantilever {L:g} mm, {st}, tip load {P:g} N: stress and deflection?',
                      f'Check a {L:g} mm long {st} cantilever with {P / 1000:g} kN at the free end (factor 1.5 for ULS)'])
    elif kind == 'beam':
        L, w = float(r.choice([3000, 4000, 6000])), float(r.choice([5, 10, 20]))
        args = {'name': 'beam', 'nodes': {'A': [0, 0, 0], 'B': [L, 0, 0]}, 'members': [{'id': 'M1', 'n1': 'A', 'n2': 'B', 'section': sec}],
                'supports': {'A': '1234', 'B': '23'}, 'loads': {'G': [{'self_weight': 1}], 'Q': [{'member': 'M1', 'w': [0, 0, -w]}]}}
        q = r.choice([f'Simply supported beam {L:g} mm, {st}, live load {w:g} N/mm plus self weight. Is it OK?',
                      f'{st} beam spanning {L / 1000:g} m, pinned at both ends, {w:g} kN/m imposed load: check it'])
    else:
        H, B, wl = float(r.choice([3000, 4000, 5000])), float(r.choice([5000, 6000, 8000])), float(r.choice([5000, 8000, 12000]))
        col = {'I': [300, 300, 10, 15]}
        args = {'name': 'portal', 'nodes': {'A': [0, 0, 0], 'B': [0, 0, H], 'C': [B, 0, H], 'D': [B, 0, 0]},
                'members': [{'id': 'C1', 'n1': 'A', 'n2': 'B', 'section': col}, {'id': 'B1', 'n1': 'B', 'n2': 'C', 'section': sec},
                            {'id': 'C2', 'n1': 'D', 'n2': 'C', 'section': col}],
                'supports': {'A': 'fixed', 'D': 'fixed'},
                'loads': {'G': [{'self_weight': 1}, {'member': 'B1', 'w': [0, 0, -5]}], 'Q': [{'member': 'B1', 'w': [0, 0, -8]}],
                          'W': [{'node': 'B', 'F': [wl, 0, 0]}]}}
        q = (f'Portal frame {B / 1000:g} m wide, {H / 1000:g} m high, columns I 300x300x10x15 fixed at the base, beam {st}; '
             f'dead 5 N/mm + self weight, live 8 N/mm on the beam, wind {wl / 1000:g} kN at the top. Check it.')
    out = tools.call('frame_solve', args)
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('frame_solve', args)},
            result_msg('frame_solve', out), {'role': 'assistant', 'content': out['plain_english']}]


def t_code(r, tools):
    """find and run a function of a copied repo in its own language (code_functions / code_call)"""
    from shipbrain import polyglot
    if r.random() < 0.5:
        repo, q, query = r.choice([('awatif', 'Which functions does Awatif have for the frame solver?', 'solver|Stiffness|Transformation'),
                                   ('awatif', 'What load functions are in awatif?', 'load'),
                                   ('diff3d', 'What can diff3d do? List its functions', None),
                                   ('awatif', 'Show me the C++ functions of the Awatif solver', 'lSolver')])
        args = {'repo': repo, **({'query': query} if query else {})}
        out = tools.call('code_functions', args)
        if 'error' in out:
            return None
        names = ', '.join(sorted({f['function'] for f in out['functions']})[:12])
        ans = out['plain_english'] + f' They are: {names}. I can run the Python / TypeScript ones directly with code_call.'
        return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('code_functions', args)},
                result_msg('code_functions', out), {'role': 'assistant', 'content': ans}]
    if not polyglot.node_ok():
        return None
    x2, y2, z2 = float(r.choice([3, 4, 6, 0])), float(r.choice([4, 0, 2])), float(r.choice([0, 0, 5]))
    if x2 == y2 == 0:
        x2 = 1.0
    q = r.choice([f"Use Awatif's own transformation matrix function for a member from (0,0,0) to ({x2:g},{y2:g},{z2:g})",
                  f"Run awatif getTransformationMatrix for nodes [0,0,0] and [{x2:g},{y2:g},{z2:g}]: what are the local axes?"])
    args = {'repo': 'awatif', 'file': 'components/analysis/l-solver/helpers/getTransformationMatrix.ts', 'function': 'getTransformationMatrix',
            'args': [[[0, 0, 0], [x2, y2, z2]]]}
    out = tools.call('code_call', args)
    if 'error' in out:
        return None
    m = out['result']
    ans = (out['plain_english'] + ' Local axes (rows of the 3 x 3 block): x = ' + str([round(v, 4) for v in m[0][:3]]) + ', y = '
           + str([round(v, 4) for v in m[1][:3]]) + ', z = ' + str([round(v, 4) for v in m[2][:3]]) + '.')
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('code_call', args)},
            result_msg('code_call', out), {'role': 'assistant', 'content': ans}]


_PID_Q = [('stats', [], 'How big is the P&ID graph of {p}? Give me the counts'),
          ('loops', [], 'List the control loops of {p}'),
          ('downstream', ['TK-100'], 'What is downstream of TK-100 in {p}?'),
          ('upstream', ['FV-101'], 'What is upstream of FV-101 in {p}?'),
          ('loop', ['F-101'], 'Explain control loop F-101 in {p}'),
          ('instruments', [], 'Which instruments are in {p} and what do they measure?'),
          ('describe', ['FIC-101'], 'What does FIC-101 do in {p}?'),
          ('path', ['TK-100', 'TK-200'], 'How does the flow go from TK-100 to TK-200 in {p}?')]


def t_pid(r, tools):
    """questions about a plant answered from its P&ID knowledge graph (pid-to-kg's own scripts; example plant from its tests)"""
    import shutil
    from shipbrain import polyglot
    if 'PID-to-Knowledge-Graph' not in polyglot.repos():
        return None
    work = 'work/mini_plant'
    wd = os.path.join(tools.workdir, work)
    if not os.path.exists(os.path.join(wd, 'kg', 'graph.json')):
        src = os.path.join(polyglot.repo_dir('PID-to-Knowledge-Graph'), 'tests', 'fixtures', 'mini_plant', 'extract')
        shutil.copytree(src, os.path.join(wd, 'extract'), dirs_exist_ok=True)
        if 'error' in tools.call('pid_kg', {'action': 'build', 'work': work, 'plant_name': 'Mini plant'}):
            return None
    cmd, args, q = r.choice(_PID_Q)
    a = {'action': 'query', 'work': work, 'command': cmd, **({'args': args} if args else {})}
    out = tools.call('pid_kg', a)
    if 'error' in out or 'not found' in out['output']:
        return None
    ans = 'From the P&ID knowledge graph:\n' + out['output'][:1500]
    return [{'role': 'user', 'content': q.format(p='the mini plant')}, {'role': 'assistant', 'content': tool_block('pid_kg', a)},
            result_msg('pid_kg', out), {'role': 'assistant', 'content': ans}]


_SUR = {}                                     # built surrogates: name -> (args, result), built once per dataset run
_SUR_SETS = [('deck_plate', {'L': [1500, 3000], 'B': [600, 900], 't': [8, 16], 'p': [0.02, 0.08]}),
             ('tank_wall', {'L': [800, 2000], 'B': [500, 800], 't': [10, 20], 'p': [0.05, 0.15]}),
             ('hatch_cover', {'L': [1000, 2500], 'B': [400, 700], 't': [6, 12], 'p': [0.01, 0.04]})]


def _sur_ready(r, tools):
    from shipbrain.solver import ccx_path
    if not ccx_path():
        return None
    name, rng = r.choice(_SUR_SETS)
    if name not in _SUR:
        args = {'name': name, 'ranges': rng, 'n': 10, 'max_runs': 14}
        _SUR[name] = (args, tools.call('surrogate_build', args))
    return name


def t_sur_build(r, tools):
    name = _sur_ready(r, tools)
    if not name or 'error' in _SUR[name][1]:
        return None
    args, out = _SUR[name]
    rg = args['ranges']
    q = r.choice(['Build a surrogate model for a clamped {n}: length {L0}-{L1} mm, breadth {B0}-{B1} mm, thickness {t0}-{t1} mm, '
                  'pressure {p0}-{p1} MPa', 'Make an AI reduced-order model of the {n} (L {L0}..{L1}, B {B0}..{B1}, t {t0}..{t1}, '
                  'p {p0}..{p1} MPa) so I get stresses instantly', 'Train a fast stress predictor for the {n} over L={L0}-{L1}, '
                  'B={B0}-{B1}, t={t0}-{t1}, p={p0}-{p1}']).format(
        n=name.replace('_', ' '), L0=rg['L'][0], L1=rg['L'][1], B0=rg['B'][0], B1=rg['B'][1], t0=rg['t'][0], t1=rg['t'][1],
        p0=rg['p'][0], p1=rg['p'][1])
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('surrogate_build', args)},
            result_msg('surrogate_build', out), {'role': 'assistant', 'content': out['plain_english']}]


def t_sur_predict(r, tools):
    name = _sur_ready(r, tools)
    if not name or 'error' in _SUR[name][1]:
        return None
    rg = _SUR[name][0]['ranges']
    P = {k: round(r.uniform(lo, hi), 3 if k == 'p' else 0) for k, (lo, hi) in rg.items()}
    if r.random() < 0.15:
        P['L'] = round(rg['L'][1] * 1.3)                       # outside the trained range: real solve
    q = r.choice(['Using the {n} surrogate, what is the stress for L={L:g}, B={B:g}, t={t:g} mm and p={p:g} MPa?',
                  '{n} model: predict max stress and deflection, L {L:g} mm, B {B:g} mm, t {t:g} mm, {p:g} MPa',
                  'Quick check with the surrogate {n}: {L:g} x {B:g} plate, {t:g} mm thick, pressure {p:g} MPa']).format(n=name, **P)
    args = {'name': name, 'params': P}
    out = tools.call('surrogate_predict', args)
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('surrogate_predict', args)},
            result_msg('surrogate_predict', out), {'role': 'assistant', 'content': out['plain_english']}]


def t_insight(r, tools):
    import glob
    name = _sur_ready(r, tools)
    if not name:
        return None
    frds = sorted(glob.glob(os.path.join(tools.workdir, name + '_runs', '*.frd')))
    if len(frds) < 2:
        return None
    f = os.path.relpath(r.choice(frds), tools.workdir)
    args = {'file': f}
    q = r.choice(['Check the result {f}: is it OK?', 'Where are the hotspots in {f}?', 'Write a short result summary for {f}',
                  'Post-process {f} and tell me if the mesh is fine enough'])
    if r.random() < 0.3:
        args['yield_MPa'] = float(r.choice([235, 315, 355]))
        q += f" (yield {args['yield_MPa']:g} MPa)"
    if r.random() < 0.25:
        args['baseline'] = os.path.relpath(frds[0], tools.workdir)
        q += f" and compare with {args['baseline']}"
    out = tools.call('result_insight', args)
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': q.format(f=f)}, {'role': 'assistant', 'content': tool_block('result_insight', args)},
            result_msg('result_insight', out), {'role': 'assistant', 'content': out['plain_english']}]


CHAT = [
    ('How can AI help the CAE chain without replacing the solver?',
     'Add it as a layer at each stage. Modelling: recognise features (holes, fillets, pipes) and clean geometry automatically '
     '(repair_model, pipe_extract, surface_extract). Meshing: flag elements that need refinement from the stress jump inside each '
     'element (result_insight). Analysis: a surrogate trained on real solver runs predicts stress and displacement in about 1 ms '
     '(surrogate_build / surrogate_predict); it gives an error estimate and runs the real solver when it is not sure. '
     'Post-processing: hotspots, comparison with a baseline, POD compression of result fields. Reporting: a draft text from the '
     'numbers, reviewed by an engineer. The solver stays the reference.'),
    ('Which library should I use for AI surrogates of FE results?',
     'For parametric studies with tens to hundreds of runs, POD + RBF (numpy/SciPy) is enough, runs on a CPU and needs no GPU; '
     'ShipBrain uses it and checks it by leave-one-out. For many different geometries and meshes, graph networks (MeshGraphNets in '
     'PyTorch / PyTorch Geometric, or NVIDIA PhysicsNeMo) or neural operators (FNO, DeepONet) are the next step, but they need a '
     'large dataset and a GPU to train. JAX (e.g. JAX-FEM) is for differentiable simulation: shape optimisation, material '
     'calibration. ONNX Runtime runs a trained network from C++; for POD + RBF ShipBrain writes a plain C++ header instead.'),
    ('What is the practical roadmap to use AI in our FE work?',
     '1. Save every run in one format (parameters, mesh, loads, results): this dataset is the most valuable asset. '
     '2. Pick one repetitive analysis (e.g. a plate or panel under pressure) and build a surrogate as a pilot. '
     '3. Validate it against the real solver (leave-one-out and new checks), keep an error estimate and fall back to the solver '
     'when it is not confident. 4. Call it from the CAD/FE program (C++ header or Python API), then extend to the other stages.'),
    ('Why are stiffeners modelled with shell webs instead of beams?',
     'Shell webs share nodes with the plate, so the stiffener and its attached plating bend together without needing beam offsets, '
     'stresses are available in the web and flange, and tripping/web buckling can be seen. Beams (CBAR with offsets) are lighter and fine '
     'for global models; in CalculiX beam offsets are ignored, so use shells there.'),
    ('How many elements between stiffeners do I need?',
     'At least 3, better 4-6 across a stiffener spacing if you want plate bending stress between stiffeners. For global stiffness 1 element per '
     'spacing (stiffeners as beams) is common. Keep aspect ratio below 3 in high-stress areas and below 5 elsewhere.'),
    ('What does the pressure value mean in the mesh?',
     'Lateral pressure in MPa on all plate elements, pushing towards -Z (towards the stiffeners). 1 m of sea water = 0.01005 MPa.'),
    ('What is the difference between 1D, 2D and 3D elements?',
     '1D elements (beams, CBAR) are lines: good for stiffeners and girders in a global model. 2D elements (shells, CQUAD4) are '
     'flat plates with a thickness: the normal choice for ship plating. 3D elements (solids, CHEXA) fill a volume: used for '
     'local details such as weld toes in fatigue models. Global ship models use 1D + 2D; local fatigue models use fine 2D (t x t) or 3D.'),
    ('What is a hot-spot stress?',
     'It is the stress at the weld toe, found by reading the surface stress at 0.5t and 1.5t away from the weld (t = plate thickness) '
     'and extrapolating to the toe: s_hs = 1.5 s(0.5t) - 0.5 s(1.5t). The mesh near the weld must be t x t. It is used with an S-N curve to get fatigue life.'),
    ('Can you do CFD?',
     'Not as a solver here. I can set up the geometry and mesh of a part for an external CFD tool, estimate loads with hand formulas, '
     'and explain the set-up (domain size, boundary layers, y+). CFD case generation is planned as a tool.'),
]


def t_chat(r, tools):
    q, a = r.choice(CHAT)
    return [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': a}]


def make_rules_task(entries):
    def t_rules(r, tools):
        e = r.choice(entries)
        first = e['text'].split('. ')[0].split('; ')[0]
        words = first.replace('(', ' ').replace(')', ' ').split()
        if len(words) < 4:
            return None
        if r.random() < 0.3:
            user = r.choice([f"What does rule {e['id']} say?", f"Explain {e['id']}", f"rule {e['id']}?"])
        else:
            n = r.randint(5, min(12, len(words)))
            topic = ' '.join(words[:n]).rstrip(',:;')
            user = r.choice(['What is the rule when ', 'Which rule covers: ', 'Rule for: ', 'What do we do here - ', 'How to handle: ']) \
                + topic[0].lower() + topic[1:] + '?'
        res = tools.call('knowledge_search', {'query': user, 'k': 4})
        ids = [h['id'] for h in res['results']]
        if e['id'] not in ids:
            return None                                       # only train cases where retrieval actually finds the rule
        ans = f"**{e['id']}**: {e['text'][:500]}" + ('' if len(ids) == 1 else f"\n\nRelated: {', '.join(i for i in ids if i != e['id'])}.")
        return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('knowledge_search', {'query': user, 'k': 4})},
                result_msg('knowledge_search', res), {'role': 'assistant', 'content': ans}]
    return t_rules


def _ocx_ok():
    try:
        from shipbrain import ocx
        return bool(ocx.versions()) and ocx.module() is not None
    except Exception:
        return False


_OCX_ASK = ['What is the OCX syntax of {n}?', 'How do I write ocx:{n} in OCX {v}?', 'Which attributes and children does {n} have in OCX {v}?',
            'Explain the OCX element {n}', 'Show me an XML example of {n} (OCX {v})', 'Is {n} required to have children in OCX {v}?',
            'What values can {n} take in OCX {v}?']
_OCX_FIND = ['bulb profile', 'plate thickness', 'watertight', 'frame table', 'end cut', 'cut-out hole', 'seam', 'material yield',
             'centre of gravity', 'bracket', 'pillar', 'edge reinforcement', 'nurbs surface', 'compartment', 'unit of measure',
             'design view', 'coordinate system', 'principal particulars', 'stiffener section', 'flange']


def t_ocx_syntax(r, tools):
    """the OCX library: exact syntax of an element / enumeration of a schema version (all 12 versions)"""
    if not _ocx_ok():
        return None
    from shipbrain import ocx
    v = ocx.LATEST if r.random() < 0.6 else r.choice(ocx.versions())
    cat = ocx.catalogue(v)
    names = [n for n, e in cat.items() if e['kind'] != 'type']
    n = r.choice(names)
    ask = r.choice(_OCX_ASK if cat[n]['kind'] == 'enumeration' else _OCX_ASK[:6])
    args = {'name': n, **({'version': v} if '{v}' in ask or v != ocx.LATEST else {})}
    out = tools.call('ocx_syntax', args)
    if 'error' in out:
        return None
    ans = out['plain_english']
    if out.get('example') and len(out['example']) < 1400:
        ans += '\n\n```xml\n' + out['example'] + '\n```'
    return [{'role': 'user', 'content': ask.format(n=n, v=v)}, {'role': 'assistant', 'content': tool_block('ocx_syntax', args)},
            result_msg('ocx_syntax', out), {'role': 'assistant', 'content': ans}]


def t_ocx_find(r, tools):
    """search the OCX library by meaning, or what changed between versions"""
    if not _ocx_ok():
        return None
    from shipbrain import ocx
    if r.random() < 0.3:
        vs = ocx.versions()
        i = r.randrange(0, len(vs) - 1)
        a, b = vs[i], r.choice(vs[i + 1:])
        args = {'changes_from': a, 'version': b}
        out = tools.call('ocx_syntax', args)
        ask = r.choice([f'What changed in OCX from {a} to {b}?', f'We export OCX {a}; the class wants {b}. What is different?'])
    else:
        q = r.choice(_OCX_FIND)
        args = {'name': q}
        out = tools.call('ocx_syntax', args)
        ask = r.choice([f'Which OCX element is used for {q}?', f'In OCX, where do I put the {q}?', f'OCX classes about {q}?'])
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tool_block('ocx_syntax', args)},
            result_msg('ocx_syntax', out), {'role': 'assistant', 'content': out['plain_english']}]


def _ocx_model(r):
    L, B = r.choice([3200, 4000, 4800, 6400, 8000]), r.choice([2400, 3200, 4000])
    n = r.choice([2, 3, 4])
    ts = [r.choice([8, 10, 11, 12, 14, 16, 18, 20]) for _ in range(n)]
    grade = r.choice(['A', 'AH32', 'AH36', 'DH36'])
    sec = r.choice([('HP200x10', {'type': 'LBar', 'H': 200, 'W': 40, 'tw': 10, 'tf': 10}), ('FB150x12', {'type': 'FlatBar', 'H': 150, 't': 12}),
                    ('L250x90x10', {'type': 'LBar', 'H': 250, 'W': 90, 'tw': 10, 'tf': 12}), ('T400x10', {'type': 'TBar', 'H': 400, 't': 10, 'wf': 150, 'tf': 15})])
    sp = r.choice([600, 700, 800])
    z = r.choice([8000, 10000, 12500, 15000])
    plates = [{'name': f'P{k + 1}', 'thk': ts[k], 'grade': grade, 'contour': [[0, k * B / n], [L, k * B / n], [L, (k + 1) * B / n], [0, (k + 1) * B / n]]}
              for k in range(n)]
    stiff = [{'name': f'L{i + 1}', 'sec': sec[0], 'grade': grade, 'trace': [[0, y], [L, y]], 'incl': [0, 0, -1]}
             for i, y in enumerate(range(sp, B, sp))]
    kind = r.choice(['DECK', 'BULKHEAD'])
    cs = {'origin': [0, 0, z], 'uaxis': [1, 0, 0], 'waxis': [0, 0, 1]} if kind == 'DECK' else {'origin': [r.choice([20000, 30000]), 0, 0], 'uaxis': [0, 1, 0], 'waxis': [1, 0, 0]}
    return {'sections': {sec[0]: dict(sec[1], name=sec[0])}, 'blocks': [{'id': 'B1', 'panels': [{'id': kind + '1', 'name': kind.title() + ' 1', 'function': kind,
                                                                                             'cs': cs, 'plates': plates, 'stiffeners': stiff}]}]}


def t_ocx_rw(r, tools):
    """structure -> OCX 3.2.0 (official classes, XSD-checked), and reading an OCX model back"""
    if not _ocx_ok():
        return None
    nm = r.choice(['panel', 'deck_block', 'bhd', 'midship_part', 'unit']) + str(r.randint(1, 99))
    json.dump(_ocx_model(r), open(os.path.join(tools.workdir, nm + '.json'), 'w'))
    w = tools.call('ocx_write', {'file': nm + '.json'})
    if 'error' in w or not w.get('valid'):
        return None
    if r.random() < 0.5:
        ask = r.choice([f'Convert {nm}.json to OCX', f'Export {nm}.json as a 3Docx file for class approval', f'Make an OCX file from {nm}.json'])
        return [{'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tool_block('ocx_write', {'file': nm + '.json'})},
                result_msg('ocx_write', w), {'role': 'assistant', 'content': w['plain_english']}]
    tool, ask = r.choice([('ocx_read', f'What is in {nm}.3docx?'), ('ocx_read', f'Summarise the OCX model {nm}.3docx: thicknesses and sections'),
                          ('ocx_validate', f'Is {nm}.3docx a valid OCX file?'), ('ocx_validate', f'Check {nm}.3docx against the OCX schema')])
    out = tools.call(tool, {'file': nm + '.3docx'})
    if 'error' in out:
        return None
    return [{'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tool_block(tool, {'file': nm + '.3docx'})},
            result_msg(tool, out), {'role': 'assistant', 'content': out['plain_english']}]


_INSTALL_CASES = [   # (user question, tool, args, the real error text that tool gives when the program is missing, key)
    ('Compare {a}.dwg with {b}.dwg and list the changes', 'compare_drawings', {'a': '{a}.dwg', 'b': '{b}.dwg'},
     'RuntimeError: DWG needs the free ODA File Converter (free download: https://www.opendesign.com/guestfiles/oda_file_converter ).', 'oda'),
    ('What changed between revision A and B? Files {a}.dwg and {b}.dwg', 'compare_drawings', {'a': '{a}.dwg', 'b': '{b}.dwg'},
     'RuntimeError: DWG needs the free ODA File Converter (free download: https://www.opendesign.com/guestfiles/oda_file_converter ).', 'oda'),
    ('Run a static analysis of {a}.inp', 'analysis_run', {'file': '{a}.inp', 'analysis': 'static'},
     'RuntimeError: CalculiX (ccx) not found on PATH; set CCX=path\\to\\ccx.exe', 'calculix'),
    ('Solve {a}.bdf with MYSTRAN', 'solve', {'file': '{a}.bdf', 'solver': 'mystran'},
     'RuntimeError: mystran was not found on this PC: give its path once with remember_solver', 'mystran'),
    ('Turn {a}.stl into a STEP solid', 'stl_to_step', {'file': '{a}.stl'},
     'RuntimeError: Rust is needed to build stl2step once: install it from https://rustup.rs', 'rust'),
    ('Check this portal frame: span 6 m, height 4 m, HEB200, 20 kN at mid-span', 'frame_solve', {'file': '{a}.json'},
     "ModuleNotFoundError: No module named 'wasmtime'", 'wasmtime'),
    ('Read the text in the scanned drawing {a}.png', 'compare_drawings', {'a': '{a}.png', 'b': '{b}.png'},
     "TesseractNotFoundError: tesseract is not installed or it's not in your PATH", 'tesseract'),
    ('Simulate sloshing in a tank with the physics lab', 'physics_lab', {'action': 'run', 'scenario': 'sloshing_tank'},
     'RuntimeError: a C compiler and make are needed: Linux `sudo apt install clang make`, macOS `xcode-select --install`', 'cc'),
]


def t_install(r, tools):
    """a tool fails because a free program is missing: tell the user what to install, why, the link and the steps
    (for Windows, Linux or macOS), and to ask again - never invent another link"""
    from shipbrain import installs
    user, name, args, err, key = r.choice(_INSTALL_CASES)
    a_, b_ = r.choice(['deck', 'frame', 'bulkhead', 'ga', 'skid', 'bracket', 'pump_base']) + f'_rev{r.choice("ABC")}', \
        r.choice(['deck', 'frame', 'bulkhead', 'ga', 'skid']) + f'_rev{r.choice("DEF")}'
    fill = lambda x: x.format(a=a_, b=b_) if isinstance(x, str) else x
    args = {k: fill(v) for k, v in args.items()}
    osn = r.choice(['windows', 'linux', 'mac'])
    i = installs.info(key)
    st = installs.SOFTWARE[key]['steps']
    i['steps'] = st.get(osn) or st.get('all') or i['steps']
    i['message'] = installs.message(i)
    res = {'error': err, 'install': i, 'plain_english': i['message']}
    ans = (f"I could not do this yet: **{i['name']}** is not installed on this PC. It is needed {i['why']}.\n\n"
           f"- Download: {i['link']}\n- How: {i['steps']}\n" + (f"- Then run once: {i['then']}\n" if i.get('then') else '')
           + (f"- Other way: {i['other']}\n" if i.get('other') else '') + '\nAfter installing, ask me again and I will run it.')
    sysnote = {'windows': 'I use Windows. ', 'linux': 'I am on Ubuntu. ', 'mac': 'I have a Mac. '}[osn] if r.random() < 0.6 else ''
    return [{'role': 'user', 'content': sysnote + fill(user)}, {'role': 'assistant', 'content': tool_block(name, args)},
            result_msg(name, res), {'role': 'assistant', 'content': ans}]


def t_setup(r, tools):
    """'what do I need to install?' -> setup_check -> the list with links"""
    only = r.random() < 0.5
    user = r.choice(['What do I need to install for ShipBrain?', 'Which programs are missing on this PC?', 'How do I set up a new PC for you?',
                     'Is everything installed?', 'What free software can you use and do I have it?'])
    res = tools.call('setup_check', {'only_missing': only})
    miss = [x for x in res['software'] if not x['installed']]
    ans = res['plain_english'] if not miss else ('These are not installed yet (install only what you need):\n\n' + '\n'.join(
        f"- **{x['name']}** - {x['why']}: {x['link']}" for x in miss) + '\n\nEverything else is ready.')
    return [{'role': 'user', 'content': user}, {'role': 'assistant', 'content': tool_block('setup_check', {'only_missing': only})},
            result_msg('setup_check', res), {'role': 'assistant', 'content': ans}]


TASKS = [('mesh', 30, lambda r, T: t_mesh(r, T)), ('mesh_fix', 6, lambda r, T: t_mesh(r, T, 'fix')),
         ('mesh_assume', 6, lambda r, T: t_mesh(r, T, 'assume')), ('plate', 12, t_plate), ('stiff', 12, t_stiff),
         ('buckle', 5, t_buckle), ('section', 8, t_section), ('calc', 4, t_calc), ('chat', 3, t_chat), ('plates', 4, t_plates), ('program', 12, t_program), ('cad_bank', 14, t_cad_bank),
         ('fileinfo', 4, t_fileinfo), ('convert', 4, t_convert), ('edit', 5, t_edit), ('clean', 3, t_clean), ('fe_repair', 3, t_fe_repair),
         ('sur_build', 1, t_sur_build), ('units', 5, t_units), ('profile', 2, t_profile), ('add_skill', 2, t_add_skill), ('frame', 5, t_frame), ('code', 2, t_code), ('pid', 3, t_pid), ('sur_predict', 4, t_sur_predict), ('insight', 3, t_insight),
         ('install', 4, t_install), ('setup', 1, t_setup),
         ('ocx_syntax', 6, t_ocx_syntax), ('ocx_find', 3, t_ocx_find), ('ocx_rw', 3, t_ocx_rw)]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=3000)
    ap.add_argument('--eval-n', type=int, default=150)
    ap.add_argument('--out', default='data/train.jsonl')
    ap.add_argument('--eval-out', default='data/eval.jsonl')
    ap.add_argument('--knowledge', action='append', default=[], help='rules_index.json / folder (adds rule retrieval tasks)')
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--no-cad', action='store_true', help='skip CadQuery tasks (slow: ~2 s per sample)')
    ap.add_argument('--feedback', action='append', default=[], help="feedback.jsonl from the app: liked (thumbs-up) conversations "
                                                                      "are added to the training data (x3), so the model learns your real requests")
    a = ap.parse_args(argv)
    import tempfile
    work = tempfile.mkdtemp(prefix='sb_data_')
    kb = knowledge.load(a.knowledge)
    try:
        import cadquery  # noqa: F401
        has_cq = True
    except ImportError:
        has_cq = False
    tools = agent.Tools(work, kb, allow_code=True, examples=Examples())
    tasks = list(TASKS)
    if has_cq and not a.no_cad:
        tasks.append(('cad', 6, t_cad))
        tasks.append(('repair', 5, t_repair))
        tasks.append(('surface', 4, t_surface))
        tasks.append(('pipes', 4, t_pipes))
    if len(kb):
        tasks.append(('rules', 25, make_rules_task([d for d in kb.docs if d.get('id')])))
    sysmsg = {'role': 'system', 'content': agent.system_prompt(tools)}
    for path, n, seed in ((a.out, a.n, a.seed), (a.eval_out, a.eval_n, a.seed + 10_000)):
        r = random.Random(seed)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        counts, tries = {}, 0
        with open(path, 'w', encoding='utf-8') as f:
            while sum(counts.values()) < n and tries < n * 5:
                tries += 1
                name, _, fn = r.choices(tasks, weights=[w for _, w, _ in tasks])[0]
                msgs = fn(r, tools)
                if not msgs:
                    continue
                ctx, _ = agent.retrieve(tools, msgs[0]['content'])          # same RAG context as at run time
                f.write(json.dumps({'task': name, 'messages': [sysmsg] + agent.attach_context(msgs, ctx, 0)}) + '\n')
                if tools.profile.data:                          # a task set a profile for its own sample only
                    tools.profile.data.clear()
                    tools.profile.update()
                counts[name] = counts.get(name, 0) + 1
        print(path, sum(counts.values()), 'samples', counts)
    real = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'real_models_train.jsonl.gz')
    if os.path.exists(real):                            # tool runs on real (cleaned) models: real sizes, real results
        import gzip
        n_real = 0
        with open(a.out, 'a', encoding='utf-8') as f, gzip.open(real, 'rt', encoding='utf-8') as g:
            for line in g:
                r = json.loads(line)
                msgs = [m for m in r['messages'] if m['role'] != 'system']
                f.write(json.dumps({'task': r.get('task', 'real_model'), 'messages': [sysmsg] + msgs}) + '\n')
                n_real += 1
        print(f'added {n_real} samples from real models ({os.path.basename(real)})')
    fb = 0
    with open(a.out, 'a', encoding='utf-8') as f:
        for path in a.feedback:
            for line in open(path, encoding='utf-8'):
                r = json.loads(line)
                if r.get('good') and r.get('messages') and r['messages'][-1]['role'] == 'assistant':
                    for _ in range(3):
                        f.write(json.dumps({'task': 'feedback', 'messages': [sysmsg] + r['messages']}) + '\n')
                    fb += 1
    if a.feedback:
        print(f'added {fb} liked conversation(s) from the app (x3)')
    import shutil
    shutil.rmtree(work, ignore_errors=True)                 # tool outputs incl. study run folders


if __name__ == '__main__':
    main()
