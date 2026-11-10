"""Step 2 (Rule 2 a-d) - the scale of EACH VIEW (title), not of a region.

Old behaviour (wrong): a Step-2 region is a grown cluster of line work; one '(S : 1/50)' anywhere inside a region that swallowed the whole sheet
gave the whole region 1/50 (1005-DH-FIN: 17.6, 8.8, 3.5 mm/pt on 1/100 plans).  A written scale belongs to the view whose title it stands next to.

Per title, in the owner's order (written text first):
  1. LABEL scale  - the drawing's own written dimension numbers (OFF C.L row, FRAME SPACE x frame row) give mm/pt directly (plans.csv)
  2. WRITTEN scale text '(S : 1/50)' / 'SCALE : 1/50' standing next to THIS title (nearest title wins, <= NEAR pt), x page reduction factor f
  3. NON SCALE text next to the title -> non-scale
  4. SHEET scale of the title block x f
  5. nothing -> none
f = (mm/pt of a sheet-scale view) / (25.4/72 x sheet denominator), read from the Step-2 views table.
Where 1 and 2 are both present they are compared: agree / DIFFERENT (label wins, flagged).
Output <name>_viewscale.csv: page,title,type,id,x,y,written_den,written_text,label_mm_per_pt,sheet_mm_per_pt,mm_per_pt,source,status
Region rows of <name>_pN_views.csv whose titles disagree are marked MIXED (their single scale was never valid)."""
import csv, os, re, glob, statistics
from . import rule2, facts, plans as plans_mod

NEAR = 260.0
PT_MM = 25.4 / 72.0


def _near(w, t):
    return abs(t['x'] - w['x']) * 0.6 + abs(t['y'] - w['y'])


def build(folder, name):
    F = facts.load(folder, name)
    P, _ = plans_mod.load(folder, name)
    plan_k = {(int(p['page']), p['title']): p for p in P if p['offcl_k'] != '' or p['frame_k'] != ''}
    pgs = sorted({r['page'] for r in F})
    out = []
    page_sheet = {}                                          # sheet scale of every page that states one in its title block
    for pg in pgs:
        vf = os.path.join(folder, '%s_p%d_views.csv' % (name, pg))
        if os.path.exists(vf):
            sh = [(float(v['mm_per_pt']), int(float(v['denominator']))) for v in csv.DictReader(open(vf, encoding='utf-8')) if v['scale_source'] == 'written(sheet)' and v['mm_per_pt']]
            if sh:
                page_sheet[pg] = (statistics.median([a for a, d in sh]), sh[0][1])
    drawing_sheet = None
    if page_sheet:
        dens = [d for a, d in page_sheet.values()]
        den0 = max(set(dens), key=dens.count)
        drawing_sheet = (statistics.median([a for a, d in page_sheet.values() if d == den0]), den0)   # the drawing's sheets share one title-block scale
    for pg in pgs:
        items = rule2._read_text(os.path.join(folder, '%s_p%d_text.csv' % (name, pg)))
        written = rule2.find_written(items)
        vf = os.path.join(folder, '%s_p%d_views.csv' % (name, pg))
        views = list(csv.DictReader(open(vf, encoding='utf-8'))) if os.path.exists(vf) else []
        sheet_mm, sheet_den = page_sheet.get(pg, drawing_sheet) if (page_sheet or drawing_sheet) else (None, None)
        other_page = pg not in page_sheet and drawing_sheet is not None
        f = (sheet_mm / (PT_MM * sheet_den)) if sheet_mm and sheet_den else 1.0
        titles = [r for r in F if r['page'] == pg and r['kind'] == 'title']
        vw = [w for w in written if w['kind'] == 'view']
        nw = [w for w in written if w['kind'] == 'nonscale']
        own = {}
        for w in vw + nw:                                    # a written scale belongs to the nearest title
            if titles:
                t = min(titles, key=lambda t: _near(w, t))
                if _near(w, t) <= NEAR:
                    own.setdefault(id(t), []).append(w)
        for t in titles:
            ws = own.get(id(t), [])
            wv = [w for w in ws if w['kind'] == 'view']
            wn = [w for w in ws if w['kind'] == 'nonscale']
            pl = plan_k.get((pg, t['text'][:70]))
            lab = (float(pl['offcl_k']) if pl['offcl_k'] != '' else float(pl['frame_k'])) if pl else None
            wden = wv[0]['den'] if wv else None
            wmm = rule2.mm_per_pt(wden, f) if wden else None
            if lab:
                mm, src = lab, ('label(OFF C.L written)' if pl['offcl_k'] != '' else 'label(FRAME SPACE x frame row written)')
                st = 'label only' if not wmm else ('agree' if abs(lab / wmm - 1) <= 0.12 else 'DIFFERENT: label %.1f vs text 1/%d = %.1f mm/pt (label kept)' % (lab, wden, wmm))
            elif wmm:
                mm, src, st = wmm, 'written(view text next to title)', 'text only'
            elif wn:
                mm, src, st = None, 'written(non-scale)', 'non-scale'
            elif sheet_mm:
                mm, src, st = sheet_mm, 'written(sheet)' if not other_page else 'written(sheet, other page of this drawing)', 'sheet scale (no own scale written)'
            else:
                mm, src, st = None, 'none', 'no scale'
            out.append(dict(page=pg, title=t['text'][:70], type=t['type'], id=t['id'], x=t['x'], y=t['y'], written_den=wden or '',
                            written_text=wv[0]['text'][:30] if wv else (wn[0]['text'][:30] if wn else ''), label_mm_per_pt=round(lab, 3) if lab else '',
                            sheet_mm_per_pt=round(sheet_mm, 3) if sheet_mm else '', mm_per_pt=round(mm, 3) if mm else '', source=src, status=st))
        # region rows: a region holding titles with different scales has no single scale
        if views:
            mine = [o for o in out if o['page'] == pg]
            ch = False
            for v in views:
                inside = [o for o in mine if float(v['x0']) - 5 <= o['x'] <= float(v['x1']) + 5 and float(v['y0']) - 5 <= o['y'] <= float(v['y1']) + 5 and o['mm_per_pt'] != '']
                sc = {round(o['mm_per_pt'], 0) for o in inside}
                if len(sc) > 1:
                    v['denominator'], v['mm_per_pt'], v['scale_source'], v['status'] = '', '', 'MIXED', 'MIXED: %d scales inside (see viewscale.csv)' % len(sc)
                    ch = True
            if ch:
                with open(vf, 'w', newline='', encoding='utf-8') as fh:
                    w = csv.DictWriter(fh, list(views[0].keys()))
                    w.writeheader()
                    w.writerows(views)
    with open(os.path.join(folder, name + '_viewscale.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.DictWriter(fh, ['page', 'title', 'type', 'id', 'x', 'y', 'written_den', 'written_text', 'label_mm_per_pt', 'sheet_mm_per_pt', 'mm_per_pt', 'source', 'status'])
        w.writeheader()
        w.writerows(out)
    return out


def load(folder, name):
    fp = os.path.join(folder, name + '_viewscale.csv')
    if not os.path.exists(fp):
        build(folder, name)
    return list(csv.DictReader(open(fp, encoding='utf-8')))
