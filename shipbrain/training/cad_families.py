"""
Verified text-to-CAD training bank: parametric part families (ship structure details and common mechanical parts).

Every item = a user request in plain words + the CadQuery script + the sizes the user asked for (expect). Each script is
BUILT with shipbrain.cadrun and kept only if the built solid matches the requested sizes (PASS) - no unchecked code.
Repair items add a typical mistake (wrong size or wrong API call), its real tool result, and the corrected script, so the
model learns to fix its own code from the tool's feedback.

  python training/cad_families.py --n 1200 --repairs 300 --out training/data/cad_bank.jsonl.gz --jobs 4

The bank stores results, not conversations: make_dataset.py turns it into chat samples with the CURRENT system prompt,
so the bank stays valid when tools change. Building needs CadQuery; reading the bank does not.
"""
import argparse, gzip, json, math, os, random, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

P = lambda v: f'{v:g}'


def _ask(r, what):
    return r.choice(['Model ', 'Make a 3D model of ', 'Create a CAD part: ', 'Build ', 'CAD banao: ', 'I need ', 'Make STEP of ']) + what


# ------------------------------------------------------------------ families: (name, generator) -> (prompt, code, bbox)
def plate_holes_row(r):
    L, B, t = r.choice([300, 400, 600, 800, 1000]), r.choice([100, 150, 200, 250]), r.choice([8, 10, 12, 15, 20])
    n, d = r.choice([2, 3, 4, 5]), r.choice([14, 18, 22, 26, 30])
    pitch = round((L - 2 * 60) / (n - 1) / 5) * 5
    if pitch < d + 10:
        return None
    what = f'a plate {P(L)} x {P(B)} x {P(t)} mm with {n} holes of {P(d)} mm in a row along the length, {P(pitch)} mm apart, centred'
    code = (f'L, B, t, n, d, pitch = {P(L)}, {P(B)}, {P(t)}, {n}, {P(d)}, {P(pitch)}\n'
            'result = (cq.Workplane("XY").box(L, B, t)\n'
            '          .faces(">Z").workplane().rarray(pitch, 1, n, 1).hole(d))')
    return _ask(r, what), code, [L, B, t], L * B * t - n * math.pi * d * d / 4 * t


def plate_hole_grid(r):
    L, B, t = r.choice([400, 500, 600, 800]), r.choice([300, 400, 500]), r.choice([10, 12, 15])
    nx, ny, d = r.choice([2, 3, 4]), r.choice([2, 3]), r.choice([16, 20, 24])
    px, py = round((L - 120) / (nx - 1) / 5) * 5, round((B - 120) / (ny - 1) / 5) * 5
    what = f'a base plate {P(L)} x {P(B)} x {P(t)} with a {nx} x {ny} grid of {P(d)} mm bolt holes, pitch {P(px)} x {P(py)} mm, centred'
    code = (f'L, B, t, d = {P(L)}, {P(B)}, {P(t)}, {P(d)}\n'
            f'result = cq.Workplane("XY").box(L, B, t).faces(">Z").workplane().rarray({P(px)}, {P(py)}, {nx}, {ny}).hole(d)')
    return _ask(r, what), code, [L, B, t], L * B * t - nx * ny * math.pi * d * d / 4 * t


def floor_lightening(r):
    L, H, t = r.choice([2000, 2400, 3000, 3600]), r.choice([800, 1000, 1200, 1500]), r.choice([10, 11, 12, 13])
    n = r.choice([2, 3, 4])
    w, h = r.choice([500, 600, 700]), r.choice([300, 350, 400])
    if n * (w + 200) > L or h > H - 300:
        return None
    what = (f'a floor plate {P(L)} long, {P(H)} high, {P(t)} thick with {n} lightening holes {P(w)} x {P(h)} with round ends, '
            f'evenly spaced along the length, at mid height')
    code = (f'L, H, t, n, w, h = {P(L)}, {P(H)}, {P(t)}, {n}, {P(w)}, {P(h)}\n'
            'result = (cq.Workplane("XZ").rect(L, H).extrude(t)\n'
            '          .faces(">Y").workplane(centerOption="CenterOfBoundBox")\n'
            '          .rarray(L / n, 1, n, 1).slot2D(w, h).cutThruAll())')
    hole = (w - h) * h + math.pi * h * h / 4
    return _ask(r, what), code, [L, t, H], (L * H - n * hole) * t


