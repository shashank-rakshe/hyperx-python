"""Longitudinal-bulkhead elevations of a drawing -> moulded-line wall panels XML.

  python -m deckrules.run_elev DRAWING.pdf --pages 1-5 --settings project_settings.json --out out_elev
"""
import re
import argparse, json, os, re, sys
from . import pdfsrc, view as dview, elevation
from .run import load_settings, frame_x_fn


DECK_Z_SOURCE = {}


_DH = {}


def deck_heights(pdf, npages):
    """P5: computed once per drawing per run"""
    import os
    k = (os.path.abspath(pdf), npages, os.path.getmtime(pdf))
    if k not in _DH:
        _DH[k] = _deck_heights(pdf, npages)
    return dict(_DH[k])


def _deck_heights(pdf, npages):
    z = {}
    hts = {}
    for pn in range(npages):
        for v in dview.find_deck_plans(pdfsrc.load_page(pdf, pn)):
            n = v.name.upper()
            from . import decknames
            code = decknames.key(n) or n[0]           # R-DN1: deck identity from its written name
            z.setdefault(code, float(v.z))
            if v.notes.get('height'):
                hts[code] = float(v.notes['height'])
    if 'A' in z:
        # R-E12: UPP. DECK = A-DECK minus the 'DECK HEIGHT' written on the A-DECK plan (height above the deck below), when that
        # lies below every other deck; the fixed 3200 offset only when the drawing writes no A-DECK height
        h = hts.get('A')
        if h and z['A'] - h < min(z.values()) - 1:
            z.setdefault('UPP', z['A'] - h)
            DECK_Z_SOURCE['UPP'] = f'A-DECK {z["A"]:g} - DECK HEIGHT {h:g} written on the A-DECK plan'
        else:
            z.setdefault('UPP', z['A'] - elevation.UPPER_OFFSET)
            DECK_Z_SOURCE['UPP'] = f'A-DECK - {elevation.UPPER_OFFSET:g} (no A-DECK height written: confirm)'
    return z


def _pdf_spacings(pdf, n):
    out = set()
    for i in range(n):
        pg = pdfsrc.load_page(pdf, i)
        txt = ' '.join(w.text for w in pg.words)
        for m in re.finditer(r'FRAME\s*SPAC\w*\s*:?\s*(\d[\d,]*)', txt):
            out.add(int(m.group(1).replace(',', '')))
    return out


