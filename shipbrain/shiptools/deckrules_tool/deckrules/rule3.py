"""Rule 3 / Step 3 (offline) - consumes ONLY Step-2 tables (facts, plans, marks, views); parses no text:
 a) classify each view   b) place each view in ship coordinates   c) find members
 d) fill gaps by correlation   e) output (views csv, members csv, report md)

Input  : `<name>_facts.csv`, `<name>_plans.csv`, `<name>_pN_marks.csv`, `<name>_pN_views.csv` (Step 2, built there if missing).
Output : `<name>_step3_views.csv`, `<name>_step3_members.csv`, `<name>_step3_report.md`
Ship axes: X = frame number (+ mm offset, forward +), Y = OFF C.L (Port +, Stbd -), Z = height A/B (mm above baseline).
Everything carries provenance: written | correlated | ambiguous | scaled | missing.
"""
import csv, os, re, sys, glob, statistics, collections, argparse


def read_csv(fp):
    with open(fp, newline='', encoding='utf-8') as f:
        return list(csv.DictReader(f))


def fl(v, d=None):
    try:
        return float(v)
    except Exception:
        return d


# ---------------------------------------------------------------- (a) classify (titles come from the Step-2 facts table)
def view_of(views, x, y):
    for i, v in enumerate(views):
        if v['x0'] - 5 <= x <= v['x1'] + 5 and v['y0'] - 5 <= y <= v['y1'] + 5:
            return i
    return None


# ---------------------------------------------------------------- (b) place
def frames_in(frames, box=None):
    """frames = Step-2 facts rows of kind 'frame' -> (n, off, x, y) inside box"""
    return [(int(f['frame_no']), int(f['frame_off'] or 0), f['x'], f['y'], f.get('frame_frac', '') or '') for f in frames
            if not box or (box[0] - 20 <= f['x'] <= box[2] + 20 and box[1] - 20 <= f['y'] <= box[3] + 20)]


def heights_in(heights, box):
    return [(int(h['height']), h['x'], h['y']) for h in heights if box[0] - 20 <= h['x'] <= box[2] + 20 and box[1] - 20 <= h['y'] <= box[3] + 20]


def plan_frame_axis(fr, mmpp):
    """plan view: FR labels sit along X -> mm of each frame relative to the first; spacing = median(dmm/dframe)."""
    if mmpp is None:
        return None
    pts = sorted({(n, round(a[2])) for a in fr for n, o in [(a[0], a[1])] if o == 0 and not a[4]})
    if len(pts) < 2:
        return None
    sp = [abs(b[1] - a[1]) * mmpp / abs(b[0] - a[0]) for a, b in zip(pts, pts[1:]) if b[0] != a[0]]
    return round(statistics.median(sp)) if sp else None


