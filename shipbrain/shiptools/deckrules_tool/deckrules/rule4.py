"""Rule 4 / Step 4a - MEMBER PLACEMENT in ship coordinates.  Offline, universal, consumes ONLY Step-2 / Step-3 tables.

  python -m deckrules.rule4 FOLDER [NAME]

A member designation that lies inside the footprint of a plan (a Step-2 plan: OFF C.L row x frame row, deck height A/B) gets
    frame  = (position along the frame row - frame0) / pt per frame
    |Y|    = (position across the OFF C.L row - centre line) x written k  (side of the sheet; P/S needs the bow direction or a (P)/(S) title)
    Z      = the plan's written deck height A/B
    X (mm) = frame -> mm through the same sources as Step 3 (frame table / GA anchor / user answer + FRAME SPACE); none -> blank, never guessed.
Members that lie in no plan footprint (sections, elevations, details) are listed as 'not in a plan' - they are placed by Rule 4b (views).
Output  <name>_step4_members.csv  and  <name>_step4_report.md  (what was placed, what is ambiguous, what is open).
"""
import csv, os, re, sys, glob, argparse, collections
from . import ask as A, labels, windows as W
import csv as _csv

VCOLS = ['view_title', 'view_type', 'view_id', 'view_side', 'view_frame', 'view_src', 'scale_mm_pt']
COLS = ['page', 'view', 'kind', 'role', 'shape', 'size', 'grade', 'prov', 'text', 'x', 'y', 'plan', 'deck', 'z_mm', 'frame', 'x_mm', 'x_src',
        'y_abs_mm', 'sheet_side', 'y_mm', 'y_src', 'z_src'] + VCOLS + ['status']


def _f(v, d=None):
    try:
        return float(v)
    except Exception:
        return d


def _fx(folder, name, T, ans):
    """frame -> X mm function for one drawing (or None)"""
    SP = A.spacing(folder, T)
    h = A.hull_of(name)
    sp = SP.get(name)
    if ans.get('frame:%s:space' % name, '').isdigit():
        sp = int(ans['frame:%s:space' % name])
    tab = A.frame_tables(folder)
    tab = tab.get(h) or tab.get('')
    if tab:
        return lambda fr: A.table_x(tab, fr)[0], 'user frame table'
    cfn, csrc, _n = A.chain_x(folder, T, name, ans, SP)
    if cfn:
        return cfn, csrc
    if A.chain_intervals(folder, T, name, ans):
        return None, ''
    AN = A.anchors(folder, T, SP)
    fa = (AN[name][0], AN[name][1]) if name in AN else None
    src = AN[name][2] if name in AN else ''
    v = ans.get('frame:%s:start' % name) or (ans.get('frame:hull:%s:start' % h) if h else None)
    if v and A.anchor_answer(v):
        fa, src = A.anchor_answer(v), 'user'
    if fa and sp:
        return (lambda fr: fa[1] + (fr - fa[0]) * sp), 'frame x %s mm (frame %d = X %d mm; %s)' % (sp, fa[0], fa[1], src)
    return None, ''


