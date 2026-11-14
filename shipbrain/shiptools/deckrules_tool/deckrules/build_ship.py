import os
"""ONE command, fully offline: drawing PDF (vector, or scan via local OCR) -> complete moulded-line ship XML.

  python -m deckrules.build_ship DRAWING.pdf --settings settings.json --out build_out [--raster] [--pages 1-5]

Runs, for every page:  deck / strake plans (R-V*, R-FP*, R-HM*, ...)  ->  longitudinal wall elevations (R-E*)
                       ->  transverse frame sections (R-S*)
then merges everything (R-AS), validates the XML (C1-C8) and writes BUILD_REPORT.md / .json: what was built, what
failed and WHY (so the rules can be extended), and the open decisions that need an owner.
Nothing leaves the machine; no reference XML is read.
"""
import argparse, contextlib, glob, io, json, os, re, sys, copy
from lxml import etree


def _pages(spec, n):
    if spec == 'all':
        return list(range(1, n + 1))
    out = []
    for p in spec.split(','):
        if '-' in p:
            a, b = p.split('-')
            out += list(range(int(a), int(b) + 1))
        else:
            out.append(int(p))
    return [p for p in out if 1 <= p <= n]


def _page_count(path):
    import pymupdf
    return len(pymupdf.open(path))


def merge(files, out_path):
    root = etree.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine',
                         Source='deckrules build_ship (PDF drawing only)')
    mats, bars, blocks = {}, {}, []
    names = set()
    for f in files:
        r = etree.parse(f).getroot()
        for m in r.findall('Material'):
            mats.setdefault(m.get('Grade'), m)
        for b in r.findall('BarSection'):
            bars.setdefault(b.get('BarSectionId'), b)
        for b in r.findall('Block'):
            if not b.findall('.//Stiffener') and not b.findall('.//Plate') and not b.findall('.//PillarGroup'):   # R-PI2: a pipe-only panel is a member
                continue
            oid = b.get('ObjId')
            k = 2
            while oid in names:                      # R-AS3: block names unique across pages
                oid = f"{b.get('ObjId')}_{k}"
                k += 1
            if oid != b.get('ObjId'):
                b.set('ObjId', oid)
            names.add(oid)
            blocks.append(b)
    if any(g.get('Grade') == 'AH' for g in ({} if False else [m for b in blocks for m in b.iter('Material')])) and 'AH' not in mats:
        mats['AH'] = etree.Element('Material', Grade='AH')     # note 5: marked "AH" = grade AH steel
    for e in list(mats.values()) + sorted(bars.values(), key=lambda b: b.get('BarSectionId')) + blocks:
        root.append(copy.deepcopy(e))
    etree.ElementTree(root).write(out_path, xml_declaration=True, encoding='utf-8', pretty_print=True)
    return len(blocks), len(bars)