def place(frames, heights, views, title_items, vscale=None, wins=None):
    """each title -> row with ship coordinates + provenance."""
    rows = []
    for k, (it, info) in enumerate(title_items):
        vi = view_of(views, it['x'], it['y'])
        v = views[vi] if vi is not None else None
        box = (v['x0'], v['y0'], v['x1'], v['y1']) if v else None
        w = (wins or {}).get((it['t'][:70], round(it['x']), round(it['y'])))
        rbox = box
        if w:                                   # the title's OWN view window (Step 2 windows.py) replaces the shared line-work cloud
            box = w[:4]
        vs = (vscale or {}).get(it['t'][:70])
        mmpp = fl(vs['mm_per_pt']) if vs else None
        row = dict(view=k, title=it['t'], type=info['type'], id=info['id'], side=info['side'], deck=info['deck'],
                   tx=round(it['x']), ty=round(it['y']), region=vi if vi is not None else '', mm_per_pt=mmpp or '',
                   scale_source=vs['source'] if vs else '', scale_status=vs['status'] if vs else '')
        notes = []
        # Z : written A/B in the title, else nearest written A/B in the region
        z, zsrc = info['height'], 'written(title)'
        if z is None and box:
            hs = sorted(heights_in(heights, box) or (heights_in(heights, rbox) if rbox else []), key=lambda h: (h[1] - it['x']) ** 2 + (h[2] - it['y']) ** 2)
            hs = [h for h in hs if (h[1] - it['x']) ** 2 + (h[2] - it['y']) ** 2 < 300 ** 2]
            if hs:
                z, zsrc = hs[0][0], 'written(near)'
        row['z_mm'], row['z_src'] = (z if z is not None else ''), (zsrc if z is not None else 'missing')
        row['z_list'] = ''
        if z is None and box and info['type'] in ('section', 'elevation', 'longitudinal-elevation', 'detail'):
            # a section / elevation shows several decks: every height written inside its window is listed, none is picked for it
            zs = sorted({h[0] for h in (heights_in(heights, box) or (heights_in(heights, rbox) if rbox else []))})
            if len(zs) > 1:
                row['z_mm'], row['z_src'], row['z_list'] = '', 'written(list in view)', '|'.join(str(v) for v in zs)
        # Y : OFF C.L in title (+P/-S), plan views span the ship width
        y = info['offcl']
        if y is not None:
            sgn = -1 if info['side'] == 'S' else 1
            row['y_mm'], row['y_src'] = sgn * y, 'written(title)'
        elif info['type'] in ('deck-plan', 'plan'):
            row['y_mm'], row['y_src'] = '', 'plan spans width'
        elif info['side']:
            row['y_mm'], row['y_src'] = '', 'side %s only' % info['side']
        else:
            row['y_mm'], row['y_src'] = '', 'missing'
        row['longl_no'], row['shell'] = info.get('longl_no', ''), info.get('shell', '')
        if row['longl_no'] and info['type'] == 'longitudinal-elevation' and row['y_src'].split('(')[0] in ('missing', 'side %s only' % info['side']):
            if row['shell'] == 'side shell':      # owner rule v2.100b: the highest NO.n are members ON the side shell - not counted along the OFF C.L list
                row['y_mm'], row['y_src'] = '', 'side shell (NO.%s)' % row['longl_no']
            else:                                  # inner longitudinal NO.n = n-th OFF C.L from the centre line: value needed (written list or user)
                row['y_mm'], row['y_src'] = '', 'missing'
        # X : frame label near the title (sections/elevations) or frame axis (plans)
        fr = frames_in(frames, box) if box else []
        if not fr and rbox and rbox != box:     # the window holds no frame label: fall back to the line-work region of Step 2
            fr = frames_in(frames, rbox)
        if info['type'] == 'section' and info.get('frame'):
            row['frame'], row['frame_off_mm'], row['frame_frac'] = info['frame'][0], info['frame'][1], info['frame'][2]
            row['x_src'] = 'written(title)'
        elif info['type'] in ('section', 'elevation') and fr:
            f = min(fr, key=lambda a: (a[2] - it['x']) ** 2 + (a[3] - it['y']) ** 2)
            d2 = (f[2] - it['x']) ** 2 + (f[3] - it['y']) ** 2
            if d2 < 450 ** 2:
                row['frame'], row['frame_off_mm'], row['x_src'] = f[0], f[1], 'written(near)'
                row['frame_frac'] = f[4]
            else:
                row['frame'], row['frame_off_mm'], row['x_src'] = '', '', 'missing'
        elif info['type'] in ('deck-plan', 'plan', 'longitudinal-elevation') and fr:
            nums = sorted({a[0] for a in fr})
            if len(nums) < 2:                  # one frame label is not the frame range of a plan / longitudinal elevation (AFT: '-2..-2')
                row['frame'], row['frame_off_mm'], row['x_src'] = '', '', 'missing'
                notes.append('only one frame label (%d) in the window - not a range' % nums[0])
                row['frame_spacing_mm'] = ''
                row['notes'] = '; '.join(notes)
                rows.append(row)
                continue
            row['frame'], row['frame_off_mm'] = '%d..%d' % (nums[0], nums[-1]), ''
            row['x_src'] = 'written(range)'
            sp = plan_frame_axis(fr, mmpp)
            if sp:
                row['frame_spacing_mm'] = sp
                notes.append('frame spacing %d mm from plan labels x scale' % sp)
        else:
            row['frame'], row['frame_off_mm'], row['x_src'] = '', '', 'missing'
        row.setdefault('frame_spacing_mm', '')
        row['notes'] = '; '.join(notes)
        rows.append(row)
    return rows



