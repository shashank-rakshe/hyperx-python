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


def result_msg(name, res):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + json.dumps(res, default=str)[:6000]}


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
    ans = (f"Max bending stress **{res['sigma_max_MPa']:g} MPa**, max deflection **{res['w_max_mm']:g} mm** "
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
           f"Stress at toe **{res['sigma_toe_MPa']:g} MPa**, at plate {res['sigma_plate_MPa']:g} MPa, deflection {res['deflection_mm']:g} mm "
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
            {'role': 'assistant', 'content': f"Profile alone: A = {res['A']:g} mm2. With plating: I = {w['I'] / 1e4:.1f} cm4, "
                                             f"Z at toe **{w['Z_toe'] / 1e3:.1f} cm3**, Z at plate {w['Z_plate'] / 1e3:.1f} cm3, neutral axis "
                                             f"{w['z_na']:.1f} mm below plate mid-plane."}]


def t_calc(r, tools):
    h = r.choice([2, 3, 4.5, 6, 7.5, 10, 12.3])
    expr = f'1.025*9.81*{h}/1000'
    res = tools.call('calc', {'expression': expr})
    return [{'role': 'user', 'content': f'Pressure in MPa of {h} m sea water head?'},
            {'role': 'assistant', 'content': tool_block('calc', {'expression': expr})}, result_msg('calc', res),
            {'role': 'assistant', 'content': f"p = rho g h = 1.025 t/m3 x 9.81 x {h} m = **{res['value']:.4f} MPa** ({res['value'] * 1000:.1f} kPa)."}]


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


CHAT = [
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


TASKS = [('mesh', 30, lambda r, T: t_mesh(r, T)), ('mesh_fix', 6, lambda r, T: t_mesh(r, T, 'fix')),
         ('mesh_assume', 6, lambda r, T: t_mesh(r, T, 'assume')), ('plate', 12, t_plate), ('stiff', 12, t_stiff),
         ('buckle', 5, t_buckle), ('section', 8, t_section), ('calc', 4, t_calc), ('chat', 3, t_chat), ('plates', 10, t_plates),
         ('fileinfo', 4, t_fileinfo), ('convert', 4, t_convert), ('edit', 5, t_edit), ('clean', 3, t_clean)]


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
                head = [sysmsg] + ([{'role': 'system', 'content': ctx}] if ctx else [])
                f.write(json.dumps({'task': name, 'messages': head + msgs}) + '\n')
                counts[name] = counts.get(name, 0) + 1
        print(path, sum(counts.values()), 'samples', counts)
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
    for fn in os.listdir(work):
        os.remove(os.path.join(work, fn))
    os.rmdir(work)


if __name__ == '__main__':
    main()
