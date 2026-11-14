"""Step 2 (Rule 2 c/d/e) - the plan table.  Everything Step 3 needs to know ABOUT a plan comes from here, Step 3 recomputes nothing.

<name>_pN_plans.csv  one row per plan / arrangement title:
   title, kind(plan|arrangement), deck, height_ab, x, y (title centre, pt),
   offcl_axis/c/k/n/vmax   (written OFF C.L labels  -> scale + centre line)
   frame_axis/ppf/f0/n/first/last/frame_src   (written frame row: its own, or aligned from the sibling plan of the same deck)
   frame_space (written FRAME SPACE), sheet_mm_per_pt (Step-2 view scale), verdict
<name>_pN_marks.csv  every cut mark ("1C5-4"): id, x, y, host (plan row index on that page or blank), host_title
"""
import csv, os, re, glob, statistics, collections
from collections import Counter
from . import labels

PLAN_RX = re.compile(r"\bPLAN\b|^\W*ARRG'?T\b", re.I)
NOT_RX = re.compile(r'\b(ALL|NOTE|LOOKING|HISTORY|SCALE)\b', re.I)
DECKPLAN_RX = re.compile(r'^\W*(.*?)\s*DECK\s+PLAN', re.I)
ARR_RX = re.compile(r"^\W*ARRG'?T\b.*?\bON\s+(.*?)\s*\.?\s*-?\s*DECK", re.I)
HEIGHT_RX = re.compile(r'(\d{3,6})\s*A\s*/\s*B', re.I)
MARK_RX = re.compile(r'^\W*"\s*([0-9A-Z]{1,3}[0-9A-Z]*-\d{1,3})\s*"\W*$')
RADIUS = 900.0            # a cut mark / frame row may be this far from its plan title
ROW_RADIUS = 2600.0      # with a frame row the frame-range gate protects against wrong plans, so a far plan body is allowed
LABEL_RADIUS = 1700.0     # its OFF C.L label row may lie further (wide plans)
PLAN_COLS = ['page', 'row', 'title', 'kind', 'deck', 'height_ab', 'x', 'y',
             'offcl_axis', 'offcl_c', 'offcl_k', 'offcl_n', 'offcl_vmax', 'offcl_mode', 'offcl_row', 'offcl_values',
             'frame_axis', 'frame_ppf', 'frame_f0', 'frame_n', 'frame_first', 'frame_last', 'frame_src',
             'frame_space', 'frame_k', 'sheet_mm_per_pt', 'verdict']


def _deck(title, kind):
    if kind == 'arrangement':
        m = ARR_RX.match(title)
        g = m.group(1) if m else ''
    else:
        m = DECKPLAN_RX.match(title)
        g = m.group(1) if m else ''
    g = re.sub(r'\s*-\s*', '-', g.strip().upper().rstrip('.')).strip('-').strip()
    return (g + ('-DECK' if len(g) <= 3 else ' DECK')) if g else ''


def _items(fp):
    out = []
    if os.path.exists(fp):
        for r in csv.DictReader(open(fp, encoding='utf-8')):
            t = (r['text'] or '').strip()
            if t:
                x0, y0, x1, y1 = (float(r[k]) for k in ('x0', 'y0', 'x1', 'y1'))
                out.append(dict(t=t, x=(x0 + x1) / 2, y=(y0 + y1) / 2))
    return out


def _segments(fp):
    out = []
    if os.path.exists(fp):
        for r in csv.DictReader(open(fp, encoding='utf-8')):
            if r.get('kind') == 'l' and r.get('x2'):
                try:
                    out.append((float(r['x1']), float(r['y1']), float(r['x2']), float(r['y2'])))
                except ValueError:
                    pass
    return out


def _body(segs, titles, k, minlen=40.0):
    """outline of the long line work whose nearest title is title k (and within RADIUS); 2..98 percentile so stray lines do not stretch it."""
    pts_x, pts_y = [], []
    t = titles[k]
    for a, b, c, d in segs:
        if ((a - c) ** 2 + (b - d) ** 2) ** 0.5 < minlen:
            continue
        mx, my = (a + c) / 2, (b + d) / 2
        dist = [((mx - q['x']) ** 2 + (my - q['y']) ** 2) for q in titles]
        j = min(range(len(titles)), key=lambda i: dist[i])
        if j == k and dist[j] < RADIUS ** 2:
            pts_x += [a, c]
            pts_y += [b, d]
    if len(pts_x) < 8:
        return None
    qx = statistics.quantiles(pts_x, n=50)
    qy = statistics.quantiles(pts_y, n=50)
    return qx[0], qy[0], qx[-1], qy[-1]


