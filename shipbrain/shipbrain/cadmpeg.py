"""
cadmpeg (https://github.com/cadmpeg/cadmpeg, Apache-2.0 code / CC-BY-4.0 docs): open native CAD files without the CAD
program - inspect, check, measure, compare and convert them to STEP / IGES. Used as written: its own command-line
program, installed once (official installer or `cargo install`, pinned to the commit below).

Formats it reads (its own support level, see its docs/format-support.md; higher = more of the file is understood):
  STEP L8, IGES L9 (also writes), FreeCAD .FCStd L5, Fusion 360 .f3d L5, SolidWorks .sldprt L3, CATIA V5 .CATPart L3,
  Inventor .ipt/.iam L3, ACIS .sat/.sab L3, Creo View .pvz L3, Rhino .3dm L2, OpenUSD L2, NX .prt L1, Creo .prt L1
  (L1 = opened and listed, no geometry yet; L3 = full B-rep solid; L5 = every surface kind and colours). In practice NX
  parts give their solid (an NX 1980 part matched NIST's STEP); NX assemblies give placements only (parts are separate files).
  Rhino .3dm goes to ShipBrain's own exact reader (rhino.py) first.
It never breaks protection: encrypted / licence-locked files are refused (its LEGAL.md).

ShipBrain uses it so that every CAD tool accepts native files: to_step(file) gives a STEP that cadplates / cad_mesh /
compare tools read, and the answer says what was lost (its decode report).
"""
import glob, json, os, re, shutil, subprocess

REPO = 'https://github.com/cadmpeg/cadmpeg'
COMMIT = '6c775550eba5647f4819826a0312feb356adab76'      # version 0.6.11, checked with ShipBrain
HOME_BIN = os.path.join(os.path.expanduser('~'), '.shipbrain', 'bin')
NATIVE = {'.sldprt': 'SolidWorks part', '.catpart': 'CATIA V5 part', '.ipt': 'Inventor part', '.iam': 'Inventor assembly',
          '.f3d': 'Fusion 360 design', '.3dm': 'Rhino model', '.prt': 'NX (or Creo) part', '.fcstd': 'FreeCAD document',
          '.sat': 'ACIS solid', '.sab': 'ACIS solid (binary)', '.smt': 'ShapeManager solid', '.smb': 'ShapeManager solid',
          '.pvz': 'Creo View file', '.usd': 'OpenUSD layer', '.usda': 'OpenUSD layer', '.usdc': 'OpenUSD layer',
          '.igs': 'IGES file', '.iges': 'IGES file', '.step': 'STEP file', '.stp': 'STEP file'}


def exe():
    """the cadmpeg program: SHIPBRAIN_CADMPEG, PATH, ~/.shipbrain/bin, cargo's bin folder"""
    for c in [os.environ.get('SHIPBRAIN_CADMPEG'), shutil.which('cadmpeg'), shutil.which('cadmpeg.exe'),
              os.path.join(HOME_BIN, 'cadmpeg'), os.path.join(HOME_BIN, 'cadmpeg.exe'),
              os.path.expanduser('~/.cargo/bin/cadmpeg'), os.path.expanduser('~/.cargo/bin/cadmpeg.exe')] + \
             sorted(glob.glob(os.path.expanduser('~/.shipbrain/cadmpeg/bin/cadmpeg*'))):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def build(jobs=2):
    """install from source with Rust (cargo), pinned to COMMIT, into ~/.shipbrain/cadmpeg (about 10-20 minutes once)"""
    cargo = shutil.which('cargo') or os.path.expanduser('~/.cargo/bin/cargo')
    if not os.path.exists(cargo):
        raise RuntimeError('cadmpeg is not installed. Install it (free): see https://github.com/cadmpeg/cadmpeg#install '
                           '(one-line installer for Windows / macOS / Linux), or install Rust (https://rustup.rs) and ShipBrain '
                           'builds it.')
    env = dict(os.environ, CARGO_PROFILE_RELEASE_LTO='false')     # thin LTO needs > 16 GB RAM on small PCs
    subprocess.run([cargo, 'install', '--git', REPO, '--rev', COMMIT, '--locked', '-j', str(jobs), '--root',
                    os.path.join(os.path.expanduser('~'), '.shipbrain', 'cadmpeg'), 'cadmpeg'], check=True, env=env)
    return exe()


