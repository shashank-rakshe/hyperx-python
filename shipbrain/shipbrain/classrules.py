"""
Class society rules: calculators for the public IACS formulas + the societies' own rule documents as private knowledge.

1. Calculators (class_rule tool) - IACS requirements every member society applies; formulas written out here with
   their rule reference, every answer says which rule and asks to check the current revision:
     ur_s11   longitudinal strength (IACS UR S11 / UR S7): wave coefficient C, wave bending moments hogging / sagging,
              minimum hull girder section modulus and moment of inertia, permissible bending and shear stress, required
              section modulus for a given still-water moment, material factor k (UR S4). (Wave shear forces are not
              included: their distribution factors are taken from the rule text via knowledge_search.)
2. Rule documents (download + build): the official rule pages of IACS and the class societies (ships AND offshore)
   are crawled for their free PDF rule books; the PDFs are kept on YOUR PC / Kaggle only (copyright of each society),
   cut into sections with their formulas and turned into a PRIVATE knowledge pack (packs/class_rules_<society>.private.sbpack,
   git-ignored). knowledge_search answers from it with society, document, section and page; the Kaggle run trains
   a PRIVATE model on it (never uploaded to GitHub).
   Some societies need a free login (ClassNK, LR, KR): download those by hand into the folder, they are used the same way.

The paid rule-check programs (BV Mars, DNV Nauticus Hull, ABS Eagle, ClassNK PrimeShip-Hull, LR RulesCalc,
KR SeaTrust-HullScan, CCS Compass) are licensed software of each society and cannot be copied; ShipBrain answers from
the rules themselves and its own calculators.

    python -m shipbrain.classrules download --out D:/class_rules [--society DNV ABS ...]
    python -m shipbrain.classrules build --pdfs D:/class_rules --out packs
"""
import argparse, hashlib, html, io, json, math, os, re, sys, time, urllib.parse, urllib.request

# ====================================================================== 1. IACS calculators
K_MATERIAL = {235: 1.0, 315: 0.78, 355: 0.72, 390: 0.68, 460: 0.62}     # IACS UR S4: higher strength steel factor


def k_factor(yield_mpa=235):
    if yield_mpa in K_MATERIAL:
        return K_MATERIAL[yield_mpa]
    ks = sorted(K_MATERIAL)
    for a, b in zip(ks, ks[1:]):
        if a <= yield_mpa <= b:
            return K_MATERIAL[a] + (K_MATERIAL[b] - K_MATERIAL[a]) * (yield_mpa - a) / (b - a)
    return 235.0 / yield_mpa


def wave_coefficient(L):
    """IACS UR S11: C for 90 m <= L <= 500 m"""
    if L < 90:
        raise ValueError('UR S11 applies from L = 90 m; smaller ships follow the society\'s own rules')
    if L <= 300:
        return 10.75 - ((300 - L) / 100) ** 1.5
    if L <= 350:
        return 10.75
    if L <= 500:
        return 10.75 - ((L - 350) / 150) ** 1.5
    raise ValueError('UR S11 applies up to L = 500 m')


def _m_dist(x):
    """bending moment distribution factor M along the length (x / L): 0 at AP, 1.0 from 0.4 to 0.65 L, 0 at FP"""
    if x <= 0 or x >= 1:
        return 0.0
    if x < 0.4:
        return x / 0.4
    if x <= 0.65:
        return 1.0
    return (1 - x) / 0.35