def main(argv=None):
    from . import runstate
    runstate.reset()          # P7: nothing carries over from an earlier drawing in this process
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('pdf')
    ap.add_argument('--settings', help='project settings json (frame spacing / table, section aliases)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--pages', default='all')
    ap.add_argument('--raster', action='store_true', help='scan / image drawings: use the local OCR front end')
    ap.add_argument('--ocr', default='auto')
    ap.add_argument('--ocr-models')
    ap.add_argument('--no-walls', action='store_true')
    ap.add_argument('--no-frames', action='store_true')
    ap.add_argument('--no-verify', action='store_true', help='skip Rule 5 (drawing vs XML verification)')
    ap.add_argument('--ask-anchor', action='store_true', help='pop-up asking X of the first printed frame when no anchor / frame table is given (R-F3)')
    ap.add_argument('--anchor', help="start point of THIS drawing's frame numbering, 'FRAME:X_mm' (e.g. 79:63200)")
    ap.add_argument('--frame-table', help="CSV 'frame,x_mm' exported from the frame table / GA plan")
    ap.add_argument('--frame-spacing', type=float, help='uniform frame spacing in mm when the drawing does not print it')
    a = ap.parse_args(argv)
    try:                                    # R-B11: bracket marks from the drawing's DET. OF BRACKET table (same hull)
        from . import elevation as _el0
        _el0.load_bracket_marks(a.pdf)
    except Exception as _e:
        from . import openitems as _oi0
        _oi0.record('R-B11 bracket table', _e)
    if a.settings:          # R-YC: yard conventions + owner answers merged once; every later reader sees the merged settings
        from . import run as _run0
        _eff = _run0.load_settings(a.settings)
        _eff.pop('pipe_table', None)
        _bd = os.path.dirname(os.path.abspath(a.settings))
        for _k in ('frame_table_csv', 'pipe_table_csv'):
            if _eff.get(_k) and not os.path.isabs(_eff[_k]):
                _eff[_k] = os.path.join(_bd, _eff[_k])
        _eff.pop('yard', None); _eff.pop('owner_answers', None)
        os.makedirs(a.out, exist_ok=True)
        a.settings = os.path.join(a.out, 'settings_merged.json')
        json.dump(_eff, open(a.settings, 'w', encoding='utf-8'), indent=1, default=str)
    if a.ask_anchor and not (a.anchor or a.frame_table):
        base0 = json.load(open(a.settings, encoding='utf-8')) if a.settings else {}
        if not base0.get('frame_anchor') and not base0.get('frame_table_csv'):
            from . import askanchor
            fr, sp0 = askanchor.first_frame(a.pdf, _pages(a.pages, _page_count(a.pdf)))
            if fr is not None:
                xa = askanchor.ask(fr, sp0)
                if xa is not None:
                    a.anchor = f'{fr}:{xa:g}'
    if a.anchor or a.frame_table or a.frame_spacing:      # R-F1/R-F2: merge the owner's frame inputs into a temp settings file
        import tempfile
        base = json.load(open(a.settings, encoding='utf-8')) if a.settings else {}
        if a.settings and base.get('frame_table_csv') and not os.path.isabs(base['frame_table_csv']):
            base['frame_table_csv'] = os.path.join(os.path.dirname(os.path.abspath(a.settings)), base['frame_table_csv'])
        if a.anchor:
            fr, x = a.anchor.split(':')
            base['frame_anchor'] = {'frame': int(fr), 'x_mm': float(x)}
        if a.frame_table:
            base['frame_table_csv'] = os.path.abspath(a.frame_table)
        if a.frame_spacing:
            base['frame_spacing_mm'] = a.frame_spacing
        os.makedirs(a.out, exist_ok=True)
        tmp = os.path.join(a.out, 'settings_effective.json')
        json.dump(base, open(tmp, 'w'), indent=1)
        a.settings = tmp
    _base = json.load(open(a.settings, encoding='utf-8')) if a.settings else {}
    _fc2 = None
    _fsq = None
    if not (_base.get('frame_table') or _base.get('frame_table_csv')):
        # R-FS1: 'F.S. : n' zone labels of the frame rows give the bays; the owner's anchor gives the X of one frame
        from . import fszones
        try:
            if _base.get('frame_anchor'):
                _ft, _fz = fszones.table(a.pdf, _base['frame_anchor'])
                if _ft:
                    _base['frame_table'] = {str(k): v for k, v in _ft.items()}
                    _base['frame_table_source'] = f"R-FS1 F.S. zones {sorted(_fz.items())} anchored at the owner's FR.{_base['frame_anchor']['frame']} = {_base['frame_anchor']['x_mm']}"
                    os.makedirs(a.out, exist_ok=True)
                    a.settings = os.path.join(a.out, 'settings_effective.json')
                    json.dump(_base, open(a.settings, 'w'), indent=1)
                    print('R-FS1 frame table from F.S. zones:', sorted(_fz.items()))
            else:
                _fz = fszones.zones(a.pdf)
                if _fz:
                    _fsq = f"The drawing gives the frame spaces (F.S. zones {sorted(_fz.items())}) but not the X of any frame: X of one frame from the origin? (--anchor FRAME:X)"
        except Exception as _e:
            from . import openitems as _oi1
            _oi1.record('R-FS1 F.S. zones', _e)
    if not (_base.get('frame_table') or _base.get('frame_table_csv')):
        # R-FC2: 'FRAME SPACE : n (EXC. AS SHOWN)' - bays drawn differently in every frame row are taken as drawn
        from . import framedrawn, run_elev as _re0
        _sp = sorted(_re0._pdf_spacings(a.pdf, _page_count(a.pdf)))
        if len(_sp) == 1:
            _fc2 = framedrawn.table(a.pdf, float(_sp[0]))
            if _fc2['table']:
                _tab2 = dict(_fc2['table'])
                _anc2 = _base.get('frame_anchor')
                if _anc2 and int(_anc2['frame']) in _tab2:        # R-FC3: the owner's anchor shifts the drawn-bay table
                    _sh2 = float(_anc2['x_mm']) - _tab2[int(_anc2['frame'])]
                    _tab2 = {k: v + _sh2 for k, v in _tab2.items()}
                _base['frame_table'] = {str(k): v for k, v in _tab2.items()}
                _base['frame_table_source'] = f"R-FC2 drawn bays {_fc2['bays']} on FRAME SPACE {_sp[0]} (EXC. AS SHOWN)"
                _base['frame_spacing_mm'] = float(_sp[0])
                os.makedirs(a.out, exist_ok=True)
                a.settings = os.path.join(a.out, 'settings_effective.json')
                json.dump(_base, open(a.settings, 'w'), indent=1)
                print('R-FC2 frame bays as drawn:', _fc2['bays'])
    from . import run, run_elev, run_sec, validate_xml
    os.makedirs(a.out, exist_ok=True)
    n = _page_count(a.pdf)
    pages = _pages(a.pages, n)
    name = re.sub(r'[^A-Za-z0-9_-]+', '_', os.path.splitext(os.path.basename(a.pdf))[0])[:40]
    rep = {'drawing': os.path.basename(a.pdf), 'pages': len(pages), 'stages': {}, 'frame_chain_drawn': _fc2}
    if _fsq:
        rep.setdefault('questions_pre', []).append(_fsq)
    files = []
    dlog = []
    for pn in pages:                                   # --- deck / strake plans
        d = os.path.join(a.out, 'decks', f'p{pn}')
        buf = io.StringIO()
        args = [a.pdf, '--page', str(pn), '--deck', 'all', '--out', d, '--ocr', a.ocr]
        if a.settings:
            args += ['--settings', a.settings]
        if a.raster:
            args += ['--raster']
        if a.ocr_models:
            args += ['--ocr-models', a.ocr_models]
        try:
            with contextlib.redirect_stdout(buf):
                run.main(args)
        except SystemExit as e:
            buf.write(str(e) + '\n')
        except Exception as e:
            import traceback as _tb
            _fr=_tb.extract_tb(e.__traceback__)[-3:]
            buf.write(f'ERROR {e} @ ' + ' <- '.join(f'{os.path.basename(f.filename)}:{f.lineno} {f.name}' for f in reversed(_fr)) + '\n')
        for line in buf.getvalue().splitlines():
            if line.strip() and 'Warn' not in line:
                dlog.append((pn, line.strip()[:240]))
        files += sorted(glob.glob(os.path.join(d, '*_moulded.xml')))
    rep['stages']['decks'] = [{'page': p, 'line': l} for p, l in dlog]
    from . import connect                               # R-CN1: deck members known before the wall / frame builders run
    connect.load([f for f in files if os.path.exists(f)])
    try:                                                # R-XV4c: wall layouts "ARRG'T OF STEEL WALL ON <deck>"
        rep['wall_plans'] = connect_wallplans = __import__('deckrules.crossverify', fromlist=['x']).load_wallplans(
            a.pdf, json.load(open(a.settings, encoding='utf-8')) if a.settings else {})
    except Exception as _e:
        rep['wall_plans'] = [f'error {_e}']
    if not a.no_walls:                                  # --- longitudinal wall elevations
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                panels, r = run_elev.main([a.pdf, '--pages', a.pages, '--out', os.path.join(a.out, 'walls')] +
                                          (['--settings', a.settings] if a.settings else []))
            rep['stages']['walls'] = {k: v for k, v in r['views'].items()}
            rep['pipes'] = {'written': r.get('pipes_written', 0), 'pending': r.get('pipes_pending', [])}
            files.append(os.path.join(a.out, 'walls', 'WALLS_moulded.xml'))
        except Exception as e:
            rep['stages']['walls'] = {'error': str(e)}
    if not a.no_frames:                                 # --- transverse frame sections
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                panels, r = run_sec.main([a.pdf, '--pages', a.pages, '--out', os.path.join(a.out, 'frames')] +
                                         (['--settings', a.settings] if a.settings else []))
            rep['stages']['frames'] = {k: v for k, v in r['views'].items()}
            files.append(os.path.join(a.out, 'frames', 'FRAMES_moulded.xml'))
        except Exception as e:
            rep['stages']['frames'] = {'error': str(e)}
    from . import openitems as _oi
    rep['rule_errors'] = list(_oi.ERRORS)                          # P9
    rep['connect'] = {'deck_members': len(connect.TABLE['beams']), 'snapped': connect.TABLE['n_snapped'], 'log': connect.TABLE['log'][:200]}
    files = [f for f in files if os.path.exists(f)]
    out_xml = os.path.join(a.out, f'{name}_complete_moulded.xml')
    if __import__('deckrules.run', fromlist=['load_settings']).load_settings(a.settings).get('vfd_room_walls'):              # R-RW1: VFD-room box walls read from the NO.10 / 18665 OFF C.L elevations
        from . import roomwalls
        _vf = os.path.join(a.out, 'VFD_room_walls.xml')
        roomwalls.build(_vf, roomwalls.beam_positions(files))
        files.append(_vf)
    if __import__('deckrules.run', fromlist=['load_settings']).load_settings(a.settings).get('vfd_room_frames'):                # R-FV1: members of the VFD room on FR.47-4000 and FR.47
        from . import framevfd
        _ff = os.path.join(a.out, 'VFD_room_frames.xml')
        framevfd.build(_ff)
        files.append(_ff)
    nb, nbar = merge(files, out_xml) if files else (0, 0)
    if nb:
        from . import xmlclean
        rep['one_member_once'] = xmlclean.clean(out_xml)          # R-W8 / R-W9
    if nb and connect.TABLE['links']:
        rep['connect']['brackets_moved'] = connect.move_brackets(out_xml, 150.0)      # R-CN3: web height of the 150X90X12 wall stiffener
        rep["connect"]["flanges_flipped"] = connect.orient_flanges(out_xml)      # R-FL1
    if nb and __import__('deckrules.run', fromlist=['load_settings']).load_settings(a.settings).get('vfd_room_frames'):
        from . import framevfd
        rep['connect']['fr47_4000_stock_stiffeners_removed'] = framevfd.finalize(out_xml)      # R-FV2
    if nb:
        _fx, _lf = connect.clear_brackets(out_xml)                                  # R-G5: no bracket overlaps a member
        rep['connect']['brackets_slid'] = _fx; rep['connect']['brackets_not_cleared'] = _lf
        print(f'R-G5 clear: {len(_fx)} brackets slid, {len(_lf)} not cleared')
    rep['xml'] = {'file': out_xml, 'blocks': nb, 'bar_sections': nbar}
    if nb:
        try:
            from . import overlap          # R-G1: two members never overlap
            _np, _hits = overlap.check(out_xml)
            rep['overlap'] = {'parts': _np, 'pairs': len(_hits), 'surface_connections': len(getattr(overlap.check, 'connections', [])), 'worst': [list(map(str, h)) for h in _hits[:60]]}
            _nb, _bh = overlap.check_brackets(out_xml)          # R-G5: a bracket never overlaps a member
            rep['overlap']['brackets'] = {'brackets': _nb, 'pairs': len(_bh), 'hits': [[str(v) for v in h] for h in _bh[:60]]}
            print(f'R-G5 bracket check: {len(_bh)} bracket/member overlaps of {_nb} brackets (see BUILD_REPORT.json)')
            print(f'R-G1 overlap check: {len(_hits)} overlapping member pairs of {_np} parts (see BUILD_REPORT.json)')
            from . import gapaudit          # R-CN6: every member end touches the member it stops on
            _ga = gapaudit.audit(out_xml)
            open(os.path.join(os.path.dirname(out_xml), 'GAP_AUDIT.md'), 'w').write(gapaudit.report(_ga))
            rep['gap_audit'] = {'ends': len(_ga), 'gap': [r for r in _ga if r['state'] == 'GAP'], 'free': [f"{r['member']}:{r['end']}" for r in _ga if r['state'] == 'FREE']}
            print(f"R-CN6 gap audit: {len(_ga)} member ends, {len(rep['gap_audit']['gap'])} with a GAP, {len(rep['gap_audit']['free'])} free (GAP_AUDIT.md)")
        except Exception as _e:
            rep['overlap'] = {'error': str(_e)}
    if nb:
        rep['validation'] = validate_xml.check(out_xml)
        rep['questions'] = _owner_questions(out_xml)         # R-Q1: a value not written anywhere is asked, never guessed silently
        if rep.get('frame_chain_drawn'):
            rep['questions'] += rep['frame_chain_drawn'].get('questions', [])
        rep['questions'] = rep.pop('questions_pre', []) + rep['questions']
        for q_ in rep['questions']:
            print('QUESTION:', q_)
    if nb and not getattr(a, 'no_verify', False):
        try:                                             # RULE 5 - verified: every view vs the produced XML
            from . import verify5
            rep['rule5'] = verify5.run(a.pdf, a.out, out_xml, rep)
            print(f"RULE 5 verify: {rep['rule5']['views_checked']} views checked, mean coverage {rep['rule5']['mean_coverage']:.0%}, "
                  f"{rep['rule5']['not_read']} of {rep['rule5']['inventory']} titled views not read (RULE5_VERIFY.md)")
        except Exception as _e:
            import traceback; traceback.print_exc()
            rep['rule5'] = {'error': str(_e)}
    rep['cross_verify'] = _xv_summary(a.out, rep)                  # R-XV: deck <-> OFF C.L <-> frame sections
    for q_ in rep['cross_verify'].get('questions', []):
        print('QUESTION:', q_)
    if nb:
        try:                                              # R5.10: printed tokens vs rules that used them (detection, not logic)
            from . import detect
            rep['detection'] = detect.report(a.pdf, out_xml)
            for r_ in rep['detection']['rows']:
                print(f"R5.10 detection: {r_['rule']}: printed {r_['printed']}, used {r_['used_in_xml']}")
            for q_ in rep['detection']['questions']:
                print('QUESTION:', q_)
        except Exception as _e:
            rep['detection'] = {'error': str(_e)}
    json.dump(rep, open(os.path.join(a.out, 'BUILD_REPORT.json'), 'w'), indent=1, default=str)
    _markdown(rep, os.path.join(a.out, 'BUILD_REPORT.md'))
    print(f"built {nb} blocks / {nbar} bar sections -> {out_xml}")
    print('report:', os.path.join(a.out, 'BUILD_REPORT.md'))
    return rep


