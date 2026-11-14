"""Frame sections of a drawing -> X-normal panels XML.
  python -m deckrules.run_sec DRAWING.pdf --pages all --settings project_settings.json --out out_sec
"""
import argparse, json, os
from . import pdfsrc, view as dview, elevation, section, run_elev
from .run import load_settings


def wall_ys(pdf, pages):
    s = set()
    for pn in pages:
        for v in elevation.find_views(pdfsrc.load_page(pdf, pn - 1)):
            if v.y:
                s.add(abs(float(v.y)))
    return sorted(s)


def _one_deck(page, v):
    """deck names / heights printed in the view (horizontal or vertical): 'E/C MONORAIL HOIST DECK', '41450 A/B', 'A - DECK' ..."""
    import re as _re
    x0, y0, x1, y1 = v.region
    y1 = min(y1, y0 + 200)
    lng = [s_ for s_ in page.segs if s_.kind == 'l' and s_.length > 200 and abs(s_.a[1] - s_.b[1]) < 0.05 * s_.length and y0 < s_.a[1] < y1
           and min(s_.a[0], s_.b[0]) < x1 and max(s_.a[0], s_.b[0]) > x0]
    if lng:                   # a long strip view reaches past the title window: its extent is the extent of its long deck line
        x0 = min(x0, min(min(s_.a[0], s_.b[0]) for s_ in lng))
        x1 = max(x1, max(max(s_.a[0], s_.b[0]) for s_ in lng))
    labs = [w.text.strip() for w in page.words if x0 - 60 < w.cx < x1 + 160 and y0 - 10 < w.cy < y1 + 20 and
            (_re.match(r'^\s*\(?\d{5}\s*A/B\)?\s*$', w.text) or _re.search(r'DECK\s*$', w.text) or section.DECK_LABEL.match(w.text) or __import__('deckrules.decknames', fromlist=['key']).key(w.text))]
    return ', '.join(sorted(set(labs))) if labs else None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf')
    ap.add_argument('--pages', default='all')
    ap.add_argument('--settings')
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    import pymupdf
    n = len(pymupdf.open(a.pdf))
    pages = list(range(1, n + 1)) if a.pages == 'all' else [int(x) for p in a.pages.split(',') for x in
        (range(int(p.split('-')[0]), int(p.split('-')[1]) + 1) if '-' in p else [p])]
    settings = load_settings(a.settings)
    sp = settings.get('frame_spacing_mm')
    if not sp:                                  # R-V20: frame spacing printed on the sheet ('FRAME SPACE: 3545') before any default
        import re as _r0
        for _p0 in range(n):
            for _w0 in pdfsrc.load_page(a.pdf, _p0).words:
                _m0 = _r0.search(r'FRAME SPACE\s*:\s*(\d[\d,]*)', _w0.text)
                if _m0:
                    sp = int(_m0.group(1).replace(',', ''))
                    break
            if sp:
                break
    sp = sp or 800
    from .run import frame_x_fn
    class _V:
        frame_space = sp
    sp = frame_x_fn(settings, _V)          # frame table / owner anchor / spacing
    deck_z = run_elev.deck_heights(a.pdf, n)
    for _c in getattr(run_elev, 'DECK_Z_SOURCE', {}):
        section.DERIVED.add(_c)             # R-S6 + R-E12: any deck height not printed on a plan title (UPP = A - written DECK HEIGHT) is measured per view
    if 'UPP' in deck_z and 'A' in deck_z and abs(deck_z['A'] - deck_z['UPP'] - elevation.UPPER_OFFSET) < 1:
        section.DERIVED.add('UPP')          # R-S6: UPP. DECK height derived from A - offset: measured in each view, never calibrates
    # R-V19: decks named by their height ('37160 A/B') or by the camber-scheme top ('COMP. ROOM TOP') in the sections
    import re as _re
    from . import view as _view
    for _pn in range(n):
        _pg = pdfsrc.load_page(a.pdf, _pn)
        from . import decknames as _dn
        for _w in _pg.words:
            _m = _re.match(r'^\s*\(?\s*(\d{4,5})\s*A/B\s*\)?\s*$', _w.text)
            if _m and not _w.vertical:
                _z = float(_m.group(1))
                # R-E15b (sections): a deck NAME without a plan height with its height label right under it is that deck
                _nm = [u for u in _pg.words if u is not _w and not u.vertical and abs(u.cx - _w.cx) < 40 and 0 < _w.cy - u.cy < 20
                       and _dn.key(u.text)]
                if _nm and _dn.key(_nm[0].text) not in deck_z:
                    deck_z[_dn.key(_nm[0].text)] = _z
                    continue
                if not any(abs(z_ - _z) <= 20 for z_ in deck_z.values()):
                    deck_z.setdefault('Z' + _m.group(1), _z)
        _cs = _view.camber_scheme(_pg)
        if _cs and _cs.get('top'):
            deck_z.setdefault('CRT', float(_cs['top']))
    from . import members as _mem
    for _p1 in range(n):
        _t1 = _mem.carling_table(pdfsrc.load_page(a.pdf, _p1))
        if len(_t1) >= 3:
            _mem.GLOBAL_CARL.update(_t1)
            break
    wys = wall_ys(a.pdf, range(1, n + 1))
    section.REBASE = set(int(x) for x in settings.get('subtitle_rebase', []))      # R-SS1
    os.makedirs(a.out, exist_ok=True)
    panels, report = [], {'views': {}, 'deck_z': deck_z, 'wall_ys': wys}
    for pn in pages:
        page = pdfsrc.load_page(a.pdf, pn - 1)
        scale = dview.sheet_scale(page) or 100
        sheet = None
        import re as _rt
        for _w in page.words:          # R-S13: a section title with no frame ('TYPICAL SECTION') has no X: not built, the owner is asked
            if _w.size >= 12 and _rt.match(r'^\s*TYPICAL\s+SEC', _w.text) and f'p{pn} {_w.text.strip()}' not in report['views']:
                report['views'][f'p{pn} {_w.text.strip()}'] = {'status': 'question', 'reason': 'no frame / X written for this section: which frames does it apply to? (R-S13, not built)'}
                print(f'p{pn} {_w.text.strip()}', 'question - no frame written (R-S13)')
        for v in section.find_views(page, sp):
            key = f'p{pn} {v.name} X={v.X:g}'
            try:
                section.calibrate(page, v, scale, deck_z)
                ps = section.extract(page, v, deck_z, settings, wys)
            except Exception as e:
                one = _one_deck(page, v) if 'fewer than two deck labels' in str(e) else None
                if one:
                    # R-S11: a section that shows ONE deck only (deck plate + members under it, no deck below) has no wall panel between
                    # two decks: it is a deck cut, used to cross-check that deck's members (R-XV2); not a failure
                    report['views'][key] = {'status': 'deck-cut', 'reason': f'one deck only ({one}): deck cut, no wall panel (R-S11)'}
                    print(key, 'deck-cut -', one)
                    continue
                report['views'][key] = {'status': 'FAILED', 'reason': str(e)}
                print(key, 'FAILED -', e)
                continue
            panels += ps
            report['views'][key] = {'status': 'ok', 'panels': len(ps), 'stiffeners': sum(len(p['stiffeners']) for p in ps),
                                    'unresolved_sections': sum(1 for p in ps for s in p['stiffeners'] if not s['section']),
                                    'evidence': v.evidence,
                                    'calib': {'page': pn, 'X': v.X, 'xcl': v.xcl, 'yz0': v.yz0, 'k': v.k, 's': v.s,
                                              'region': list(v.region) if v.region else None, 'decks': dict(v.decks)}}    # Rule 5
            print(key, 'ok', len(ps), 'panels', report['views'][key]['stiffeners'], 'stiffeners')
    from . import crossverify as _xv
    if (_xv.DECKS or _xv.WALLPLANS) and settings.get('cross_verify', True):
        # R-XV4 for frame sections: a wall panel at X stands on / under a deck: the deck plan above or below shows a wall line or its edge at X
        from shapely.geometry import LineString as _LS
        keep, drop = [], []
        for p_ in panels:
            us = [u for u, _ in p_['poly']]
            u0, u1 = min(us), max(us)
            ds = [_xv.DECKS.get(round(deck_z.get(c, -1))) for c in p_['tier']]
            ds = [d for d in ds if d] + ([_xv.WALLPLANS[p_['tier'][0]]] if p_['tier'][0] in _xv.WALLPLANS else [])   # R-XV4c walls ON the lower deck
            if not ds or u1 - u0 < 400:
                keep.append(p_)
                continue
            X = p_['x']
            checked, best, clip = _xv.wall_support('x', X, u0, u1, ds)
            if clip is None:
                drop.append(f"{p_['name']}: outside every built deck of its tier (R-XV4b)")
                continue
            if not checked:
                keep.append(p_)
                continue
            if best < 0.5:
                drop.append(f"{p_['name']}: no wall line / deck edge at X={X:.0f} Y {u0:.0f}..{u1:.0f} in the deck plan above or below ({best:.0%})")
                continue
            if _xv.clip_panel(p_, clip[0], clip[1], 'u'):
                drop.append(f"{p_['name']}: cut to Y {clip[0]:.0f}..{clip[1]:.0f} = inside the deck(s) it connects (R-XV4b)")
            keep.append(p_)
        panels[:] = keep
        report['xv_walls_dropped'] = drop
    if settings.get('symmetry_mirror', True) and _xv.symmetric_note(a.pdf):
        settings['mirror_missing_side'] = True              # R-SY2: drawing note 'BOTH SIDES ARE SYMMETRIC EXCEPT AS SHOWN'
        report['symmetry_note'] = _xv.symmetric_note(a.pdf)
    if settings.get('mirror_missing_side', False):
        from .mirror import mirror_sections
        extra = mirror_sections(panels)
        panels += extra
        report['mirrored_panels'] = len(extra)
    xml = os.path.join(a.out, 'FRAMES_moulded.xml')
    section.write(xml, panels, settings)
    json.dump(report, open(os.path.join(a.out, 'FRAMES_report.json'), 'w'), indent=1, default=str)
    print('wrote', xml, len(panels), 'panels')
    return panels, report


if __name__ == '__main__':
    main()