def ur_s11(L, B, Cb, Ms_hog=None, Ms_sag=None, yield_mpa=235, x=0.5, Z_deck=None, Z_bottom=None, I=None):
    """IACS UR S11 / S7 at position x (fraction of L from AP). L, B in m; moments kN m; Z cm3; I cm4"""
    Cb = max(Cb, 0.6)
    C, k, M = wave_coefficient(L), k_factor(yield_mpa), _m_dist(x)
    Mw_hog = 190 * M * C * L ** 2 * B * Cb * 1e-3
    Mw_sag = -110 * M * C * L ** 2 * B * (Cb + 0.7) * 1e-3
    Zmin = C * L ** 2 * B * (Cb + 0.7) * k                        # UR S7, cm3 (midship 0.4 L)
    Imin = 3 * C * L ** 3 * B * (Cb + 0.7)                       # UR S11, cm4
    sigma = 175 / k                                              # permissible total bending stress, N/mm2
    out = {'rule': 'IACS UR S11 (longitudinal strength) + UR S7 (minimum section modulus) + UR S4 (k)', 'L_m': L, 'B_m': B, 'Cb': Cb,
           'x_over_L': x, 'C': round(C, 4), 'k': round(k, 3), 'M': round(M, 3), 'Mw_hog_kNm': round(Mw_hog), 'Mw_sag_kNm': round(Mw_sag),
           'Z_min_cm3': round(Zmin), 'I_min_cm4': round(Imin), 'sigma_perm_MPa': round(sigma, 1),
           'tau_perm_MPa': round(110 / k, 1)}
    req = [Zmin]
    if Ms_hog is not None or Ms_sag is not None:
        Mt = max(abs(Ms_hog or 0) + abs(Mw_hog), abs(Ms_sag or 0) + abs(Mw_sag))
        out['M_total_kNm'] = round(Mt)
        out['Z_req_stress_cm3'] = round(Mt / sigma * 1e3)
        req.append(Mt / sigma * 1e3)
    out['Z_required_cm3'] = round(max(req))
    checks = []
    for nm, z in (('deck', Z_deck), ('bottom', Z_bottom)):
        if z:
            u = max(req) / z
            checks.append(f'{nm} section modulus {z:,.0f} cm3 vs required {max(req):,.0f} cm3: {"PASS" if u <= 1 else "FAIL"} (utilisation {u:.2f})')
    if I:
        checks.append(f'moment of inertia {I:,.0f} cm4 vs minimum {Imin:,.0f} cm4: {"PASS" if I >= Imin else "FAIL"}')
    out['checks'] = checks
    out['plain_english'] = (
        f'By IACS UR S11, a ship {L:g} m long and {B:g} m wide with block coefficient {Cb:g} has wave coefficient C = {C:.3f}. '
        f'At {x:g} L the wave bending moment is {Mw_hog:,.0f} kN m hogging and {Mw_sag:,.0f} kN m sagging. The hull girder must have a section modulus of at least {Zmin:,.0f} cm3 (UR S7, '
        f'k = {k:.2f} for {yield_mpa:g} MPa steel) and a moment of inertia of at least {Imin:,.0f} cm4; the total bending '
        f'stress may not exceed {sigma:.0f} N/mm2 and the shear stress {110 / k:.0f} N/mm2.'
        + (f' With the still-water moment the total is {out["M_total_kNm"]:,} kN m, which needs {out["Z_req_stress_cm3"]:,} cm3; '
           f'the required section modulus is therefore {out["Z_required_cm3"]:,} cm3.' if 'M_total_kNm' in out else '')
        + (' ' + '; '.join(checks) + '.' if checks else '')
        + ' (Formulas of IACS UR S11 / S7 / S4 as written in ShipBrain; check the current revision and your society\'s rules, '
          'which may add to them.)')
    return out


# ====================================================================== 2. rule documents
SOURCES = [   # society, index pages of the free rule books (ships and offshore), keywords for the PDFs worth taking
    ('IACS', ['https://iacs.org.uk/resolutions/common-structural-rules', 'https://iacs.org.uk/resolutions/unified-requirements',
              'https://iacs.org.uk/resolutions/unified-interpretations', 'https://iacs.org.uk/resolutions/recommendations'], ''),
    ('DNV', ['https://www.dnv.com/rules-standards/', 'https://rules.dnv.com/servicedocuments/dnv'], 'RU-SHIP|RU-OU|OS-|ST-|CG-|RP-'),
    ('ABS', ['https://ww2.eagle.org/en/rules-and-resources/rules-and-guides.html'], 'rule|guide|steel|offshore|mobile'),
    ('BV', ['https://marine-offshore.bureauveritas.com/rules-guidelines'], 'NR|NI|rule'),
    ('LR', ['https://www.lr.org/en/knowledge/lloyds-register-rules/'], 'rule|ships|offshore'),
    ('ClassNK', ['https://www.classnk.or.jp/hp/en/rules/index.html'], 'rule|guidance'),
    ('KR', ['https://www.krs.co.kr/eng/Exclusive/Rule_Guide_List.aspx'], 'rule|guidance'),
    ('CCS', ['https://www.ccs.org.cn/ccswzen/'], 'rule|guide'),
    ('RINA', ['https://www.rina.org/en/marine/rules'], 'rule|part'),
    ('IRS', ['https://www.irclass.org/technical-information/rules-and-regulations/'], 'rule|part'),
    ('PRS', ['https://www.prs.pl/en/publications/rules'], 'rule|part'),
    ('CRS', ['https://www.crs.hr/en-us/Rules'], 'rule|part'),
    ('TL', ['https://www.turkloydu.org/en-US/rules'], 'rule|chapter'),
]
UA = {'User-Agent': 'Mozilla/5.0 (rules download for personal engineering reference)'}