def _xv_summary(out, rep):
    """R-XV: per deck the cross-verification of its members with the OFF C.L elevations and frame sections (deck reports) and the walls
    of the elevations / sections that no deck plan carries."""
    res = {'decks': {}, 'questions': []}
    for f in sorted(glob.glob(os.path.join(out, 'decks', 'p*', '*_report.json'))):
        try:
            cv = json.load(open(f))['coordinate_sources']['members'].get('cross_verify')
        except Exception:
            continue
        if not cv:
            continue
        name = os.path.basename(f).replace('_DECK_report.json', '')
        res['decks'][name] = cv
        if cv.get('not_shown'):
            res['questions'].append(f"{name}: {len(cv['not_shown'])} deck members cross an OFF C.L elevation / frame section that does not show them - keep or remove? "
                                    f"(e.g. {cv['not_shown'][0]})")
        if cv.get('missing'):
            res['questions'].append(f"{name}: {len(cv['missing'])} members cut in an elevation / section have no deck member in the plan - add? (e.g. {cv['missing'][0]})")
        if cv.get('mirror_unverified'):
            res['questions'].append(f"{name}: {cv['mirror_unverified']} members mirrored by the symmetry note are crossed by no view (not verified) - confirm")
    for stage, fn in (('walls', 'WALLS_report.json'), ('frames', 'FRAMES_report.json')):
        try:
            r = json.load(open(os.path.join(out, stage, fn)))
        except Exception:
            continue
        res[stage + '_dropped'] = r.get('xv_walls_dropped', [])
        res[stage + '_mirrored'] = r.get('mirrored_panels', 0)
        if stage == 'walls':
            res['sim_side_stiffeners'] = r.get('sim_side_stiffeners_copied', 0)
    return res