def run(folder, name):
    plans = [r for r in A._read(os.path.join(folder, name + '_frames.csv')) if r.get('kind') == 'plan' and r.get('offcl_axis')]
    mem = A._read(os.path.join(folder, name + '_step3_members.csv'))
    T = {n: A._read(os.path.join(folder, n + '_step3_views.csv')) for n in A.drawings(folder)}
    ans = A.load_answers(folder)
    V3 = T.get(name, [])
    ctx = {}
    fx, fsrc = _fx(folder, name, T, ans) if name in T else (None, '')
    out, st = [], collections.Counter()
    legend = set()          # >=4 designations in one straight line of the sheet (same y or same x within 2 pt) = a size table / legend, not members at their places
    for ax in ('x', 'y'):
        rows_ = collections.defaultdict(list)
        for i, m in enumerate(mem):
            rows_[(m['page'], round(_f(m['y' if ax == 'x' else 'x']) / 2))].append(i)
        for g in rows_.values():
            if len(g) >= 4:
                legend.update(g)
    for i, m in enumerate(mem):
        if i in legend:
            r = {k: m.get(k, '') for k in COLS}
            r['status'] = 'legend / size table row (not a member place)'
            st['legend'] += 1
            out.append(r)
            continue
        r = {k: m.get(k, '') for k in COLS}
        pg, x, y = int(m['page']), _f(m['x']), _f(m['y'])
        cand = []
        for p in plans:
            if int(p['page']) != pg:
                continue
            if _f(p['rect_x0']) <= x <= _f(p['rect_x1']) and _f(p['rect_y0']) <= y <= _f(p['rect_y1']):
                area = (_f(p['rect_x1']) - _f(p['rect_x0'])) * (_f(p['rect_y1']) - _f(p['rect_y0']))
                cand.append((0 if p['height_ab'] != '' else 1, area, p))
        if not cand:
            if pg not in ctx:
                ctx[pg] = _page_ctx(folder, name, pg, V3)
            pv = place_in_view(ctx[pg], m)
            if pv:
                r.update(pv)
                if r['x_mm'] == '' and r['frame'] not in ('', None) and fx and '..' not in str(r['frame']):
                    try:
                        xv = fx(float(r['frame']))
                        if xv is not None:
                            r['x_mm'], r['x_src'] = round(xv), fsrc
                    except ValueError:
                        pass
                r['status'] = 'placed in view'
                st['in view'] += 1
                st['view+X'] += r['x_mm'] != ''
                st['view+|Y|'] += (r.get('y_abs_mm', '') != '' or r.get('y_mm', '') != '')
                st['view+Z'] += r['z_mm'] != ''
            else:
                r['status'] = 'not in a plan or view'
                st['not in a plan'] += 1
            out.append(r)
            continue
        cand.sort(key=lambda c: (c[0], c[1]))
        p = cand[0][2]
        tied = [c for c in cand if c[0] == cand[0][0] and abs(c[1] - cand[0][1]) < 0.02 * cand[0][1]]
        pos_t = x if p['offcl_axis'] == 'x' else y
        r['plan'], r['deck'] = p['title'][:40] or '(untitled plan)', p['deck']
        r['z_mm'] = p['height_ab']
        r['y_abs_mm'] = round(abs(pos_t - _f(p['offcl_c'])) * _f(p['offcl_k']))
        r['sheet_side'] = 'left' if pos_t < _f(p['offcl_c']) else 'right'
        r['y_mm'], r['y_src'] = '', 'sign needs bow direction (|Y| and sheet side given)'
        if p['frame_axis'] != '' and _f(p['frame_ppf']):
            pos_l = x if p['frame_axis'] == 'x' else y
            fr = (pos_l - _f(p['frame_f0'])) / _f(p['frame_ppf'])
            if _f(p['frame_first']) - 1.5 <= fr <= _f(p['frame_last']) + 1.5:
                r['frame'] = round(fr, 2)
                if fx and fx(fr) is not None:
                    r['x_mm'], r['x_src'] = round(fx(fr)), fsrc
        st['placed'] += 1
        st['with frame'] += r['frame'] != ''
        st['with X mm'] += r['x_mm'] != ''
        st['with Z'] += r['z_mm'] != ''
        r['status'] = 'placed in plan' + (' (tie: %d plans)' % len(tied) if len(tied) > 1 else '')
        st['tie'] += len(tied) > 1
        out.append(r)
    A._write(os.path.join(folder, name + '_step4_members.csv'), out, COLS)
    with open(os.path.join(folder, name + '_step4_report.md'), 'w') as f:
        f.write('# Rule 4a - member placement: %s\n\nmembers/plates %d | placed in a plan %d | with frame %d | with X mm %d | with Z %d | tied footprints %d | in no plan (Rule 4b) %d | legend / size-table rows %d\nRule 4b (members in views): placed in a view %d | with X mm %d | with |Y| %d | with Z %d\n'
                % (name, len(mem), st['placed'], st['with frame'], st['with X mm'], st['with Z'], st['tie'], st['not in a plan'], st['legend'], st['in view'], st['view+X'], st['view+|Y|'], st['view+Z']))
        f.write('\nOpen: P/S sign of Y needs the bow direction; X mm needs a frame table / GA anchor / user answer (%s).\n' % (fsrc or 'none available'))
    return out, st


def main(argv=None):
    ap = argparse.ArgumentParser(description='Rule 4a / Step 4a')
    ap.add_argument('folder')
    ap.add_argument('name', nargs='?')
    a = ap.parse_args(argv)
    names = [a.name] if a.name else A.drawings(a.folder)
    for n in names:
        o, st = run(a.folder, n)
        print(n, dict(st))



# ----------------------------------------------------------------------------- Rule 4b: members that lie in a section / elevation / detail view
HRX = re.compile(r'(\d{3,6})\s*A\s*/\s*B', re.I)