def _get(url, timeout=60):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read(), r.headers.get('Content-Type', ''), r.geturl()


def download(out_dir, societies=None, max_files=400, depth=2, log=print):
    """crawl the societies' rule pages for PDF rule books -> out_dir/<society>/*.pdf (already present files are kept)"""
    got = {}
    for soc, starts, kw in SOURCES:
        if societies and soc.lower() not in [s.lower() for s in societies]:
            continue
        dst = os.path.join(out_dir, soc)
        os.makedirs(dst, exist_ok=True)
        seen, queue, n = set(), [(u, 0) for u in starts], 0
        host = {urllib.parse.urlparse(u).netloc.split(':')[0].removeprefix('www.') for u in starts}
        while queue and n < max_files:
            url, d = queue.pop(0)
            if url in seen:
                continue
            seen.add(url)
            try:
                body, ctype, final = _get(url)
            except Exception as e:
                log and log(f'  {soc}: {url} - {type(e).__name__} {getattr(e, "code", "")}'.rstrip())
                continue
            if 'pdf' in ctype or final.lower().endswith('.pdf'):
                name = re.sub(r'[^\w.\-]+', '_', urllib.parse.unquote(os.path.basename(urllib.parse.urlparse(final).path)) or 'rule.pdf')
                if not name.lower().endswith('.pdf'):
                    name += '.pdf'
                p = os.path.join(dst, name)
                if not os.path.exists(p):
                    open(p, 'wb').write(body)
                n += 1
                continue
            if d >= depth:
                continue
            for href in re.findall(r'href=["\']([^"\'#]+)', body.decode('utf-8', 'ignore')):
                u = urllib.parse.urljoin(final, html.unescape(href))
                h = urllib.parse.urlparse(u).netloc.split(':')[0].removeprefix('www.')
                if not any(h.endswith(x) or x.endswith(h) for x in host):
                    continue
                low = u.lower()
                if low.endswith('.pdf') and (not kw or re.search(kw, u, re.I)):
                    queue.insert(0, (u, d + 1))
                elif not re.search(r'\.(jpg|png|gif|zip|docx?|xlsx?|mp4)$', low) and re.search(r'rule|standard|resolution|guide|class|requirement|offshore|ship|publication', low):
                    queue.append((u, d + 1))
        got[soc] = n
        log and log(f'{soc}: {n} PDF(s) in {dst}' + ('' if n else ' - none downloaded: the site refuses automatic downloads (HTTP 403) or has moved; download the books by hand and attach them as a private Kaggle dataset with "rules" in its name'))
    return got


_SEC = re.compile(r'^\s*((?:Sec(?:tion)?\.?\s*)?\d{1,2}(?:\.\d{1,3}){0,4})\s+([A-Z][^\n]{2,90})$', re.M)
_FORMULA = re.compile(r'[A-Za-z_][\w,]*\s*=\s*[^=\n]{3,}')


def _doc_name(path):
    return os.path.splitext(os.path.basename(path))[0].replace('_', ' ')