def _align_from_sibling(rows, items):
    """a plan with an OFF C.L axis but no frame row at its own scale takes the frame row of the sibling (same deck, 'ARRG'T ... ON <deck>'):
    both titles are centred over the same footprint -> same frame under both title centres; spacing = written FRAME SPACE / the plan's k."""
    for p in rows:
        if p['kind'] != 'plan' or not p['offcl_axis'] or p['frame_axis'] or not p['frame_space'] or not p['deck']:
            continue
        ax = 'y' if p['offcl_axis'] == 'x' else 'x'
        for sb in [r for r in rows if r['kind'] == 'arrangement' and r['deck'] == p['deck']]:
            row = labels.frame_axis(items, (-1e9, -1e9, 1e9, 1e9), p['offcl_axis'], (sb['x'], sb['y']), RADIUS)
            if not row or row['axis'] != ax:
                continue
            tc = sb['y'] if ax == 'y' else sb['x']
            span = abs(row['pt_per_frame']) * (row['last'] - row['first'])
            rc = row['f0'] + row['pt_per_frame'] * (row['first'] + row['last']) / 2.0
            if abs(rc - tc) > 0.2 * span:
                continue
            f_t = (tc - row['f0']) / row['pt_per_frame']
            ppf = (1 if row['pt_per_frame'] > 0 else -1) * p['frame_space'] / p['offcl_k']
            pc = p['y'] if ax == 'y' else p['x']
            p.update(frame_axis=ax, frame_ppf=ppf, frame_f0=pc - ppf * f_t, frame_n=row['n'], frame_first=row['first'], frame_last=row['last'],
                     frame_src='aligned to frame row of "%s" (title centres)' % sb['title'][:32])
            break



FRAME_COLS = ['page', 'row', 'title', 'title_dist', 'deck', 'height_ab', 'x', 'y', 'rect_x0', 'rect_y0', 'rect_x1', 'rect_y1',
              'offcl_axis', 'offcl_c', 'offcl_k', 'offcl_n', 'offcl_vmax', 'offcl_mode', 'offcl_row', 'offcl_values',
              'frame_axis', 'frame_ppf', 'frame_f0', 'frame_n', 'frame_first', 'frame_last', 'frame_src', 'frame_space', 'kind']


def _rect_dist(r, x, y):
    dx = max(r[0] - x, 0, x - r[2])
    dy = max(r[1] - y, 0, y - r[3])
    return (dx * dx + dy * dy) ** 0.5


