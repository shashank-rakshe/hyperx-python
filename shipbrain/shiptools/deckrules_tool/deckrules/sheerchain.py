"""Step 2: sheer range read from the dimension chain beside the printed '(SHEER : n)' (owner rule v2.90).

  strip  ('REVERSE (SHEER : 50)' + a 3-4 digit dimension L beside it): the dimension text stands at the middle of its chain, so the strip is
          frame(text) -/+ L / 2 / FRAME SPACE.
  whole  ('SLANTED' + end heights 'Za A/B' ... 'Zb A/B' at the two ends of the plan): the range is the frames at the two end-height labels.
  frames : the frame row beside the label (consecutive OR sparse integer labels), scale = FRAME SPACE / pt-per-frame.
Output <name>_sheerchain.csv. Anything that cannot be read stays empty -> the tool asks the user.
"""
import csv, os, re, glob, statistics
from . import labels

SH = re.compile(r'SHEER\s*:?\s*(\d{2,4})')
FS = re.compile(r'FRAME\s*SPACE\s*:?\s*(\d{3,4})')
AB = re.compile(r'^\(?\s*(\d{5})\s*A/B\s*\)?$')
DIM = re.compile(r'^\d{3,4}$')
COLS = ['page', 'x', 'y', 'text', 'n', 'mode', 'deck', 'dim_mm', 'from_fr', 'to_fr', 'frame_mm_per_pt', 'frame_labels', 'how']


def _items(fp):
    out = []
    for r in csv.DictReader(open(fp, encoding='utf-8')):
        t = (r['text'] or '').strip()
        if t:
            x0, y0, x1, y1 = (float(r[k]) for k in ('x0', 'y0', 'x1', 'y1'))
            out.append(dict(t=t, x=(x0 + x1) / 2, y=(y0 + y1) / 2))
    return out


def _row_for(rows, px, py, radius=900):
    best = None
    for r in rows:
        along, perp = (px, py) if r['axis'] == 'x' else (py, px)
        d = abs(perp - r['oc'])
        if d <= radius and r['lo'] - 400 <= along <= r['hi'] + 400 and (best is None or d < best[0]):
            best = (d, r)
    return best[1] if best else None


def _fr(r, px, py):
    return (((px if r['axis'] == 'x' else py) - r['f0']) / r['pt_per_frame'])


def build(folder, name):
    from . import ask as _ask
    facts = os.path.join(folder, name + '_facts.csv')
    titles = {}
    if os.path.exists(facts):
        for r in csv.DictReader(open(facts, encoding='utf-8')):
            if r['kind'] == 'title' and r['deck'] and '~' not in r['deck'] and r['type'] in ('deck-plan', 'arrangement'):
                titles.setdefault(r['page'], []).append((float(r['x']), float(r['y']), r['deck'].strip().upper()))
    out, drawing_fs = [], None
    pages = []
    for tf in glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv')):
        m = re.search(r'_p(\d+)_text\.csv$', tf)
        if m and os.path.basename(tf)[:-len(m.group(0))] == name:
            pages.append((int(m.group(1)), tf))
    for pg, tf in sorted(pages):
        items = _items(tf)
        fs_vals = [int(FS.search(i['t'].upper()).group(1)) for i in items if FS.search(i['t'].upper())]
        fs = statistics.median(fs_vals) if fs_vals else drawing_fs
        if fs_vals:
            drawing_fs = fs
        mentions = [i for i in items if SH.search(i['t'].upper())]
        if not mentions or not fs:
            continue
        rows = labels.frame_rows(items) + labels.sparse_frame_rows(items)
        rows = [r for r in rows if r.get('sparse') or True]
        for w in mentions:
            n = int(SH.search(w['t'].upper()).group(1))
            row = _row_for(rows, w['x'], w['y'])
            rec = dict(page=pg, x=round(w['x']), y=round(w['y']), text=w['t'], n=n, mode='', deck='', dim_mm='', from_fr='', to_fr='', frame_mm_per_pt='', frame_labels='', how='')
            tt = titles.get(str(pg), [])
            if tt:
                d = min(tt, key=lambda t: (t[0] - w['x']) ** 2 + (t[1] - w['y']) ** 2)
                if (d[0] - w['x']) ** 2 + (d[1] - w['y']) ** 2 <= 1500 ** 2:
                    rec['deck'] = d[2]
            if not row:
                rec['how'] = 'no frame row beside the label'
                out.append(rec)
                continue
            if row['n'] < 4 and row.get('sparse'):
                pass
            mmpp = fs / abs(row['pt_per_frame'])
            rec['frame_mm_per_pt'] = round(mmpp, 2)
            rec['frame_labels'] = row['n']
            near = [i for i in items if (i['x'] - w['x']) ** 2 + (i['y'] - w['y']) ** 2 <= 70 ** 2]
            slanted = any(i['t'].upper().startswith('SLANTED') for i in near)
            if slanted:
                ends = [i for i in items if AB.match(i['t'].upper()) and abs((i['x'] if row['axis'] == 'y' else i['y']) - (w['x'] if row['axis'] == 'y' else w['y'])) <= 40
                        and ((i['x'] - w['x']) ** 2 + (i['y'] - w['y']) ** 2) <= 700 ** 2]
                vals = {}
                for i in ends:
                    vals.setdefault(AB.match(i['t'].upper()).group(1), i)
                if len(vals) >= 2:
                    along = sorted(((i['y'] if row['axis'] == 'y' else i['x']) for i in vals.values()))
                    a, b = _fr(row, w['x'] if row['axis'] == 'x' else 0, 0) if False else None, None
                    pa = [_fr(row, i['x'], i['y']) for i in vals.values()]
                    rec.update(mode='whole', from_fr=round(min(pa), 1), to_fr=round(max(pa), 1), how='SLANTED + end heights %s' % '/'.join(sorted(vals)))
                else:
                    rec.update(mode='whole', how='SLANTED but end heights not found')
            else:
                dims = [i for i in near if DIM.match(i['t']) and 300 <= int(i['t']) <= 3000]
                if dims:
                    dd = min(dims, key=lambda i: (i['x'] - w['x']) ** 2 + (i['y'] - w['y']) ** 2)
                    L = int(dd['t'])
                    c = _fr(row, dd['x'], dd['y'])
                    h = L / 2.0 / fs
                    rec.update(mode='strip', dim_mm=L, from_fr=round(c - h, 1), to_fr=round(c + h, 1), how='dimension %d beside the label, centred at FR %.1f' % (L, c))
                else:
                    rec['how'] = 'no dimension beside the label'
            out.append(rec)
    with open(os.path.join(folder, name + '_sheerchain.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, COLS)
        w.writeheader()
        w.writerows(out)
    return out


def load(folder, name):
    fp = os.path.join(folder, name + '_sheerchain.csv')
    return list(csv.DictReader(open(fp, encoding='utf-8'))) if os.path.exists(fp) else []