# ---------------------------------------------------------------- (b2) cut marks: where a section/elevation belongs


def locate_by_marks(V, plans, marks):
    """Step 3 only JOINS what Steps 1-2 delivered: `plans` (<name>_plans.csv: heights, written OFF C.L axis, frame axis, written spacing) and
    `marks` (<name>_pN_marks.csv: where each section id stands on a plan and which plan hosts it).
    Z = plan height; |Y| = (mark position - centre line) x written k; X = (mark position - frame0) / pt per frame."""
    by_row = {(int(p['page']), int(p['row'])): p for p in plans}
    mk = collections.defaultdict(list)
    for m in marks:
        if m['host'] != '':
            mk[(int(m['page']), m['id'])].append(m)
    for v in V:
        if v['type'] not in ('section', 'elevation', 'view') or not v['id']:
            continue
        ms = mk.get((int(v['page']), v['id']))
        if not ms:
            v['mark'] = 'no mark in a plan'
            continue
        m = ms[0]
        p = by_row[(int(m['page']), int(m['host']))]
        v['mark'] = 'mark in plan "%s" at (%s,%s)' % ((p['title'] or '(untitled plan)')[:30], m['x'], m['y'])
        v['host_plan'] = p['title'] or '(untitled plan)'
        pos = float(m[p['offcl_axis']])
        y = (pos - p['offcl_c']) * p['offcl_k']
        v['mark_y_abs_mm'] = int(round(abs(y), -1))
        v['mark_sheet_side'] = 'left' if pos < p['offcl_c'] else 'right'
        if p['frame_axis'] != '':
            fr = round((float(m['x'] if p['frame_axis'] == 'x' else m['y']) - p['frame_f0']) / p['frame_ppf'], 1)
            if p['frame_first'] - 1.5 <= fr <= p['frame_last'] + 1.5:      # outside the plan's own frame range = not this plan's mark
                v['mark_frame'] = fr
            else:
                v['notes'] = (v.get('notes', '') + '; mark frame %.1f outside plan range %d-%d, ignored' % (fr, p['frame_first'], p['frame_last'])).strip('; ')
        z = int(p['height_ab']) if p['height_ab'] != '' and str(m.get('z_ok', '1')) == '1' else ''
        if v['z_mm'] == '' and z != '':
            v['z_mm'], v['z_src'] = z, 'correlated(cut-mark in plan %s)' % p['title'][:24]
        elif v['z_mm'] != '' and z != '' and v['z_mm'] != z and v['z_src'].startswith('written'):
            v['notes'] = (v.get('notes', '') + '; Z conflict: view %s vs plan %s' % (v['z_mm'], z)).strip('; ')
        if v['y_mm'] == '':
            v['y_mm'] = v['mark_y_abs_mm']
            v['y_src'] = 'correlated(cut-mark; |Y|, side %s of sheet, sign needs bow direction)' % v['mark_sheet_side']
        if v.get('mark_frame') is not None and v['frame'] == '' and p['title'] and p['title'] != '(untitled plan)':     # an untitled host plan is not trusted for a frame (AFT 8B4-1: 9.2 against the written 13)
            v['frame'], v['x_src'] = v['mark_frame'], 'correlated(cut-mark in plan; %s)' % (p['frame_src'] or 'frame row')
    return V