def build_frames(items, title_rows, page_sheet, pg):
    """Plans of reference from WRITTEN LABEL ROWS (not from titles): an OFF C.L row (transverse axis: centre line, written scale, span) paired with
    a frame row (longitudinal axis) that lies at its edge and whose written spacing agrees with the OFF C.L scale gives the plan's footprint.
    The title is attached afterwards (nearest, preferring one that states height A/B) - a title only names the plan, it does not define it."""
    offs = labels.offcl_rows(items, page_sheet or None)
    fss = [int(m.group(1).replace(',', '')) for i in items for m in [labels.FRAMESP_RX.search(i['t'])] if m]
    frs = [f for f in labels.all_frame_rows(items, bool(fss)) if 8 < abs(f['pt_per_frame']) < 300]       # consecutive AND sparse frame labels
    out = []
    for R in offs:
        c, k, vm = R['c'], R['k'], R['vmax']
        half = 1.12 * vm / k
        t0, t1 = min(R['lo'], c - half) - 60, max(R['hi'], c + half) + 60          # transverse span
        best = None
        for F in frs:
            if F['axis'] == R['axis']:
                continue
            if not (R['lo'] - 250 <= F['oc'] <= R['hi'] + 250) or not (F['lo'] - 150 <= R['oc'] <= F['hi'] + 150):
                continue
            if not (300 <= abs(F['pt_per_frame']) * k <= 6000):
                continue                      # owner rule v2.106: a frame row measures 300..6000 mm per frame at the plan's written scale (zone numbers 1..6, section ids are not frames)
            tol = 0.05 if F.get('sparse') else 0.15            # a sparse row (labels skip numbers) must agree with the written scale more closely
            if fss and not any(1 - tol <= (fs / abs(F['pt_per_frame'])) / k <= 1 + tol for fs in fss):
                continue                      # that frame row is drawn at another scale (e.g. the small arrangement plan)
            miss = 0 if F['lo'] - 50 <= R['oc'] <= F['hi'] + 50 else min(abs(R['oc'] - F['lo']), abs(R['oc'] - F['hi']))
            key = (miss, abs(F['oc'] - (R['lo'] + R['hi']) / 2))
            if best is None or key < best[0]:
                best = (key, F)
        F = best[1] if best else None
        if F:
            pad = 1.5 * abs(F['pt_per_frame'])
            l0, l1 = F['lo'] - pad, F['hi'] + pad
        else:
            l0, l1 = R['oc'] - ROW_RADIUS, R['oc'] + ROW_RADIUS
        rect = (t0, l0, t1, l1) if R['axis'] == 'x' else (l0, t0, l1, t1)
        row = dict(page=pg, offcl_axis=R['axis'], offcl_c=round(c, 1), offcl_k=round(k, 3), offcl_n=R['n'], offcl_vmax=R['vmax'], offcl_mode=R['mode'],
                   offcl_row=round(R['oc'], 1), offcl_values='|'.join(str(v) for v in R.get('vals', [])), rect_x0=round(rect[0]), rect_y0=round(rect[1]), rect_x1=round(rect[2]), rect_y1=round(rect[3]),
                   frame_axis='', frame_ppf='', frame_f0='', frame_n='', frame_first='', frame_last='', frame_src='', frame_space=fss[0] if fss else '', kind='plan')
        if F:
            row.update(frame_axis=F['axis'], frame_ppf=F['pt_per_frame'], frame_f0=F['f0'], frame_n=F['n'], frame_first=F['first'], frame_last=F['last'], frame_src='own frame row')
        row.update(title='', title_dist='', deck='', height_ab='', x=round((rect[0] + rect[2]) / 2), y=round((rect[1] + rect[3]) / 2), _R=R, _rect=rect)
        out.append(row)
    # the same plan is often labelled on both edges: keep the first of footprints that coincide
    uniq = []
    for r in out:
        if not any(abs(r['offcl_c'] - u['offcl_c']) < 40 and u['offcl_axis'] == r['offcl_axis'] and abs(r['rect_x0'] - u['rect_x0']) < 60 and abs(r['rect_y0'] - u['rect_y0']) < 60 for u in uniq):
            uniq.append(r)
    # R-OF2: one title per plan. Each OFF C.L row is bound to the nearest still-unused plan title measured from the row's own point (centre line, label row);
    # a title names ONE plan (two plans of one sheet row no longer share a title)
    pairs = []
    for r in uniq:
        R_ = r['_R']
        px, py = (R_['c'], R_['oc']) if R_['axis'] == 'x' else (R_['oc'], R_['c'])
        for t in title_rows:
            if t['kind'] != 'plan':
                continue
            d_ = ((t['x'] - px) ** 2 + (t['y'] - py) ** 2) ** 0.5
            if d_ <= 900:
                pairs.append((d_, id(r), id(t), r, t))
    used_r, used_t = set(), set()
    for d_, _, _, r, t in sorted(pairs, key=lambda q: q[:3]):
        if id(r) in used_r or id(t) in used_t:
            continue
        used_r.add(id(r))
        used_t.add(id(t))
        r.update(title=t['title'], title_dist=round(d_), deck=t['deck'], height_ab=t['height_ab'], x=t['x'], y=t['y'])
    for r in uniq:        # a row left without a title (several footprints of ONE plan, e.g. both edges) takes the nearest title as before (R-OF2 fallback)
        if r['title'] == '':
            cands = [(_rect_dist(r['_rect'], t['x'], t['y']), t) for t in title_rows if t['kind'] == 'plan']
            cands = sorted([c_ for c_ in cands if c_[0] <= 700], key=lambda a: a[0])
            if cands:
                withh = [c_ for c_ in cands if c_[1]['height_ab'] != '' and c_[0] <= cands[0][0] + 150]
                tt = (withh or cands)[0]
                r.update(title=tt[1]['title'], title_dist=round(tt[0]), deck=tt[1]['deck'], height_ab=tt[1]['height_ab'], x=tt[1]['x'], y=tt[1]['y'])
    for r in uniq:
        r.pop('_R', None)
        r.pop('_rect', None)
    for k_, r in enumerate(uniq):
        r['row'] = k_
    return uniq