def profile_bar(r):
    kind = r.choice(['FB', 'L', 'T'])
    Lg = r.choice([1000, 1500, 2000, 2400, 3000])
    if kind == 'FB':
        h, tw = r.choice([100, 120, 150, 180, 200]), r.choice([8, 10, 12, 15])
        what = f'a flat bar stiffener FB {P(h)}x{P(tw)}, {P(Lg)} mm long, standing on the XY plane, length along X'
        code = f'L, h, t = {P(Lg)}, {P(h)}, {P(tw)}\nresult = cq.Workplane("YZ").rect(t, h, centered=(True, False)).extrude(L)'
        return _ask(r, what), code, [Lg, tw, h], Lg * h * tw
    if kind == 'L':
        h, b, tw, tf = r.choice([150, 200, 250, 300]), r.choice([75, 90, 100]), r.choice([9, 10, 11]), r.choice([10, 12, 14])
        what = f'an angle stiffener L {P(h)}x{P(b)}, web {P(tw)} mm, flange {P(tf)} mm, {P(Lg)} mm long along X, hanging below z = 0'
        code = (f'L, h, b, tw, tf = {P(Lg)}, {P(h)}, {P(b)}, {P(tw)}, {P(tf)}\n'
                'pts = [(0, 0), (tw, 0), (tw, -(h - tf)), (b, -(h - tf)), (b, -h), (0, -h)]\n'
                'result = cq.Workplane("YZ").polyline(pts).close().extrude(L)')
        return _ask(r, what), code, [Lg, b, h], Lg * (tw * (h - tf) + b * tf)
    hw, tw, bf, tf = r.choice([300, 400, 500, 600]), r.choice([9, 10, 12]), r.choice([100, 150, 200]), r.choice([12, 15, 18, 20])
    what = f'a T-bar web {P(hw)}x{P(tw)} with flange {P(bf)}x{P(tf)}, {P(Lg)} mm long along X, hanging below z = 0 (total height {P(hw)})'
    code = (f'L, hw, tw, bf, tf = {P(Lg)}, {P(hw)}, {P(tw)}, {P(bf)}, {P(tf)}\n'
            'web = cq.Workplane("XY").box(L, tw, hw - tf, centered=(False, True, False)).translate((0, 0, -(hw - tf)))\n'
            'flange = cq.Workplane("XY").box(L, bf, tf, centered=(False, True, False)).translate((0, 0, -hw))\n'
            'result = web.union(flange)')
    return _ask(r, what), code, [Lg, bf, hw], Lg * ((hw - tf) * tw + bf * tf)


def box_section(r):
    L, B, H, t = r.choice([2000, 3000, 6000]), r.choice([400, 600, 800]), r.choice([400, 500, 600, 800]), r.choice([10, 12, 14, 16])
    kind = r.choice(['box', 'channel'])
    if kind == 'box':
        what = f'a closed box girder {P(L)} long, {P(B)} wide, {P(H)} high with {P(t)} mm plates'
        code = f'L, B, H, t = {P(L)}, {P(B)}, {P(H)}, {P(t)}\nresult = cq.Workplane("YZ").rect(B, H).rect(B - 2 * t, H - 2 * t).extrude(L)'
        return _ask(r, what), code, [L, B, H], L * (B * H - (B - 2 * t) * (H - 2 * t))
    what = f'a U channel {P(L)} long, {P(B)} wide, {P(H)} high, {P(t)} mm thick, open at the top'
    code = (f'L, B, H, t = {P(L)}, {P(B)}, {P(H)}, {P(t)}\n'
            'pts = [(-B / 2, 0), (B / 2, 0), (B / 2, H), (B / 2 - t, H), (B / 2 - t, t), (-B / 2 + t, t), (-B / 2 + t, H), (-B / 2, H)]\n'
            'result = cq.Workplane("YZ").polyline(pts).close().extrude(L)')
    return _ask(r, what), code, [L, B, H], L * (B * H - (B - 2 * t) * (H - t))