# ---------------------------------------------------------------- (c) members
def find_members(mfacts, views, view_titles):
    """(c) member designations and plate thicknesses = Step-2 facts rows; tied to the nearest title inside the same Step-2 region (N1)."""
    out = []
    for it in mfacts:
        vi = view_of(views, it['x'], it['y'])
        cand = [(k, ti) for k, (ti, info) in enumerate(view_titles) if vi is not None and view_of(views, ti['x'], ti['y']) == vi]
        if not cand:
            cand = list(enumerate(ti for ti, _ in view_titles))
        k = min(cand, key=lambda c: (c[1]['x'] - it['x']) ** 2 + (c[1]['y'] - it['y']) ** 2)[0] if cand else ''
        row = dict(shape=it['shape'], size=it['size'], h=int(it['h']) if it['h'] not in ('', None) else '', b=it['b'], t=it['t'], t2=it['t2'], fw=it['fw'], ft=it['ft'],
                   cond=it['cond'], role=it['role'], grade=it['grade'], level=it['level'], view=k, text=it['text'][:80], x=round(it['x']), y=round(it['y']),
                   candidates='', kind='plate' if it['kind'] == 'plate' else 'member')
        row['prov'] = 'written' if it['level'] == 'full' else 'gap'
        out.append(row)
    return out


# ---------------------------------------------------------------- (d) correlate
def fill_gaps(members):
    """height-only members ('300 I.A', '100 F.B'): find the full size elsewhere. Order (owner Rule 2e/3d):
       same view -> same page (unique) -> other pages in the drawing.  One candidate => correlated,
       several => ambiguous (all listed, nothing guessed), none => missing."""
    full = [m for m in members if m['level'] == 'full' and m['kind'] == 'member']
    for m in members:
        if m['level'] != 'height-only':
            continue
        same_shape = [f for f in full if f['shape'].startswith(m['shape'][0]) and f['h'] == m['h']]
        for scope, sel in (('same view', lambda f: f['view'] == m['view'] and f['page'] == m['page']),
                           ('same page', lambda f: f['page'] == m['page']),
                           ('same drawing', lambda f: True)):
            c = sorted({f['size'] for f in same_shape if sel(f)})
            if len(c) == 1:
                m['size'], m['prov'] = c[0], 'correlated(%s)' % scope
                ref = next(f for f in same_shape if f['size'] == c[0] and sel(f))
                for k in ('b', 't', 't2', 'fw', 'ft'):
                    m[k] = ref[k]
                m['level'] = 'filled'
                break
            if len(c) > 1:
                m['prov'], m['candidates'] = 'ambiguous(%s)' % scope, '|'.join(c)
                break
        else:
            m['prov'] = 'missing'
    return members


# ---------------------------------------------------------------- (e) output
VIEW_COLS = ['page', 'view', 'title', 'type', 'id', 'side', 'deck', 'tx', 'ty', 'region', 'frame', 'frame_off_mm', 'x_src',
             'frame_frac', 'longl_no', 'shell', 'x_mm', 'y_mm', 'y_src', 'z_mm', 'z_list', 'z_src', 'mm_per_pt', 'scale_source', 'scale_status', 'frame_spacing_mm', 'mark', 'host_plan', 'mark_y_abs_mm', 'mark_sheet_side', 'mark_frame', 'notes']
MEM_COLS = ['page', 'view', 'kind', 'role', 'shape', 'size', 'h', 'b', 't', 't2', 'fw', 'ft', 'cond', 'grade', 'prov', 'candidates', 'text', 'x', 'y']


def conflicts(views_rows):
    """same id on two titles with different Z/Y/frame -> flagged."""
    seen = collections.defaultdict(list)
    for r in views_rows:
        if r['id']:
            seen[(r['page'], r['id'], r['side'])].append(r)
    out = []
    for k, rs in seen.items():
        if len(rs) > 1:
            out.append('page %s: id %s (%s) appears on %d titles' % (k[0], k[1], k[2] or '-', len(rs)))
    return out


def _pages(folder, name):
    out = []
    for f in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')):
        m = re.search(r'_p(\d+)_text\.csv$', f)
        if m and os.path.basename(f)[:-len(m.group(0))] == name:
            out.append(int(m.group(1)))
    return sorted(out)