def _page_ctx(folder, name, pg, views):
    """everything 4b needs of one page: text items, reading direction, view windows tied to their Step-3 view rows"""
    items = []
    fp = os.path.join(folder, '%s_p%d_text.csv' % (name, pg))
    for r in A._read(fp) if os.path.exists(fp) else []:
        t = (r.get('text') or '').strip()
        if t:
            items.append(dict(t=t, x=(float(r['x0']) + float(r['x1'])) / 2, y=(float(r['y0']) + float(r['y1'])) / 2))
    u = W._text_axis(folder, name, pg)
    wins = W.load(folder, name, pg)
    vw = []
    for v in views:
        if int(v['page']) != pg:
            continue
        b = wins.get((v['title'][:70], int(v['tx']), int(v['ty'])))
        if b:
            vw.append((b[:4], v))
    return dict(items=items, u=u, vw=vw, views={v['view']: v for v in views if int(v['page']) == pg})


def place_in_view(ctx, m, mmpp_sheet=None):
    """-> dict of columns for a member inside a view, or None.  View = smallest window containing the member (else the Step-3 view of its nearest title)."""
    x, y = _f(m['x']), _f(m['y'])
    hit = [(b, v) for b, v in ctx['vw'] if b[0] <= x <= b[2] and b[1] <= y <= b[3]]
    if hit:
        b, v = min(hit, key=lambda h: (h[0][2] - h[0][0]) * (h[0][3] - h[0][1]))
        how = 'window of the title'
    else:
        v = ctx['views'].get(str(m.get('view')))
        b, how = None, 'nearest title (no window)'
    if not v:
        return None
    mmpp = _f(v.get('mm_per_pt')) or mmpp_sheet
    r = dict(view_title=v['title'][:40], view_type=v['type'], view_id=v['id'], view_side=v['side'], view_frame=v.get('frame', ''),
             view_src=how + ('; ' + v['x_src'] if v.get('x_src') else ''), scale_mm_pt=mmpp or '')
    r['x_mm'], r['x_src'] = v.get('x_mm', ''), (v.get('x_src', '') if v.get('x_mm', '') != '' else '')
    r['frame'] = v.get('frame', '')
    r['z_mm'], r['z_src'] = v.get('z_mm', ''), v.get('z_src', '') if v.get('z_mm', '') != '' else ''
    if v.get('y_mm', '') != '':                              # written in the view's own title (e.g. '2640 OFF C.L ELEV.(P)'): Y of every member of that elevation
        r['y_mm'], r['y_src'] = v['y_mm'], 'view title: ' + v.get('y_src', '')
    if b and mmpp:
        ux, uy = ctx['u']
        inb = [i for i in ctx['items'] if b[0] <= i['x'] <= b[2] and b[1] <= i['y'] <= b[3]]
        along = lambda p: p[0] * ux + p[1] * uy            # across the view (reading direction)
        up = lambda p: p[0] * uy - p[1] * ux               # upwards on the sheet
        oc = labels.offcl_axis(inb, (-1e9, -1e9, 1e9, 1e9), None, mmpp)
        if oc and abs(oc['k'] / mmpp - 1) <= 0.15 and ((oc['axis'] == 'x') == (abs(ux) >= abs(uy))):
            pos = x if oc['axis'] == 'x' else y
            r['y_abs_mm'], r['sheet_side'] = round(abs(pos - oc['c']) * oc['k']), 'left' if (pos - oc['c']) * (ux + uy) < 0 else 'right'
            r['y_src'] = 'OFF C.L labels in the view window (k %.1f mm/pt)' % oc['k']
        hs = []
        for i in inb:
            h = HRX.search(i['t'])
            if h:
                hs.append((up((i['x'], i['y'])), int(h.group(1))))
        hs = sorted(set(hs))
        if len(hs) >= 2:
            (p1, z1), (p2, z2) = hs[0], hs[-1]
            if p2 != p1 and abs(abs((z2 - z1) / (p2 - p1)) / mmpp - 1) <= 0.15:
                r['z_mm'], r['z_src'] = round(z1 + (up((x, y)) - p1) * mmpp), 'fit of %d height labels in the view window (scale agrees)' % len(hs)
        elif len(hs) == 1 and r['z_mm'] == '':
            p1, z1 = hs[0]
            r['z_mm'], r['z_src'] = round(z1 + (up((x, y)) - p1) * mmpp), 'ASSUMED: the only height label of the view is on its level line'
    return r


if __name__ == '__main__':
    main()
