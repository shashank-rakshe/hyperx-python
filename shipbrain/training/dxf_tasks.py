"""
DXF drawing training samples from real runs (dxf_draw / dxf_check): plain-words requests -> the parts the tool needs (hole
positions worked out from "40 mm from the edges", spacings, units converted) -> drawing -> a plain description of what was
drawn. Also: asking when a key size is missing, recovering from "hole outside the plate", and checking a sloppy DXF.

    python training/dxf_tasks.py --n 120 --out training/data/dxf_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=120)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'dxf_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_dxf_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}
    sheet_words = {'A4': ['A4', 'A4 sheet'], 'A3': ['A3', 'A3 paper'], 'A2': ['A2']}

    def run(name, args):
        return T.call(name, args)

    def tail(res, what):
        return f"{what} {res['plain_english']} Preview: {res['png']}."

    def plate_corner_holes():
        L, W, t = r.choice([200, 300, 400, 500]), r.choice([100, 150, 200, 250]), r.choice([8, 10, 12, 16, 20])
        e, d = r.choice([20, 25, 30, 40]), r.choice([10, 12, 14, 18, 22])
        sh = r.choice(['A4', 'A3'])
        q = r.choice([f'Draw a plate {L} x {W} x {t} with four holes of {d} mm, {e} mm from the edges, on {sh}',
                      f'{L} by {W} mm plate, {t} thick, 4 corner holes dia {d} ({e} from each edge) - drawing on {sh} please',
                      f'Make a DXF: base plate {L}x{W}, t={t}, holes {d} mm at the corners, edge distance {e}. {sh}.'])
        holes = [{'x': x, 'y': y, 'd': d} for x in (e, L - e) for y in (e, W - e)]
        args = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'thickness': t, 'holes': holes}], 'title': f'BASE PLATE PL{t}', 'sheet': sh, 'name': 'base_plate'}
        res = run('dxf_draw', args)
        return [U(q), A(tb(args)), rm(res), A(tail(res, f'A {L} x {W} mm plate, {t} mm thick, with four {d} mm holes {e} mm from the edges (hole positions measured from the lower-left corner).'))]

    def plate_grid():
        nx, ny = r.choice([2, 3, 4]), r.choice([2, 3])
        dx, dy = r.choice([60, 80, 100]), r.choice([50, 60, 80])
        x0, y0 = r.choice([30, 40]), r.choice([30, 40])
        L, W = x0 * 2 + dx * (nx - 1), y0 * 2 + dy * (ny - 1)
        d = r.choice([12, 14, 18])
        q = r.choice([f'Drawing of a mounting plate with a grid of {nx} x {ny} holes dia {d}, pitch {dx} x {dy}, {x0} mm margin all round',
                      f'{nx} by {ny} holes, {d} mm, spaced {dx} and {dy} mm; plate with {x0} mm borders. Draw it.'])
        args = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'hole_grid': {'x0': x0, 'y0': y0, 'nx': nx, 'ny': ny, 'dx': dx, 'dy': dy, 'd': d}}], 'title': 'MOUNTING PLATE', 'sheet': 'A4', 'name': 'mounting_plate'}
        res = run('dxf_draw', args)
        return [U(q), A(f'The plate size follows from the margins: {x0 * 2} + {dx * (nx - 1)} = {L} long and {y0 * 2} + {dy * (ny - 1)} = {W} wide.\n' + tb(args)), rm(res),
                A(tail(res, f'A {L} x {W} mm plate with {nx * ny} holes of {d} mm in a {nx} x {ny} grid (pitch {dx} x {dy}), first hole {x0} mm from each edge.'))]

    def plate_rounded_slot():
        L, W = r.choice([200, 250, 300]), r.choice([100, 120, 150])
        rad, sl, sw = r.choice([8, 10, 15]), r.choice([50, 60, 80]), r.choice([12, 14, 16])
        q = f'Plate {L} x {W} with {rad} mm corner radius and a centred slot {sl} x {sw}'
        args = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'corner_radius': rad, 'slots': [{'x': L / 2, 'y': W / 2, 'length': sl, 'width': sw}]}], 'name': 'slotted_plate'}
        res = run('dxf_draw', args)
        return [U(q), A(tb(args)), rm(res), A(tail(res, f'A {L} x {W} mm plate with {rad} mm rounded corners and a {sl} x {sw} mm slot in the middle.'))]

    def panel():
        L, W, t = r.choice([2400, 3200, 4800, 6000]), r.choice([1600, 2400, 3200]), r.choice([8, 10, 12, 14])
        s = r.choice([600, 700, 800, 900])
        fs = r.choice([1200, 1600, 2000, 2400])
        prof = r.choice(['FB 150x12', 'FB 200x10', 'HP 160x8', 'HP 200x9', 'T 250x10+100x12'])
        sh = r.choice(['A3', 'A3', 'A2'])
        q = r.choice([f'Deck panel {L / 1000:g} m x {W / 1000:g} m, {t} mm plating, {prof} stiffeners every {s} mm and frames every {fs} mm - draw it on {sh}',
                      f'Stiffened panel plan: {L} x {W}, PL {t}, stiffener spacing {s} ({prof}), frame spacing {fs}. {sh} drawing.'])
        args = {'parts': [{'type': 'panel', 'length': L, 'width': W, 'thickness': t, 'stiffeners': {'spacing': s, 'profile': prof, 'direction': 'x'}, 'frames': {'spacing': fs}}],
                'title': f'STIFFENED PANEL PL{t}', 'sheet': sh, 'name': 'panel'}
        res = run('dxf_draw', args)
        n = len([1 for v in range(1, 10 ** 3) if v * s < W - 1e-6])
        m = len([1 for v in range(1, 10 ** 3) if v * fs < L - 1e-6])
        return [U(q), A(tb(args)), rm(res), A(tail(res, f'A {L} x {W} mm panel, plating {t} mm, {n} stiffeners {prof} along the length at {s} mm spacing and {m} frames at {fs} mm (FR1 ...).'))]

    def flange():
        od, idia = r.choice([180, 220, 250, 300]), r.choice([60, 80, 100])
        n, bd = r.choice([4, 6, 8, 12]), r.choice([14, 18, 22])
        bc = round(od * r.choice([0.75, 0.78, 0.8]))
        q = r.choice([f'Draw a flange OD {od}, bore {idia}, {n} bolts dia {bd} on a {bc} bolt circle',
                      f'Flange drawing: outside diameter {od} mm, ID {idia}, PCD {bc}, {n} x {bd} holes'])
        args = {'parts': [{'type': 'flange', 'od': od, 'id': idia, 'bolt_circle': bc, 'n_bolts': n, 'bolt_d': bd}], 'title': 'FLANGE', 'sheet': 'A4', 'name': 'flange'}
        res = run('dxf_draw', args)
        return [U(q), A(tb(args)), rm(res), A(tail(res, f'A flange of {od} mm outside diameter with a {idia} mm bore and {n} holes of {bd} mm on a {bc} mm bolt circle.'))]

    def inches():
        Li, Wi, ti = r.choice([8, 12, 16]), r.choice([4, 6, 8]), r.choice([0.25, 0.375, 0.5])
        di = r.choice([0.5, 0.625, 0.75])
        ei = r.choice([1, 1.5])
        q = f'Plate {Li} in x {Wi} in, {ti} in thick, 4 holes {di} in dia, {ei} in from the edges. Drawing please.'
        L, W, t, d, e = [round(v * 25.4, 1) for v in (Li, Wi, ti, di, ei)]
        holes = [{'x': x, 'y': y, 'd': d} for x in (e, round(L - e, 1)) for y in (e, round(W - e, 1))]
        args = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'thickness': t, 'holes': holes}], 'sheet': 'A3', 'name': 'plate_inch'}
        res = run('dxf_draw', args)
        return [U(q), A(f'Converting to mm: {Li} in = {L}, {Wi} in = {W}, {ti} in = {t}, {di} in = {d}, {ei} in = {e}.\n' + tb(args)), rm(res),
                A(tail(res, f'The plate is {L} x {W} mm (from {Li} x {Wi} in), {t} mm thick, with four {d} mm holes {e} mm from the edges.'))]

    def shapes():
        w, h, d = r.choice([100, 150, 200]), r.choice([50, 80, 100]), r.choice([20, 30])
        q = f'Draw a rectangle {w} x {h} with a circle of diameter {d} in the middle and the text "CENTRE HOLE"'
        args = {'parts': [{'type': 'shapes', 'rects': [{'x': 0, 'y': 0, 'w': w, 'h': h}], 'circles': [{'x': w / 2, 'y': h / 2, 'd': d}],
                           'texts': [{'x': w / 2, 'y': h + 10, 'text': 'CENTRE HOLE'}]}], 'dims': False, 'name': 'sketch'}
        res = run('dxf_draw', args)
        return [U(q), A(tb(args)), rm(res), A(tail(res, f'A {w} x {h} mm rectangle with a {d} mm circle at its centre and the label CENTRE HOLE above it.'))]

    def ask_then_draw():
        L, W, e, d = r.choice([200, 300, 400]), r.choice([100, 150, 200]), r.choice([20, 30, 40]), r.choice([10, 14, 18])
        q1 = r.choice(['Draw a plate with 4 holes', 'I need a drawing of a base plate', 'Plate drawing banao, chaar holes ke saath'])
        ask = 'Sure. I need: the plate length and width (mm), the hole diameter, and where the holes are (for example "40 mm from the edges"). Thickness and sheet size are optional - I use A3 if you do not say.'
        a2 = f'{L} x {W}, holes {d} mm, {e} mm from the edges'
        holes = [{'x': x, 'y': y, 'd': d} for x in (e, L - e) for y in (e, W - e)]
        args = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'holes': holes}], 'sheet': 'A3', 'name': 'plate'}
        res = run('dxf_draw', args)
        return [U(q1), A(ask), U(a2), A(tb(args)), rm(res), A(tail(res, f'A {L} x {W} mm plate with four {d} mm holes {e} mm from the edges (A3 sheet, as no size was given).'))]

    def recover_outside():
        L, W, d = r.choice([200, 300]), r.choice([100, 120]), r.choice([12, 16])
        bad = L + r.choice([20, 40])
        q = f'Plate {L} x {W}, hole dia {d} at x={bad}, y={W // 2}'
        a1 = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'holes': [{'x': bad, 'y': W // 2, 'd': d}]}], 'name': 'plate'}
        e1 = run('dxf_draw', a1)
        a2 = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'holes': [{'x': L - 30, 'y': W // 2, 'd': d}]}], 'name': 'plate'}
        res = run('dxf_draw', a2)
        return [U(q), A(tb(a1)), rm(e1),
                A(f'The hole at x = {bad} lies outside the {L} mm long plate. Probably it should be inside: I put it {30} mm from the right edge (x = {L - 30}); tell me if you meant something else.\n' + tb(a2)),
                rm(res), A(tail(res, f'A {L} x {W} mm plate with one {d} mm hole at x = {L - 30}, y = {W // 2}.'))]

    def check_good():
        L, W = r.choice([300, 400]), r.choice([150, 200])
        a1 = {'parts': [{'type': 'plate', 'length': L, 'width': W, 'holes': [{'x': 40, 'y': 40, 'd': 14}]}], 'name': 'chk'}
        res = run('dxf_draw', a1)
        a2 = {'file': 'chk.dxf'}
        c = run('dxf_check', a2)
        return [U(f'Draw a {L} x {W} plate with a 14 mm hole 40 mm from the corner and check the drawing quality'), A(tb(a1)), rm(res),
                A(tb(a2)), rm(c), A(tail(res, f'A {L} x {W} mm plate with one 14 mm hole 40 mm from the lower-left corner.') + ' Drafting check: ' + c['plain_english'].split(': ', 1)[-1])]

    def check_bad():
        import ezdxf
        n = r.randint(0, 999)
        doc = ezdxf.new('R2018')
        doc.header['$INSUNITS'] = r.choice([0, 4])
        m = doc.modelspace()
        L, W = r.choice([200, 300]), r.choice([100, 150])
        pts = [(0, 0), (L, 0), (L, W), (0, W)]
        for i in range(4):
            b = pts[(i + 1) % 4]
            if i == 3 and r.random() < 0.8:
                b = (b[0], b[1] + r.choice([0.4, 0.8]))
            m.add_line(pts[i], b)
        if r.random() < 0.7:
            m.add_line(pts[0], pts[1])
        if r.random() < 0.6:
            d = m.add_linear_dim(base=(0, -15), p1=(0, 0), p2=(L, 0), text=str(L + 20), dimstyle='EZDXF')
            d.render()
        f = f'old_part_{n}.dxf'
        doc.saveas(os.path.join(work, f))
        args = {'file': f}
        c = run('dxf_check', args)
        tips = []
        for i in c['issues']:
            w = i['what']
            if 'layer 0' in w: tips.append('put outline, dimensions and text on separate layers')
            if 'duplicate' in w: tips.append('delete the duplicate lines (they plot twice)')
            if 'nearly meet' in w: tips.append('close the small gaps (use "join" / snap the ends together)')
            if 'typed over' in w: tips.append('reset the dimension text to the measured value (a typed-over number can be wrong)')
            if 'units' in w: tips.append('set the drawing units to mm')
        return [U(r.choice([f'Is {f} a clean drawing?', f'Check the DXF {f} for drafting problems'])), A(tb(args)), rm(c),
                A(c['plain_english'] + (' To fix: ' + '; '.join(tips) + '.' if tips else ''))]

    def tb(args):
        from make_dataset import tool_block
        name = 'dxf_check' if set(args) == {'file'} else 'dxf_draw'
        return tool_block(name, args)

    def rm(res):
        from make_dataset import result_msg
        name = 'dxf_check' if 'issues' in res else 'dxf_draw'
        return result_msg(name, res if 'error' not in res else res)

    gens = [(plate_corner_holes, 6), (plate_grid, 4), (plate_rounded_slot, 3), (panel, 6), (flange, 3), (inches, 3), (shapes, 2),
            (ask_then_draw, 3), (recover_outside, 3), (check_good, 2), (check_bad, 4)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds = [], {}
    while len(rows) < a.n:
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:150])
            continue
        if any('"error"' in x['content'][:60] and x['content'].startswith('TOOL_RESULT') and g.__name__ != 'recover_outside' for x in m):
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'dxf_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    shutil.rmtree(work, ignore_errors=True)
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