def frames_from_plans(V, plans):
    """a plan / deck-plan view without any written FR. label takes the frame range of its own footprint (frame row = consecutive or sparse labels, Step 2)."""
    for v in V:
        if v['type'] not in ('deck-plan', 'plan') or v['frame'] != '':
            continue
        c = [p for p in plans if int(p['page']) == int(v['page']) and p['frame_axis'] != '' and p['title'] and p['title'][:40] == v['title'][:40]]
        if len(c) == 1 and c[0]['frame_first'] != '' and c[0]['frame_last'] != '':
            v['frame'] = '%d..%d' % (int(c[0]['frame_first']), int(c[0]['frame_last']))
            v['x_src'] = 'written(plan frame row)'
    return V


def correlate_views(V):
    """(d) for views: a missing X / Y / Z is filled from (1) the same id elsewhere (other title or page), (2) the one distinct written value in the same Step-2 region. Provenance 'correlated(...)'; several values -> left missing."""
    byid = collections.defaultdict(list)
    for v in V:
        if v['id']:
            byid[(v['id'], v['side'])].append(v)
    reg = collections.defaultdict(list)
    for v in V:
        if v['region'] != '':
            reg[(v['page'], v['region'])].append(v)
    for v in V:
        for key, src, fld in (('frame', 'x_src', None), ('z_mm', 'z_src', None), ('y_mm', 'y_src', None)):
            if v[key] != '' or v[src] not in ('missing', 'side %s only' % v['side']):
                continue
            c = {str(o[key]) for o in byid.get((v['id'], v['side']), []) if o is not v and o[key] != '' and o[src].startswith('written')}
            how = 'same id'
            if len(c) != 1:
                c = {str(o[key]) for o in reg.get((v['page'], v['region']), []) if o is not v and o[key] != '' and o[src].startswith('written') and (key != 'y_mm' or o['type'] == v['type'])}
                how = 'same region'
            if len(c) == 1:
                val = c.pop()
                v[key] = int(val) if val.lstrip('-').isdigit() else val
                v[src] = 'correlated(%s)' % how
    return V