def _owner_questions(xml_path):
    """R-Q1: defaults used because the drawing writes no value -> one question per deck (bracket size, unmarked member size)."""
    import re as _re
    import xml.etree.ElementTree as _ET
    out = []
    root = _ET.parse(xml_path).getroot()
    for blk in root.iter('Block'):
        unk = [b for b in blk.iter('Bracket') if 'size UNKNOWN' in (b.get('Source') or '')]
        if unk:
            sz = _re.search(r'default ([0-9.]+x[0-9.]+)', unk[0].get('Source') or '')
            out.append(f"{blk.get('ObjId')}: {len(unk)} brackets have no size written in the drawing (default {sz.group(1) if sz else '?'} used). "
                       f"Bracket leg x thickness in mm? (answer = settings bracket_leg_mm / bracket_thk_mm)")
        dflt = [st for st in blk.iter('Stiffener') if 'unmarked' in (st.get('Evidence') or '') and 'default' in (st.get('Evidence') or '')]
        if dflt:
            out.append(f"{blk.get('ObjId')}: {len(dflt)} unmarked longitudinal/oblique members took the deck default size - confirm it applies")
    return out


def _markdown(rep, path):
    L = [f"# Build report - {rep['drawing']}", '']
    x = rep.get('xml', {})
    L.append(f"XML: `{os.path.basename(x.get('file', ''))}` - {x.get('blocks', 0)} blocks, {x.get('bar_sections', 0)} bar sections")
    v = rep.get('validation')
    if v:
        L.append(f"Validation: hard issues = {v.get('hard') or 'none'}; member ends supported "
                 f"{v['ends']['touching_support']}/{v['ends']['total']}")
    L += ['', '## Deck / strake plans', '']
    for e in rep['stages']['decks']:
        L.append(f"- p{e['page']}: {e['line']}")
    for stage, title in (('walls', 'Wall elevations'), ('frames', 'Frame sections')):
        st = rep['stages'].get(stage)
        if st is None:
            continue
        L += ['', f'## {title}', '']
        if 'error' in st:
            L.append(f"- stage failed: {st['error']}")
            continue
        okc = sum(1 for s in st.values() if s.get('status') == 'ok')
        L.append(f'{okc} of {len(st)} views built.')
        for k, s in st.items():
            if s.get('status') != 'ok':
                L.append(f"- {k}: FAILED - {s.get('reason')}")
    xv = rep.get('cross_verify')
    if xv and xv.get('decks'):
        L += ['', '## Cross-verification deck <-> OFF C.L <-> frame sections (R-XV / R-SY2)', '',
              '| deck | views | confirmed | not shown in a view | cut but no deck member | mirrored (R-SY2) | mirror rejected (except as shown) | mirror unverified | duplicates removed |',
              '|---|---|---|---|---|---|---|---|---|']
        for d, cv in xv['decks'].items():
            L.append(f"| {d} | {len(cv['views'])} | {cv['confirmed']} | {len(cv['not_shown'])} | {len(cv['missing'])} | {cv['mirrored']} | {len(cv['mirror_rejected'])} | {cv['mirror_unverified']} | {cv['duplicates_removed']} |")
        nt = next(iter(xv['decks'].values())).get('symmetric_note')
        L += ['', f"Symmetry note: {nt or 'none found'}. Walls dropped (not on any deck plan wall line / edge, or edge-on): "
              f"{len(xv.get('walls_dropped', []))} elevation panels, {len(xv.get('frames_dropped', []))} section panels; mirrored: "
              f"{xv.get('walls_mirrored', 0)} wall panels, {xv.get('frames_mirrored', 0)} section panels; 'SIM. TO PORT SIDE' stiffeners/sizes taken: {xv.get('sim_side_stiffeners', 0)}.", '']
        for d, cv in xv['decks'].items():
            for k, t in (('not_shown', 'not shown in a view'), ('missing', 'cut in a view, no deck member'), ('mirror_rejected', 'mirror rejected')):
                for x_ in cv[k]:
                    L.append(f'- {d} {t}: {x_}')
        for x_ in xv.get('walls_dropped', []) + xv.get('frames_dropped', []):
            L.append(f'- wall dropped: {x_}')
    if rep.get('questions') or (xv and xv.get('questions')):
        L += ['', '## Questions for the owner (value not written in the drawing)', ''] + [f'- {q_}' for q_ in rep.get('questions', []) + (xv or {}).get('questions', [])]
    pp_ = rep.get('pipes')
    if pp_ and (pp_['written'] or pp_['pending']):
        L += ['', '## Pipes', '', f"{pp_['written']} pipes written from the pipe table; {len(pp_['pending'])} pending (no OD / thickness row in the pipe table):"]
        L += [f'- {x}' for x in pp_['pending']]
    from . import view as _vw
    qs = list(dict.fromkeys(_vw.ASK)) + list(dict.fromkeys(_vw.DETAILS))
    if qs:
        L += ['', '## Questions for the owner / skipped items (found by the rules)', ''] + [f'- {q}' for q in qs]
    from . import details as _dt
    if _dt.ALL:
        un = sorted({v['title'] for k, v in _dt.ALL.items() if v['title'] not in _dt.USED})
        L += ['', '## Section / detail views read (R-DT)', '',
              f'{len(_dt.ALL)} views indexed; used for geometry or sizes: {", ".join(sorted(_dt.USED)) or "none"}.', '',
              'NOT yet used (their content is not in the XML - to be taught): ' + ', '.join(un)]
    L += ['', '## Open decisions (not printed on the drawings)', '',
          '- web side of stiffeners (Inclination W sign) on frame sections; flange side of angles on plans',
          '- default for unmarked longitudinals (girder vs beam)',
          '- frame table / frame zero for ships whose frames are not at n x spacing',
          '- sections vs bulkheads: open web frames drawn like bulkhead sections']
    open(path, 'w', encoding='utf-8').write('\n'.join(L))


if __name__ == '__main__':
    main()