def build(folder, name, pages=None):
    pgs = pages or sorted(int(m.group(1)) for m in (re.search(r'_p(\d+)_text\.csv$', f) for f in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')))
                          if m and os.path.basename(m.string)[:-len(m.group(0))] == name)
    allp = []
    allf = []
    for pg in pgs:
        items = _items(os.path.join(folder, '%s_p%d_text.csv' % (name, pg)))
        segs = _segments(os.path.join(folder, '%s_p%d_segments.csv' % (name, pg)))
        vf = os.path.join(folder, '%s_p%d_views.csv' % (name, pg))
        views = list(csv.DictReader(open(vf, encoding='utf-8'))) if os.path.exists(vf) else []
        shs = [float(v['mm_per_pt']) for v in views if v.get('scale_source') == 'written(sheet)' and v.get('mm_per_pt')]
        page_sheet = statistics.median(shs) if shs else ''          # the title-block sheet scale (a region's own scale is not reliable, see viewscale.py)
        # a title is not a list of drawing names in the title block: '( A-DECK ~ C-DECK PLAN )', '(PLAN)', '( 2ND DECK PLAN ~ NO.3 STR. PLAN)'
        tl = [i for i in items if PLAN_RX.search(i['t']) and len(i['t']) < 80 and not NOT_RX.search(i['t'])
              and not (i['t'].lstrip().startswith('(') and not HEIGHT_RX.search(i['t']))]
        rows = []
        for k, t in enumerate(tl):
            kind = 'arrangement' if re.match(r"^\W*ARRG'?T\b", t['t'], re.I) else 'plan'
            sub = [i for i in items if (i['x'] - t['x']) ** 2 + (i['y'] - t['y']) ** 2 < LABEL_RADIUS ** 2
                   and min(tl, key=lambda q: (i['x'] - q['x']) ** 2 + (i['y'] - q['y']) ** 2) is t]     # a label belongs to the nearest title
            sheet = page_sheet
            oa = labels.offcl_axis(sub, (-1e9, -1e9, 1e9, 1e9), (t['x'], t['y']), sheet or None)
            fa = labels.frame_axis(items, (-1e9, -1e9, 1e9, 1e9), oa['axis'] if oa else None, (t['x'], t['y']), RADIUS)
            fs = [int(m.group(1).replace(',', '')) for i in sub for m in [labels.FRAMESP_RX.search(i['t'])] if m]
            h = HEIGHT_RX.search(t['t'])
            hnear = ''
            if not h:      # '( 30300 A/B )' written beside the title instead of inside it
                hs = [(((i['x'] - t['x']) ** 2 + (i['y'] - t['y']) ** 2) ** 0.5, int(HEIGHT_RX.search(i['t']).group(1))) for i in items
                      if HEIGHT_RX.search(i['t']) and i is not t and not PLAN_RX.search(i['t'])]
                hs = [q for q in hs if q[0] <= 220]
                hnear = min(hs)[1] if hs else ''
            r = dict(page=pg, row=k, title=t['t'][:70], kind=kind, deck=_deck(t['t'], kind), height_ab=int(h.group(1)) if h else hnear, x=round(t['x']), y=round(t['y']),
                     frame_space=fs[0] if fs else '', sheet_mm_per_pt=sheet,
                     offcl_axis='', offcl_c='', offcl_k='', offcl_n='', offcl_vmax='', offcl_mode='', offcl_row='', frame_axis='', frame_ppf='', frame_f0='', frame_n='', frame_first='', frame_last='', frame_src='')
            if oa:
                r.update(offcl_axis=oa['axis'], offcl_c=round(oa['c'], 1), offcl_k=round(oa['k'], 3), offcl_n=oa['n'], offcl_vmax=oa['vmax'], offcl_mode=oa['mode'], offcl_row=round(oa['oc'], 1))
            if fa and oa and not (300 <= abs(fa['pt_per_frame']) * oa['k'] <= 6000):
                fa = None
            if fa and not (oa and fs and not 0.85 <= (fs[0] / abs(fa['pt_per_frame'])) / oa['k'] <= 1.15):   # a frame row drawn at another scale is not this plan's
                r.update(frame_axis=fa['axis'], frame_ppf=fa['pt_per_frame'], frame_f0=fa['f0'], frame_n=fa['n'], frame_first=fa['first'], frame_last=fa['last'], frame_src='own frame row')
            ref = r['offcl_k'] if oa else ''
            if not ref and fa and fs:
                ref = fs[0] / abs(fa['pt_per_frame'])
            r['verdict'] = 'no label scale' if not ref else ('no sheet scale' if not sheet else
                           ('same as sheet' if abs(ref / sheet - 1) <= 0.15 else 'DIFFERENT: label %.1f vs sheet %.1f mm/pt (1/%d)' % (ref, sheet, round(ref * 72 / 25.4))))
            rows.append(r)
        for r in rows:       # keep numeric fields numeric for the alignment
            for kk in ('offcl_k', 'frame_space'):
                r[kk] = float(r[kk]) if r[kk] != '' else ''
        _align_from_sibling(rows, items)
        for r in rows:       # written frame spacing of the same deck's plan applies to its arrangement view; scale from the frame row = spacing / pt per frame
            if r['kind'] == 'arrangement' and r['frame_space'] == '':
                sib = [q['frame_space'] for q in rows if q['kind'] == 'plan' and q['deck'] == r['deck'] and q['frame_space'] != '']
                if sib:
                    r['frame_space'] = sib[0]
            r['frame_k'] = round(float(r['frame_space']) / abs(float(r['frame_ppf'])), 3) if r['frame_space'] != '' and r['frame_ppf'] != '' and r['frame_src'] == 'own frame row' else ''
            ref = r['offcl_k'] if r['offcl_k'] != '' else r['frame_k']
            sh_ = r['sheet_mm_per_pt']
            if ref != '' and sh_ != '':
                r['verdict'] = 'same as sheet' if abs(float(ref) / float(sh_) - 1) <= 0.15 else 'DIFFERENT: label %.1f vs sheet %.1f mm/pt (1/%d)' % (float(ref), float(sh_), round(float(ref) * 72 / 25.4))
        frames = build_frames(items, rows, page_sheet, pg)
        for fr_ in frames:
            fr_['kind'] = 'plan'
        # a footprint without a frame row at its own scale takes the sibling (ARRG'T ... ON <deck>) frame row, same method as before
        pseudo = [dict(kind='plan', deck=f_['deck'], offcl_axis=f_['offcl_axis'], frame_axis=f_['frame_axis'], frame_space=f_['frame_space'], offcl_k=f_['offcl_k'],
                       x=f_['x'], y=f_['y'], title=f_['title'], _f=f_) for f_ in frames] + [r for r in rows if r['kind'] == 'arrangement']
        _align_from_sibling(pseudo, items)
        for ps in pseudo:
            if '_f' in ps:
                ps['_f'].update({k_: ps[k_] for k_ in ('frame_axis', 'frame_ppf', 'frame_f0', 'frame_n', 'frame_first', 'frame_last', 'frame_src') if k_ in ps})
        marks = []
        for i in items:
            m = MARK_RX.match(i['t'])
            if not m:
                continue
            host, why, tdist = '', Counter(), 1e9
            cand = []
            for f_ in frames:
                ax = f_['offcl_axis']
                inside = f_['rect_x0'] <= i['x'] <= f_['rect_x1'] and f_['rect_y0'] <= i['y'] <= f_['rect_y1']
                if f_['frame_axis'] == '' and not inside:
                    # no frame row: the footprint is only a band round its label row - nearest label row, mark inside the transverse span
                    if abs(i['y' if ax == 'x' else 'x'] - f_['offcl_row']) > RADIUS:
                        why['mark outside every plan footprint'] += 1
                        continue
                    pos = i[ax]
                    if abs(pos - f_['offcl_c']) * f_['offcl_k'] > 1.12 * f_['offcl_vmax']:
                        why['mark outside every plan footprint'] += 1
                        continue
                    inside = True
                if not inside:
                    why['mark outside every plan footprint'] += 1
                    continue
                if f_['frame_axis'] != '':
                    fr = (i[f_['frame_axis']] - f_['frame_f0']) / f_['frame_ppf']
                    if not f_['frame_first'] - 1.5 <= fr <= f_['frame_last'] + 1.5:
                        why['mark outside the plan frame range'] += 1
                        continue
                area = (f_['rect_x1'] - f_['rect_x0']) * (f_['rect_y1'] - f_['rect_y0'])
                tdist = ((f_['x'] - i['x']) ** 2 + (f_['y'] - i['y']) ** 2) ** 0.5 if f_['title'] else 1e9
                cand.append((area if f_['frame_axis'] != '' else area * 4, f_, tdist))
            if cand:
                _, host, tdist = min(cand, key=lambda c_: (c_[0], c_[2]))
            reason = '' if host != '' else (why.most_common(1)[0][0] if why else 'no plan footprint on this page')
            marks.append(dict(page=pg, id=m.group(1).upper(), x=round(i['x']), y=round(i['y']), host=host['row'] if host != '' else '',
                              host_title=(host['title'] or '(untitled plan)') if host != '' else '', how=('inside footprint (OFF C.L row x frame row)' if host != '' and host['frame_axis'] != '' else 'near OFF C.L row (no frame row)') if host != '' else '',
                              z_ok=int(host != '' and (host['frame_axis'] != '' or tdist <= 700)), why=reason))
        allf += frames
        with open(os.path.join(folder, '%s_p%d_marks.csv' % (name, pg)), 'w', newline='', encoding='utf-8') as f:
            w = csv.DictWriter(f, ['page', 'id', 'x', 'y', 'host', 'host_title', 'how', 'z_ok', 'why'])
            w.writeheader()
            w.writerows(marks)
        allp += rows
    with open(os.path.join(folder, name + '_frames.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, FRAME_COLS, extrasaction='ignore')
        w.writeheader()
        w.writerows(allf)
    with open(os.path.join(folder, name + '_plans.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, PLAN_COLS, extrasaction='ignore')
        w.writeheader()
        w.writerows(allp)
    return allp


def load(folder, name):
    fp = os.path.join(folder, name + '_plans.csv')
    if not os.path.exists(fp):
        build(folder, name)
    num = ('page', 'row', 'x', 'y', 'height_ab', 'offcl_c', 'offcl_k', 'offcl_n', 'offcl_vmax', 'frame_ppf', 'frame_f0', 'frame_n', 'frame_first', 'frame_last', 'frame_space', 'sheet_mm_per_pt')
    out = []
    for r in csv.DictReader(open(fp, encoding='utf-8')):
        for k in num:
            r[k] = float(r[k]) if r[k] != '' else ''
        out.append(r)
    marks = []
    for pg in sorted({int(r['page']) for r in out} | set()):
        mf = os.path.join(folder, '%s_p%d_marks.csv' % (name, pg))
        if os.path.exists(mf):
            marks += list(csv.DictReader(open(mf, encoding='utf-8')))
    return out, marks


def load_frames(folder, name):
    """-> (frames, marks): the footprints (plans of reference) and every cut mark with its host footprint (Step 3 reads this)"""
    fp = os.path.join(folder, name + '_frames.csv')
    if not os.path.exists(fp):
        build(folder, name)
    num = ('page', 'row', 'x', 'y', 'height_ab', 'offcl_c', 'offcl_k', 'offcl_n', 'offcl_vmax', 'offcl_row', 'frame_ppf', 'frame_f0', 'frame_n', 'frame_first', 'frame_last', 'frame_space',
           'rect_x0', 'rect_y0', 'rect_x1', 'rect_y1')
    out = []
    for r in csv.DictReader(open(fp, encoding='utf-8')):
        for k in num:
            r[k] = float(r[k]) if r[k] != '' else ''
        out.append(r)
    marks = []
    for pg in sorted({int(r['page']) for r in out} | set(range(1, 40))):
        mf = os.path.join(folder, '%s_p%d_marks.csv' % (name, pg))
        if os.path.exists(mf):
            marks += list(csv.DictReader(open(mf, encoding='utf-8')))
    return out, marks