def run(folder, name, out=None):
    out = out or folder
    pages = _pages(folder, name)
    from . import facts as _facts
    FACTS = _facts.load(folder, name)            # Step 2: every written fact, parsed once
    from . import viewscale as _vs
    VSCALE = _vs.load(folder, name)              # Step 2: the scale of each view title
    V, M = [], []
    for pg in pages:
        fx = [r for r in FACTS if r['page'] == pg]
        titles = [(dict(t=r['text'], x=r['x'], y=r['y']), dict(type=r['type'], id=r['id'], side=r['side'], deck=r['deck'],
                  longl_no=r.get('longl_no', ''), shell=r.get('shell', ''),
                  height=int(r['height']) if r['height'] != '' else None, offcl=int(r['offcl']) if r['offcl'] != '' else None,
                  frame=(int(r['frame_no']), int(r['frame_off'] or 0), r.get('frame_frac', '') or '') if r.get('frame_no', '') != '' else None))
                  for r in fx if r['kind'] == 'title']
        vf = os.path.join(folder, '%s_p%d_views.csv' % (name, pg))
        views = [dict(r, x0=fl(r['x0']), y0=fl(r['y0']), x1=fl(r['x1']), y1=fl(r['y1'])) for r in read_csv(vf)] if os.path.exists(vf) else []
        vsc = {r['title']: r for r in VSCALE if int(r['page']) == pg}
        from . import windows as _win
        vr = place([r for r in fx if r['kind'] == 'frame'], [r for r in fx if r['kind'] == 'height'], views, titles, vsc, _win.load(folder, name, pg))
        for r in vr:
            r['page'] = pg
        mem = find_members([r for r in fx if r['kind'] in ('member', 'plate')], views, titles)
        for m in mem:
            m['page'] = pg
        V += vr
        M += mem
    M = fill_gaps(M)
    from . import plans as _plans
    pl, mk = _plans.load_frames(folder, name)    # Step 2 output: plan footprints from the written label rows + marks hosted by them
    V = locate_by_marks(V, pl, mk)
    V = frames_from_plans(V, pl)
    V = correlate_views(V)
    with open(os.path.join(out, name + '_step3_views.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, VIEW_COLS, extrasaction='ignore')
        w.writeheader()
        w.writerows(V)
    with open(os.path.join(out, name + '_step3_members.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, MEM_COLS, extrasaction='ignore')
        w.writeheader()
        w.writerows(M)
    rep = report(name, V, M)
    with open(os.path.join(out, name + '_step3_report.md'), 'w', encoding='utf-8') as f:
        f.write(rep)
    return V, M


def report(name, V, M):
    C = collections.Counter
    L = ['# Step 3 (Rule 3) - %s' % name, '']
    L.append('Views classified: %d  (%s)' % (len(V), ', '.join('%s %d' % kv for kv in sorted(C(v['type'] for v in V).items()))))
    pl = C()
    for v in V:
        pl['X ' + v['x_src']] += 1
        pl['Y ' + v['y_src']] += 1
        pl['Z ' + v['z_src']] += 1
    L.append('Placement provenance: ' + ', '.join('%s %d' % kv for kv in sorted(pl.items())))
    mm = [m for m in M if m['kind'] == 'member']
    L.append('Member designations: %d  (%s)' % (len(mm), ', '.join('%s %d' % kv for kv in sorted(C(m['prov'].split('(')[0] for m in mm).items()))))
    L.append('Plate thicknesses: %d' % sum(1 for m in M if m['kind'] == 'plate'))
    L.append('')
    L.append('## Views')
    L.append('| pg | type | id | side | deck | frame | Y mm | Z mm | scale |')
    L.append('|--|--|--|--|--|--|--|--|--|')
    for v in V[:80]:
        L.append('| %s | %s | %s | %s | %s | %s%s | %s | %s | %s %s |' % (v['page'], v['type'], v['id'], v['side'], v['deck'], v['frame'],
                 ('%+d' % v['frame_off_mm'] if isinstance(v['frame_off_mm'], int) and v['frame_off_mm'] else ''), v['y_mm'], v['z_mm'],
                 v['mm_per_pt'], v['scale_status']))
    if len(V) > 80:
        L.append('... %d more in the csv' % (len(V) - 80))
    L.append('')
    L.append('## Member sizes (unique, count, provenance)')
    cnt = collections.Counter((m['shape'], m['size'], m['prov'].split('(')[0]) for m in mm)
    for (sh, sz, pv), n in cnt.most_common(40):
        L.append('- %s %s x%d [%s]' % (sh, sz, n, pv))
    amb = [m for m in mm if m['prov'].startswith('ambiguous')]
    if amb:
        L.append('')
        L.append('## Ambiguous (not guessed)')
        for m in amb[:20]:
            L.append('- p%s "%s" -> candidates %s' % (m['page'], m['text'], m['candidates']))
    cf = conflicts(V)
    if cf:
        L.append('')
        L.append('## Conflicts / duplicates')
        L += ['- ' + c for c in cf[:20]]
    return '\n'.join(L) + '\n'


def main(argv=None):
    ap = argparse.ArgumentParser(description='Rule 3 / Step 3')
    ap.add_argument('folder')
    ap.add_argument('name', nargs='?')
    ap.add_argument('--out')
    ap.add_argument('--ask', choices=['auto', 'gui', 'console', 'headless', 'off'], default='off', help='after all drawings: look in the whole folder, then ask the user for what is not written')
    a = ap.parse_args(argv)
    names = [a.name] if a.name else sorted({re.sub(r'_p\d+_text\.csv$', '', os.path.basename(f)) for f in glob.glob(os.path.join(a.folder, '*_p*_text.csv')) if re.search(r'_p\d+_text\.csv$', f)})
    for n in names:
        V, M = run(a.folder, n, a.out)
        print(n, 'views', len(V), 'members', len(M))
    if a.ask != 'off':
        from . import ask as _ask
        _ask.run(a.out or a.folder, a.ask)


if __name__ == '__main__':
    main()