def pipe(r):
    od, wt, L = r.choice([60.3, 88.9, 114.3, 168.3, 219.1, 273.0, 323.9]), r.choice([4, 5, 6, 8, 10]), r.choice([300, 500, 1000, 1500])
    what = f'a pipe OD {P(od)} mm, wall {P(wt)} mm, {P(L)} mm long, axis along Z'
    code = f'od, wt, L = {P(od)}, {P(wt)}, {P(L)}\nresult = cq.Workplane("XY").circle(od / 2).circle(od / 2 - wt).extrude(L)'
    return _ask(r, what), code, [od, od, L], math.pi / 4 * (od ** 2 - (od - 2 * wt) ** 2) * L


def flange(r):
    od, idd, t = r.choice([200, 250, 300, 400]), r.choice([90, 115, 140, 170]), r.choice([16, 20, 24, 30])
    n, pcd, d = r.choice([4, 6, 8, 12]), None, r.choice([14, 18, 22])
    pcd = round((od + idd) / 2 / 5) * 5
    if idd >= od - 60:
        return None
    what = f'a flange ring OD {P(od)}, bore {P(idd)}, {P(t)} thick, with {n} bolt holes of {P(d)} mm on a {P(pcd)} mm bolt circle'
    code = (f'od, idd, t, n, pcd, d = {P(od)}, {P(idd)}, {P(t)}, {n}, {P(pcd)}, {P(d)}\n'
            'result = (cq.Workplane("XY").circle(od / 2).circle(idd / 2).extrude(t)\n'
            '          .faces(">Z").workplane().polarArray(pcd / 2, 0, 360, n).hole(d))')
    return _ask(r, what), code, [od, od, t], math.pi / 4 * (od ** 2 - idd ** 2 - n * d * d) * t


def collar_plate(r):
    S, t, d = r.choice([600, 800, 1000]), r.choice([8, 10, 12]), r.choice([114.3, 168.3, 219.1, 273.0])
    w, tc = r.choice([50, 60, 80]), r.choice([10, 12, 15, 20])
    what = (f'a bulkhead plate {P(S)} x {P(S)} x {P(t)} with a {P(d)} mm pipe penetration in the centre and a collar ring '
            f'{P(w)} mm wide, {P(tc)} mm thick around the hole on top')
    code = (f'S, t, d, w, tc = {P(S)}, {P(t)}, {P(d)}, {P(w)}, {P(tc)}\n'
            'plate = cq.Workplane("XY").rect(S, S).extrude(t).faces(">Z").workplane().hole(d)\n'
            'collar = cq.Workplane("XY").workplane(offset=t).circle(d / 2 + w).circle(d / 2).extrude(tc)\n'
            'result = plate.union(collar)')
    vol = (S * S - math.pi * d * d / 4) * t + math.pi * ((d / 2 + w) ** 2 - (d / 2) ** 2) * tc
    return _ask(r, what), code, [S, S, t + tc], vol


def bracket(r):
    a, b, t, s = r.choice([300, 400, 500, 600, 800]), r.choice([300, 400, 500, 600, 800]), r.choice([10, 12, 14]), r.choice([0, 20, 30, 50])
    if s:
        what = f'a triangular bracket with legs {P(a)} and {P(b)} mm, {P(t)} mm thick, corner snipe {P(s)} mm, in the XZ plane'
        code = (f'a, b, t, s = {P(a)}, {P(b)}, {P(t)}, {P(s)}\n'
                'result = cq.Workplane("XZ").polyline([(s, 0), (a, 0), (0, b), (0, s)]).close().extrude(t)')
        area = a * b / 2 - s * s / 2
    else:
        what = f'a triangular knee bracket with legs {P(a)} and {P(b)} mm, {P(t)} mm thick, in the XZ plane'
        code = f'a, b, t = {P(a)}, {P(b)}, {P(t)}\nresult = cq.Workplane("XZ").polyline([(0, 0), (a, 0), (0, b)]).close().extrude(t)'
        area = a * b / 2
    return _ask(r, what), code, [a, t, b], area * t