def _frame_fns(page, settings, fx0, extra=()):
    import re
    out = [fx0]
    if settings.get('frame_spacing_mm') or settings.get('frame_table'):
        return out
    seen = {800} | set(extra)
    if extra:
        seen.discard(800)            # R-XV1: a written spacing exists -> the 800 default is not a candidate
    for w in page.words:
        for m in re.finditer(r'FRAME\s*SPAC\w*\s*:?\s*(\d[\d,]*)', w.text):
            seen.add(int(m.group(1).replace(',', '')))
    txt = ' '.join(w.text for w in page.words)
    for m in re.finditer(r'FRAME\s*SPAC\w*\s*:?\s*(\d[\d,]*)', txt):
        seen.add(int(m.group(1).replace(',', '')))
    x0 = settings.get('frame0_x_mm', 0.0)
    for sp in sorted(seen - {800}):
        out.append(lambda n, sp=sp: x0 + n * sp)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf')
    ap.add_argument('--pages', default='all', help="1-based, e.g. '3,5' or '1-5'")
    ap.add_argument('--settings')
    ap.add_argument('--out', required=True)
    ap.add_argument('--reference')
    a = ap.parse_args(argv)
    import pymupdf
    n = len(pymupdf.open(a.pdf))
    pages = range(1, n + 1) if a.pages == 'all' else [int(x) for p in a.pages.split(',') for x in
        (range(int(p.split('-')[0]), int(p.split('-')[1]) + 1) if '-' in p else [p])]
    settings = load_settings(a.settings)
    deck_z = deck_heights(a.pdf, n)
    os.makedirs(a.out, exist_ok=True)
    panels, report = [], {'views': {}, 'deck_z': deck_z}

    sp_all = _pdf_spacings(a.pdf, n)

    class _V:  # frame_x_fn wants an object with frame_space
        # R-XV1: ONE frame -> X function for every view of the drawing: the spacing written on the sheets ('FRAME SPACE : 1600'),
        # the same one the deck plans and frame sections use (R-V20); the 800 default only when nothing is written
        frame_space = (min(sp_all) if len(sp_all) == 1 else (sorted(sp_all)[0] if sp_all else 800)) if not settings.get('frame_spacing_mm') else settings['frame_spacing_mm']
    fx = frame_x_fn(settings, _V)
    for pn in pages:
        page = pdfsrc.load_page(a.pdf, pn - 1)
        scale = dview.sheet_scale(page) or 100
        sheet = None
        for v in elevation.find_views(page):
            key = f'p{pn} {v.name}'
            try:
                err = None
                for cand in _frame_fns(page, settings, fx, sp_all):       # R-E3e: spacing printed on the sheet ('FRAME SPACE : n')
                    try:
                        elevation.calibrate(page, v, cand, scale, deck_z)
                        err = None
                        break
                    except ValueError as e2:
                        err = e2
                        if 'uniform grid' not in str(e2):
                            break
                        v.decks, v.evidence = {}, {}
                if err:
                    raise err
                ws = elevation.extract(page, v, deck_z, settings)
                for _w in ws:
                    _w['sim'] = v.notes.get('sim')
            except Exception as e:
                report['views'][key] = {'status': 'FAILED', 'reason': str(e)}
                print(key, 'FAILED -', e)
                continue
            panels += ws
            report['views'][key] = {'status': 'ok', 'walls': len(ws), 'stiffeners': sum(len(w['stiffeners']) for w in ws),
                                    'unresolved_sections': sum(1 for w in ws for s in w['stiffeners'] if not s['section']),
                                    'evidence': v.evidence,
                                    'calib': {'page': pn, 'y': v.y, 'x0': v.x0, 'k': v.k, 'y_upp': v.y_upp, 'xr': list(v.xr) if v.xr else None,
                                              'ytop': v.ytop, 'ybot': v.row_cy, 'decks': dict(v.decks)}}          # Rule 5 needs the view transform
            print(key, 'ok', len(ws), 'walls', report['views'][key]['stiffeners'], 'stiffeners')
    from . import crossverify as _xv
    if (_xv.DECKS or _xv.WALLPLANS) and settings.get('cross_verify', True):
        # R-XV4 (owner 2026-10-25): a wall of an OFF C.L elevation stands on / under a deck: the deck plan above or below must show it
        # (a wall line or the deck edge at that Y over at least half of the wall). R-E9b: a 'wall' narrower than 400 mm is a
        # transverse wall seen edge-on (its stiffener 1 depth inside) - it belongs to the frame section at that X, not to this view.
        from shapely.geometry import LineString as _LS
        keep, drop = [], []
        for p_ in panels:
            u0, u1 = min(u for u, _ in p_['poly']), max(u for u, _ in p_['poly'])
            if p_.get('host_only') and p_.get('pipes'):           # R-PI2: a pipe is a pillar on its own host, not a narrow wall: never dropped
                keep.append(p_)
                continue
            if u1 - u0 < 400:
                drop.append(f"{p_['name']}: {u1 - u0:.0f} mm wide = transverse wall seen edge-on (R-E9b)")
                continue
            ds = [_xv.DECKS.get(round(deck_z.get(c, -1))) for c in p_['tier']]
            ds = [d for d in ds if d] + ([_xv.WALLPLANS[p_['tier'][0]]] if p_['tier'][0] in _xv.WALLPLANS else [])   # R-XV4c walls ON the lower deck
            if not ds:
                p_.setdefault('xv', 'no deck plan of this tier built: not cross-checked')
                keep.append(p_)
                continue
            Y = p_['y']
            checked, best, clip = _xv.wall_support('y', Y, u0, u1, ds)
            if clip is None:
                drop.append(f"{p_['name']}: outside every built deck of its tier (R-XV4b)")
                continue
            if not checked:
                p_.setdefault('xv', 'outside the built deck plans: not cross-checked')
                keep.append(p_)
                continue
            if best < 0.5 and p_.get('sim'):
                # R-XV4d: a view 'SIM. TO P-SIDE (EXC. AS SHOWN)' is the other side's wall: the plan line on that side confirms it
                ck2, best2, _ = _xv.wall_support('y', -Y, u0, u1, ds)
                if ck2 and best2 >= 0.5:
                    best = best2
                    p_['xv_mirror'] = f'R-XV4d confirmed on the plan line at Y={-Y:.0f} (view similar to the other side)'
            if best < 0.5:
                drop.append(f"{p_['name']}: no wall line / deck edge at Y={Y:.0f} in the deck plan above or below ({best:.0%})")
                continue
            if _xv.clip_panel(p_, clip[0], clip[1], 'x'):
                drop.append(f"{p_['name']}: cut to X {clip[0]:.0f}..{clip[1]:.0f} = inside the deck(s) it connects (R-XV4b)")
            p_['xv'] = f'R-XV4 on the deck plan wall line / edge ({best:.0%})'
            keep.append(p_)
        panels[:] = keep
        report['xv_walls_dropped'] = drop
        # R-CB9: a wall / OFF C.L member meets a CAMBERED deck along the sloping deck surface: its top (or foot) edge at its OFF C.L Y is
        # the deck height THERE (deck z minus slope x distance from the knuckle), not the deck's centre height.  Universal: every wall of every tier.
        ncam = 0
        for p_ in panels:
            if p_.get('host_only'):
                continue
            Yw = abs(p_['y'])
            zs = [z for _, z in p_['poly']]
            for code in p_['tier']:
                d_ = _xv.DECKS.get(round(deck_z.get(code, -1)))
                cm = d_ and d_.get('camber')
                if not cm:
                    continue
                sl = cm['n'] / max(cm['outer'] - cm['inner'], 1.0)
                dd = min(max(Yw - cm['knuckle'], 0.0), cm['outer'] - cm['knuckle'])
                zc = d_['z_flat'] - sl * dd
                zref = deck_z[code]
                new_poly = []
                for (u_, z_) in p_['poly']:
                    new_poly.append((u_, z_ - (d_['z_flat'] - zc)) if abs(z_ - zref) < 60 else (u_, z_))
                for st_ in p_.get('stiffeners', []):           # stiffener ends that reach the deck follow the same surface
                    for k_ in ('a_z', 'b_z'):
                        if st_.get(k_) is not None and abs(st_[k_] - zref) < 60:
                            st_[k_] = st_[k_] - (d_['z_flat'] - zc)
                for r_ in p_.get('pipes', []):
                    for k_ in ('z0', 'z1'):
                        if abs(r_[k_] - zref) < 60:
                            r_[k_] = r_[k_] - (d_['z_flat'] - zc)
                if new_poly != p_['poly']:
                    p_['poly'] = new_poly
                    p_.setdefault('camber_note', []).append(f"R-CB9 {code} deck height at Y={Yw:.0f}: {zc:.0f} (flat {d_['z_flat']:.0f})")
                    ncam += 1
        report['camber_walls'] = ncam
    _note = _xv.symmetric_note(a.pdf)
    if settings.get('symmetry_mirror', True) and (_note or any(p_.get('sim') for p_ in panels)):
        # R-SY2/R-SY3: 'BOTH SIDES ARE SYMMETRIC EXCEPT AS SHOWN' / 'SIM. TO PORT SIDE EXCEPT AS SHOWN' -> the other side takes the drawn side
        settings['mirror_missing_side'] = True
        report['symmetry_note'] = _note
        import copy as _cp
        nfill = 0
        for p_ in panels:
            src = p_.get('sim')
            if not src:
                continue
            twins = [q for q in panels if q is not p_ and q['tier'] == p_['tier'] and abs(q['y'] + p_['y']) < 5 and not q.get('sim')]
            u0, u1 = min(u for u, _ in p_['poly']), max(u for u, _ in p_['poly'])
            for q in twins:
                for o in p_['stiffeners']:          # R-SY3b: a line of the similar view without its own size takes the size of the drawn side at that X
                    if o.get('section'):
                        continue
                    tw = min(q['stiffeners'], key=lambda t: abs(t['x'] - o['x']), default=None)
                    if tw is not None and abs(tw['x'] - o['x']) < 150 and tw.get('section'):
                        o['section'] = tw['section']
                        o['evidence'] = (f"R-SY3b size from {q['name'].split('|')[0]} at the same X ({src} side similar); " + o['evidence'])[:300]
                        nfill += 1
                for st in q['stiffeners']:
                    if not (u0 + 1 < st['x'] < u1 - 1) or any(abs(st['x'] - o['x']) < 150 for o in p_['stiffeners']):
                        continue
                    n_ = _cp.deepcopy(st)
                    n_['evidence'] = (f"R-SY3 {p_['name'].split('|')[0]} 'SIM. TO {src} SIDE EXCEPT AS SHOWN': from {q['name'].split('|')[0]} " + st['evidence'])[:300]
                    p_['stiffeners'].append(n_)
                    nfill += 1
            z0_, z1_ = min(z for _, z in p_['poly']), max(z for _, z in p_['poly'])
            for q in [q for q in panels if q is not p_ and abs(q['y'] + p_['y']) < 5 and not q.get('sim')]:
                for st in q.get('hstiff', []):      # R-SY3 for R-E24 horizontal longitudinals: same Z, over the common X span
                    if not (z0_ + 50 < st['z'] < z1_ - 50):
                        continue
                    a_, b_ = max(u0, st['x0']), min(u1, st['x1'])
                    if b_ - a_ < 300 or any(abs(st['z'] - o['z']) < 60 for o in p_.get('hstiff', [])):
                        continue
                    n_ = _cp.deepcopy(st)
                    n_['x0'], n_['x1'] = a_, b_
                    n_['evidence'] = (f"R-SY3 'SIM. TO {src} SIDE EXCEPT AS SHOWN': from {q['name'].split('|')[0]} " + st['evidence'])[:300]
                    p_.setdefault('hstiff', []).append(n_)
                    nfill += 1
        report['sim_side_stiffeners_copied'] = nfill
    if settings.get('mirror_missing_side', False):
        from .mirror import mirror_walls
        extra = mirror_walls(panels)
        panels += extra
        report['mirrored_panels'] = len(extra)
    xml = os.path.join(a.out, 'WALLS_moulded.xml')
    _xv.ELEV_WALLS[:] = [(p_['y'], min(v_ for _, v_ in p_['poly']), max(v_ for _, v_ in p_['poly']),
                          min(u for u, _ in p_['poly']), max(u for u, _ in p_['poly'])) for p_ in panels if not p_.get('host_only')]   # R-S17 cross-check
    elevation.write_walls(xml, panels, settings)
    json.dump(report, open(os.path.join(a.out, 'WALLS_report.json'), 'w'), indent=1, default=str)
    report['pipes_pending'] = settings.get('_pipes_pending', [])
    report['pipes_written'] = sum(len(w_.get('pipes', [])) for w_ in panels) - len(report['pipes_pending'])
    print('wrote', xml, len(panels), 'wall panels;', report['pipes_written'], 'pipes written,', len(report['pipes_pending']), 'pipes pending (no pipe table row)')
    return panels, report


if __name__ == '__main__':
    main()