def sections(pdf_path, size=1600):
    """rule book -> [{'id', 'section', 'title', 'page', 'text', 'formulas'}]: cut at numbered headings, formulas kept whole"""
    from .knowledge import _read
    text = _read(pdf_path) or ''
    out, page = [], 1
    parts = re.split(r'(?m)^# page (\d+)\n', text)
    flat = []                                             # (page, line)
    for i in range(1, len(parts), 2):
        for ln in parts[i + 1].splitlines():
            flat.append((int(parts[i]), re.sub(r'^\s*#{1,6}\s+', '', ln)))      # markdown heading marks (LiteParse)
    cur = {'section': '', 'title': '', 'page': 1, 'lines': []}

    def close():
        body = '\n'.join(cur['lines']).strip()
        while body:
            piece, body = body[:size], body[size:]
            if len(body) < 200:
                piece, body = piece + body, ''
            if len(piece.strip()) > 80:
                out.append({'section': cur['section'], 'title': cur['title'], 'page': cur['page'], 'text': piece,
                            'formulas': [f.strip() for f in _FORMULA.findall(piece)][:12]})
    for pg, ln in flat:
        m = _SEC.match(ln)
        if m and len(cur['lines']) > 3:
            close()
            cur = {'section': m.group(1).replace('Section', '').replace('Sec.', '').strip(), 'title': m.group(2).strip(), 'page': pg, 'lines': [ln]}
        else:
            cur['lines'].append(ln)
    close()
    return out


def build(pdf_dir, out_dir='packs', log=print):
    """PDF rule books (one folder per society) -> one PRIVATE pack per society (git-ignored, never published)"""
    from .repopack import FORMAT
    import gzip
    made = []
    socs = sorted(d for d in os.listdir(pdf_dir) if os.path.isdir(os.path.join(pdf_dir, d))) or ['rules']
    for soc in socs:
        folder = os.path.join(pdf_dir, soc) if soc != 'rules' else pdf_dir
        chunks = []
        for f in sorted(os.listdir(folder)):
            if not f.lower().endswith('.pdf'):
                continue
            try:
                secs = sections(os.path.join(folder, f))
            except Exception as e:
                log and log(f'  {soc}/{f}: not readable ({type(e).__name__})')
                continue
            doc = _doc_name(f)
            for i, s in enumerate(secs):
                title = f"{soc} {doc}" + (f" {s['section']}" if s['section'] else '') + (f" {s['title']}" if s['title'] else '') + f" (p. {s['page']})"
                cid = f"{soc}:{hashlib.md5((doc + str(i)).encode()).hexdigest()[:10]}"
                chunks.append({'id': cid, 'source': f'class:{soc}/{f}#p{s["page"]}', 'title': title, 'text': s['text'],
                               'kind': 'doc', 'society': soc, 'document': doc, 'section': s['section'], 'page': s['page'],
                               'formulas': s['formulas']})
        if not chunks:
            continue
        pack = {'format': FORMAT, 'name': f'class_rules_{soc}', 'repo': f'{soc} rule books (downloaded by the user)', 'commit': '',
                'license': f'{soc} rules - copyright {soc}; personal reference copy', 'license_reason': 'class society rules: used '
                'privately (knowledge + training of a PRIVATE model), never published', 'allowed_for_training': True,
                'private_only': True, 'own': True, 'usage': 'PRIVATE: class rules for your own use; never publish the pack or a model trained on it',
                'attribution': [f'Rules of {soc}'], 'built': time.strftime('%Y-%m-%d'),
                'stats': {'documents': len({c['document'] for c in chunks}), 'chunks': len(chunks),
                          'formulas': sum(len(c['formulas']) for c in chunks)}, 'chunks': chunks}
        os.makedirs(out_dir, exist_ok=True)
        fn = os.path.join(out_dir, f'class_rules_{soc}.private.sbpack')
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9, mtime=0) as g:
            g.write(json.dumps(pack, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
        open(fn, 'wb').write(buf.getvalue())
        log and log(f"{soc}: {pack['stats']['documents']} documents -> {len(chunks)} sections, {pack['stats']['formulas']} formulas -> {fn}")
        made.append(fn)
    return made


def main(argv=None):
    ap = argparse.ArgumentParser(prog='python -m shipbrain.classrules', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('download')
    d.add_argument('--out', required=True)
    d.add_argument('--society', nargs='*')
    d.add_argument('--max-files', type=int, default=400)
    b = sub.add_parser('build')
    b.add_argument('--pdfs', required=True)
    b.add_argument('--out', default='packs')
    c = sub.add_parser('s11')
    for k in ('L', 'B', 'Cb'):
        c.add_argument(k, type=float)
    a = ap.parse_args(argv)
    if a.cmd == 'download':
        print(download(a.out, a.society, a.max_files))
    elif a.cmd == 'build':
        print(build(a.pdfs, a.out))
    else:
        print(ur_s11(a.L, a.B, a.Cb)['plain_english'])


if __name__ == '__main__':
    main()