def lifting_lug(r):
    w, h, t, d = r.choice([120, 150, 200]), r.choice([150, 200, 250]), r.choice([20, 25, 30, 40]), r.choice([40, 50, 60])
    if d > w - 50:
        return None
    what = (f'a lifting lug plate {P(w)} wide and {P(h)} high (rounded top of radius {P(w / 2)}), {P(t)} thick, '
            f'with a {P(d)} mm hole at the centre of the round top')
    code = (f'w, h, t, d = {P(w)}, {P(h)}, {P(t)}, {P(d)}\n'
            'r = w / 2\n'
            'body = cq.Workplane("XZ").rect(w, h - r, centered=(True, False)).extrude(t)\n'
            'top = cq.Workplane("XZ").workplane().center(0, h - r).circle(r).extrude(t)\n'
            'hole = cq.Workplane("XZ").workplane().center(0, h - r).circle(d / 2).extrude(t)\n'
            'result = body.union(top).cut(hole)')
    vol = (w * (h - w / 2) + math.pi * (w / 2) ** 2 / 2 - math.pi * d * d / 4) * t
    return _ask(r, what), code, [w, t, h], vol


def chamfer_plate(r):
    L, B, t, c = r.choice([300, 400, 500]), r.choice([200, 250, 300]), r.choice([10, 12, 15]), r.choice([20, 30, 40, 50])
    kind = r.choice(['chamfer', 'round'])
    if kind == 'chamfer':
        what = f'a plate {P(L)} x {P(B)} x {P(t)} with its four corners chamfered {P(c)} x {P(c)} mm'
        code = f'L, B, t, c = {P(L)}, {P(B)}, {P(t)}, {P(c)}\nresult = cq.Workplane("XY").box(L, B, t).edges("|Z").chamfer(c)'
        vol = (L * B - 2 * c * c) * t
    else:
        what = f'a plate {P(L)} x {P(B)} x {P(t)} with its four corners rounded to radius {P(c)} mm'
        code = f'L, B, t, c = {P(L)}, {P(B)}, {P(t)}, {P(c)}\nresult = cq.Workplane("XY").box(L, B, t).edges("|Z").fillet(c)'
        vol = (L * B - (4 - math.pi) * c * c) * t
    return _ask(r, what), code, [L, B, t], vol


def manhole(r):
    L, B, t = r.choice([1500, 2000, 2500]), r.choice([1200, 1500, 2000]), r.choice([10, 12, 14])
    a, b = r.choice([600, 800]), r.choice([400, 600])
    if b > a:
        a, b = b, a
    what = f'a tank top plate {P(L)} x {P(B)} x {P(t)} with an elliptical manhole {P(a)} x {P(b)} in the centre'
    code = (f'L, B, t, a, b = {P(L)}, {P(B)}, {P(t)}, {P(a)}, {P(b)}\n'
            'result = cq.Workplane("XY").rect(L, B).extrude(t).faces(">Z").workplane().ellipse(a / 2, b / 2).cutThruAll()')
    return _ask(r, what), code, [L, B, t], (L * B - math.pi * a * b / 4) * t