def _need():
    x = exe()
    if not x:
        raise RuntimeError('cadmpeg is not installed. Install it (free): see https://github.com/cadmpeg/cadmpeg#install '
                           '(one-line installer for Windows / macOS / Linux), or install Rust (https://rustup.rs) and ShipBrain '
                           'builds it.')
    return x


def _run(args, timeout=900):
    p = subprocess.run([_need()] + args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def is_native(path):
    return os.path.splitext(path)[1].lower() in NATIVE and os.path.splitext(path)[1].lower() not in ('.step', '.stp')


LEVELS = {'L0': 'only recognised', 'L1': 'opened and listed, no geometry yet', 'L2': 'geometry (surfaces / curves) but not a full solid',
          'L3': 'full solid (B-rep)', 'L4': 'solid plus feature records', 'L5': 'complete shape with colours',
          'L6': 'complete design (sketches, parameters)', 'L7': 'product structure', 'L8': 'full document incl. PMI',
          'L9': 'reads and writes back'}


def inspect(path):
    code, out, err = _run(['inspect', path])
    text = out or err
    name = os.path.basename(path)
    kind = NATIVE.get(os.path.splitext(path)[1].lower(), 'CAD file')
    fmt = re.search(r'^format: (\S+)', text, re.M)
    cont = re.search(r'^container: (\S+)', text, re.M)
    ent = re.search(r'^entries: (\d+)', text, re.M)
    dia = re.search(r'^dialect: (\S+)(?: — read (L\d))?', text, re.M)
    pe = f"{name} is a {kind}" + (f" (format {fmt.group(1)}" + (f", version / dialect {dia.group(1).split(':', 1)[-1]}" if dia else '') + ')'
                                   if fmt else '') + '.'
    if cont:
        pe += f" Container: {cont.group(1)}" + (f" with {ent.group(1)} entries" if ent else '') + '.'
    if dia and dia.group(2):
        pe += f" cadmpeg reads this version at level {dia.group(2)}: {LEVELS.get(dia.group(2), '')}."
    if code != 0:
        pe = f"cadmpeg could not open {name}: " + text.strip()[-400:]
    return {'ok': code == 0, 'text': text[-6000:], 'plain_english': pe}


def check(path):
    code, out, err = _run(['check', path, '--json'])
    try:
        rep = json.loads(out)
    except ValueError:
        rep = {'text': (out + err)[-4000:]}
    rep['ok'] = code == 0
    return rep


def _val(q):
    return q.get('value') if isinstance(q, dict) and q.get('status') == 'measured' else None


def measure(path, density=None, faces=None):
    """bodies with volume, area, centroid (and mass / inertia when density kg/m3 is given), in plain words"""
    args = ['measure', path, '--json']
    if density:
        args += ['--density', str(density)]
    if faces:
        args += ['--faces', '--kind', faces]
    code, out, err = _run(args)
    try:
        m = json.loads(out)
    except ValueError:
        return {'error': (err or out)[-3000:]}
    rows = []
    for b in (m.get('measure') or {}).get('bodies', []):
        r = {'body': b.get('name') or b.get('body'), 'kind': b.get('kind'), 'faces': b.get('faces'),
             'surfaces': b.get('surface_kinds'), 'volume_mm3': _val(b.get('volume')), 'area_mm2': _val(b.get('area')),
             'centroid_mm': _val(b.get('centroid')), 'mass_kg': _val(b.get('mass'))}
        bb = b.get('bbox') or {}
        if bb.get('status') == 'measured':
            r['size_mm'] = [round(bb['max'][k] - bb['min'][k], 3) for k in 'xyz']
        rows.append({k: v for k, v in r.items() if v not in (None, {}, [])})
    solids = [r for r in rows if r.get('kind') == 'solid']
    pe = f"{os.path.basename(path)}: {len(rows)} bodies ({len(solids)} solids)."
    if solids:
        V = sum(r.get('volume_mm3') or 0 for r in solids)
        pe += f" Total solid volume {V:,.1f} mm3"
        M = [r['mass_kg'] for r in solids if r.get('mass_kg') is not None]
        pe += (f", mass {sum(M):,.3f} kg at {density:g} kg/m3." if M and density else '.')
        big = max(solids, key=lambda r: r.get('volume_mm3') or 0)
        if big.get('size_mm'):
            pe += f" Largest solid: {' x '.join(f'{v:g}' for v in big['size_mm'])} mm, volume {big.get('volume_mm3') or 0:,.1f} mm3."
    return {'bodies': rows[:50], 'status': m.get('status'), 'plain_english': pe + ' (Measured by cadmpeg with its error terms.)'}


def to_step(path, out=None, allow_errors=False):
    """native CAD -> STEP; returns {file, report (what was decoded / lost), plain_english}"""
    out = out or os.path.splitext(path)[0] + '.step'
    args = ['convert', path, '-o', out, '--force']
    if allow_errors:
        args.append('--allow-errors')
    code, so, se = _run(args)
    text = (so + '\n' + se).strip()
    if code != 0 or not os.path.exists(out):
        reason = [l for l in text.splitlines() if l.strip().startswith(('[blocking/', 'error'))]
        raise RuntimeError(f'cadmpeg could not convert {os.path.basename(path)}: ' + ('; '.join(reason[:3]) or text[-1500:]))
    depth = re.search(r'depth=(\w+)', text)
    geo = re.search(r'geometry_transferred=(\w+)', text)
    chk = re.search(r'check: (\w+) \((\d+) error\(s\), (\d+) warning\(s\)\)', text)
    kind = NATIVE.get(os.path.splitext(path)[1].lower(), 'CAD file')
    pe = f"Read the {kind} {os.path.basename(path)} with cadmpeg (free, no CAD licence) and wrote {os.path.basename(out)}."
    block = [re.sub(r'^\s*\[blocking/\w+\]\s*', '', l) for l in text.splitlines() if l.strip().startswith('[blocking/')]
    places = re.search(r'native\.nx\.assembly_placements: (\d+)', text)
    if geo and geo.group(1) != 'true' and re.search(r'assembly \.prt', text):
        pe += (f" This is an NX ASSEMBLY: it only places {places.group(1) if places else 'its'} components; their geometry is in "
               "separate part .prt files. Upload those part files and I convert each one (or export the assembly to STEP in NX).")
    elif geo and geo.group(1) != 'true':
        pe += (' Its geometry could NOT be transferred (this format is only partly understood yet): the STEP is empty or partial.'
               + (' Reason: ' + '; '.join(block[:2]) if block else ''))
    if chk:
        pe += f" Check: {chk.group(1)} ({chk.group(2)} errors, {chk.group(3)} warnings)."
    bodies = re.search(r'^\s+bodies: (\d+)', text, re.M)
    faces = re.search(r'^\s+faces: (\d+)', text, re.M)
    if bodies:
        pe += f" The model has {bodies.group(1)} bod{'y' if bodies.group(1) == '1' else 'ies'}" + (f" and {faces.group(1)} faces." if faces else '.')
    warn = [re.sub(r"\s*:\s*'.*$", '', l.split(']', 1)[1]).strip() for l in text.splitlines() if l.strip().startswith('[warning/geometry')]
    warn = [w if len(w) < 140 else w[:137] + '...' for w in warn]
    info = [l.split(']', 1)[0].split('/')[-1] for l in text.splitlines() if l.strip().startswith('[info/')]
    if warn:
        pe += ' Warnings: ' + '; '.join(warn[:4]) + '.'
    if info:
        kinds = sorted(set(info))
        pe += (' As usual for STEP, the native-only data was not carried over (' + ', '.join(k.replace('_', ' ') for k in kinds)
               + ': e.g. feature history, appearance details, attributes).')
    return {'file': out, 'depth': depth.group(1) if depth else None, 'geometry_transferred': geo.group(1) == 'true' if geo else None,
            'report': text[-3000:], 'plain_english': pe}


def diff(a, b, geometry=True):
    """compare the decoded geometry and topology of two files (native or STEP)"""
    args = ['diff', a, b] + (['--geometry'] if geometry else [])
    code, out, err = _run(args)
    text = out or err
    agree = len(re.findall(r'\bagree\b', text))
    differ = [l.strip() for l in text.splitlines() if re.search(r'\b(differ|disagree|only in|missing)\b', l)]
    pairs = len(re.findall(r'^\s*pair ', text, re.M))
    pe = (f"Compared {os.path.basename(a)} with {os.path.basename(b)}: {pairs} matching bod{'y' if pairs == 1 else 'ies'}, "
          f"{agree} measured values agree" + (f", {len(differ)} differ (" + '; '.join(differ[:5]) + ')' if differ else '')
          + ('. They are the same.' if code == 0 else '. They differ.'))
    return {'same': code == 0, 'agree': agree, 'differences': differ[:40], 'text': text[-4000:], 'plain_english': pe}