def web_slots(r):
    L, H, t = r.choice([2400, 3200, 4000]), r.choice([600, 800, 1000]), r.choice([9, 10, 12])
    s, w, d = r.choice([600, 700, 800]), r.choice([30, 40, 50]), r.choice([120, 150, 170, 200])
    n = int(L // s)
    what = (f'a web frame plate {P(L)} long, {P(H)} high, {P(t)} thick with {n} slots {P(w)} wide and {P(d)} deep in the top edge, '
            f'one in the middle of every {P(s)} mm bay, for passing stiffeners')
    code = (f'L, H, t, s, w, d, n = {P(L)}, {P(H)}, {P(t)}, {P(s)}, {P(w)}, {P(d)}, {n}\n'
            'result = cq.Workplane("XZ").rect(L, H, centered=(False, False)).extrude(-t)\n'
            'for k in range(n):\n'
            '    x = k * s + s / 2\n'
            '    result = result.cut(cq.Workplane("XY").box(w, 3 * t, d, centered=(True, True, False)).translate((x, 0, H - d)))')
    return _ask(r, what), code, [L, t, H], (L * H - n * w * d) * t


def pillar(r):
    od, wt, Lp = r.choice([114.3, 139.7, 168.3, 219.1]), r.choice([6, 8, 10]), r.choice([1500, 2000, 2500, 3000])
    S, tb = r.choice([250, 300, 350]), r.choice([15, 20, 25])
    what = f'a pillar: pipe OD {P(od)} x {P(wt)} wall, {P(Lp)} long, standing on a square base plate {P(S)} x {P(S)} x {P(tb)}'
    code = (f'od, wt, L, S, tb = {P(od)}, {P(wt)}, {P(Lp)}, {P(S)}, {P(tb)}\n'
            'base = cq.Workplane("XY").rect(S, S).extrude(tb)\n'
            'tube = cq.Workplane("XY").workplane(offset=tb).circle(od / 2).circle(od / 2 - wt).extrude(L)\n'
            'result = base.union(tube)')
    return _ask(r, what), code, [S, S, tb + Lp], S * S * tb + math.pi / 4 * (od ** 2 - (od - 2 * wt) ** 2) * Lp


def stiffened_panel(r):
    L, B, t = r.choice([2400, 3200, 4800]), r.choice([1600, 2400, 3200]), r.choice([8, 10, 12])
    s, h, tw = r.choice([600, 700, 800]), r.choice([100, 120, 150]), r.choice([8, 10, 12])
    n = int(round(B / s)) - 1
    if n < 1:
        return None
    what = f'a deck panel {P(L)} x {P(B)} x {P(t)} with {n} flat bars {P(h)}x{P(tw)} underneath every {P(s)} mm, running along the length'
    code = (f'L, B, t, s, h, tw, n = {P(L)}, {P(B)}, {P(t)}, {P(s)}, {P(h)}, {P(tw)}, {n}\n'
            'result = cq.Workplane("XY").box(L, B, t, centered=(False, False, False))\n'
            'for k in range(1, n + 1):\n'
            '    result = result.union(cq.Workplane("XY").box(L, tw, h, centered=(False, True, False)).translate((0, k * s, -h)))')
    return _ask(r, what), code, [L, B, t + h], L * B * t + n * L * h * tw


def stepped_block(r):
    L, B, H1, L2, H2 = r.choice([200, 300, 400]), r.choice([100, 150, 200]), r.choice([30, 40, 50]), None, r.choice([20, 30, 40])
    L2 = r.choice([0.4, 0.5, 0.6]) * L
    what = f'a stepped block {P(L)} x {P(B)}, {P(H1)} high, with a raised pad {P(L2)} long and {P(H2)} higher at one end, full width'
    code = (f'L, B, H1, L2, H2 = {P(L)}, {P(B)}, {P(H1)}, {P(L2)}, {P(H2)}\n'
            'base = cq.Workplane("XY").box(L, B, H1, centered=(False, False, False))\n'
            'pad = cq.Workplane("XY").box(L2, B, H2, centered=(False, False, False)).translate((0, 0, H1))\n'
            'result = base.union(pad)')
    return _ask(r, what), code, [L, B, H1 + H2], L * B * H1 + L2 * B * H2


FAMILIES = [plate_holes_row, plate_hole_grid, floor_lightening, profile_bar, box_section, pipe, flange, collar_plate, bracket,
            lifting_lug, chamfer_plate, manhole, web_slots, pillar, stiffened_panel, stepped_block]


# ------------------------------------------------------------------ mistakes for repair samples
def make_mistake(r, code, bbox):
    """-> (bad code, what went wrong) : a wrong size, a misspelt CadQuery call, or a forgotten result"""
    kind = r.choice(['size', 'size', 'api', 'result'])
    if kind == 'api':
        for a, b in (('.hole(', '.holes('), ('.extrude(', '.extrudes('), ('.rect(', '.rectangle('), ('.circle(', '.circel('),
                     ('.polyline(', '.polyLine('), ('.union(', '.add_union(')):
            if a in code:
                return code.replace(a, b, 1), 'api'
        kind = 'size'
    if kind == 'result':
        if 'result = (' not in code and code.count('result =') == 1:
            return code.replace('result =', 'part =', 1), 'result'
        kind = 'size'
    first = code.split('\n', 1)
    names, vals = first[0].split(' = ')
    v = [x.strip() for x in vals.split(',')]
    i = r.randrange(len(v))
    try:
        x = float(v[i])
    except ValueError:
        return None, None
    v[i] = P(x * r.choice([0.5, 0.8, 1.25, 2]))
    return names + ' = ' + ', '.join(v) + ('\n' + first[1] if len(first) > 1 else ''), 'size'


# ------------------------------------------------------------------ build + verify (parallel)
def _work(args):
    from shipbrain import cadrun
    idx, seed, n_rep = args
    r = random.Random(seed)
    fam = FAMILIES[idx % len(FAMILIES)]
    item = None
    for _ in range(5):
        item = fam(r)
        if item:
            break
    if not item:
        return None
    prompt, code, bbox, vol = item
    expect = {'bbox': [round(float(x), 3) for x in bbox], 'volume': round(float(vol), 1), 'tol': 0.01}
    name = fam.__name__ + f'_{idx}'
    with tempfile.TemporaryDirectory() as d:
        res = cadrun.run('import cadquery as cq\n' + code, d, name, expect)
        if not (res.get('ok') and res.get('pass')):
            return {'family': fam.__name__, 'rejected': res.get('checks') or res.get('message')}
        rec = {'family': fam.__name__, 'prompt': prompt, 'name': name, 'code': 'import cadquery as cq\n' + code, 'expect': expect,
               'result': res}
        if n_rep:
            bad, kind = make_mistake(r, code, bbox)
            if bad:
                bres = cadrun.run('import cadquery as cq\n' + bad, d, name, expect)
                if not bres.get('pass'):
                    rec['repair'] = {'kind': kind, 'bad_code': 'import cadquery as cq\n' + bad, 'bad_result': bres}
    return rec


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=1200)
    ap.add_argument('--repairs', type=int, default=300, help='how many items also get a mistake + fix')
    ap.add_argument('--out', default='training/data/cad_bank.jsonl.gz')
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--seed', type=int, default=7)
    a = ap.parse_args(argv)
    from multiprocessing import Pool
    jobs = [(i, a.seed * 100003 + i, i < a.repairs * 1.3) for i in range(int(a.n * 1.15))]
    kept, rejected, seen = [], {}, set()
    with Pool(a.jobs) as pool:
        for rec in pool.imap_unordered(_work, jobs, chunksize=4):
            if not rec:
                continue
            if 'rejected' in rec:
                rejected[rec['family']] = rejected.get(rec['family'], 0) + 1
                continue
            key = rec['code']
            if key in seen:
                continue
            seen.add(key)
            kept.append(rec)
            if len(kept) >= a.n:
                break
    kept.sort(key=lambda x: x['name'])
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as f:
        for rec in kept:
            f.write(json.dumps(rec) + '\n')
    fams = {}
    for rec in kept:
        fams[rec['family']] = fams.get(rec['family'], 0) + 1
    print(f"{len(kept)} verified items ({sum('repair' in x for x in kept)} with a repair) -> {a.out}; per family: {fams}; "
          f"rejected (did not match the requested sizes): {rejected}")


if __name__ == '__main__':
    main()
