"""
AISC 360 connection design checks with Osoconn (https://github.com/roshnnoronha/osoconn, MIT, roshnnoronha; command-line app copied
as written in vendor/osoconn/cla, compiled on first use: cmake + make, about 40 s, C++17):

  shear_clip_angle   SC001  double clip angle shear connection (beam to girder web / column)
  moment_end_plate   MC001  extended end plate moment connection (4 / 8 bolts, optional column stiffener / doubler plate)
  vertical_brace     VB001  vertical brace gusset connection
  horizontal_brace   HB001  horizontal brace gusset connection

Inputs are Osoconn's own keywords (see the example .cin files in vendor/osoconn/cla/examples), in the unit system you choose:
NEWTON_MM (N, mm, MPa, bolts M22 ...) or KIP_IN (kip, in, ksi, bolts 3/4 ...). Sections are AISC names from its database
(W310X74 metric, W14X30 inch; angles L102X76X9.5, L4X3-1/2X1/2). Result: every check's interaction ratio and the governing one.
LRFD or ASD. These are the AISC 360 limit states built into Osoconn: not a replacement for the engineer's own checks.
"""
import glob, os, re, shutil, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CLA = os.path.join(HERE, 'vendor', 'osoconn', 'cla')
CACHE = os.path.join(os.environ.get('SHIPBRAIN_CACHE') or os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain'), 'osoconn_build')

CODES = {'shear_clip_angle': ('SC001AM10', 'SC001'), 'moment_end_plate': ('MC001AM10', 'MC001'),
         'vertical_brace': ('VB001AM10', 'VB001'), 'horizontal_brace': ('HB001AM10', 'HB001')}
ALIASES = {'clip angle': 'shear_clip_angle', 'shear': 'shear_clip_angle', 'moment': 'moment_end_plate', 'end plate': 'moment_end_plate',
           'extended': 'moment_end_plate', 'vertical': 'vertical_brace', 'horizontal': 'horizontal_brace', 'brace': 'vertical_brace'}


def kind_of(s):
    k = str(s).lower().strip().replace('-', '_').replace(' ', '_')
    if k in CODES:
        return k
    k = k.replace('_', ' ')
    for a, v in ALIASES.items():
        if a in k:
            return v
    raise ValueError(f'unknown check {s!r}: shear_clip_angle, moment_end_plate, vertical_brace or horizontal_brace')


def binary():
    """compile Osoconn once (cmake + make), return the executable"""
    exe = os.path.join(CACHE, 'osoconn')
    if os.path.exists(exe):
        return exe
    for tool in ('cmake', 'make', 'g++'):
        if not shutil.which(tool):
            raise RuntimeError(f'Osoconn needs {tool} to compile once (free: sudo apt install cmake make g++). Source: vendor/osoconn/cla')
    os.makedirs(CACHE, exist_ok=True)
    r = subprocess.run(['cmake', CLA, '-DCMAKE_BUILD_TYPE=Release'], cwd=CACHE, capture_output=True, text=True)
    if r.returncode == 0:
        r = subprocess.run(['make', '-j2'], cwd=CACHE, capture_output=True, text=True)
    if r.returncode or not os.path.exists(exe):
        raise RuntimeError('compiling Osoconn failed: ' + (r.stderr or r.stdout)[-400:])
    return exe


def template(kind):
    """[(section, [keys])] of the example input of this check: the keywords it understands"""
    code, folder = CODES[kind_of(kind)]
    f = sorted(glob.glob(os.path.join(CLA, 'examples', folder, code, '*.cin')))[0]
    secs, cur = [], None
    for line in open(f):
        line = line.rstrip()
        if line.startswith('*'):
            cur = (line, [])
            secs.append(cur)
        elif cur is not None and line.strip():
            cur[1].append(line.split()[0])
    return secs


def keys(kind):
    return [k for _, ks in template(kind) for k in ks]


def write_input(kind, params, path, method='LRFD', units='NEWTON_MM', cid='shipbrain'):
    kind = kind_of(kind)
    code = CODES[kind][0]
    valid = keys(kind)
    P = {str(k).upper().strip(): v for k, v in params.items()}
    bad = [k for k in P if k not in valid]
    if bad:
        raise ValueError(f'unknown input {bad}; the {kind} check understands: ' + ', '.join(valid))
    u = str(units).upper().replace('-', '_').replace(' ', '_')
    u = {'N_MM': 'NEWTON_MM', 'NEWTON_MM': 'NEWTON_MM', 'KIP_IN': 'KIP_IN', 'KIP_INCH': 'KIP_IN'}.get(u, u)
    L = [f'CONNECTION_CODE {code}', f'CONNECTION_ID {cid}', f'METHOD {str(method).upper()}', f'UNITS {u}', '']
    for sec, ks in template(kind):
        have = [k for k in ks if k in P]
        if have:
            L.append(sec)
            L += [f'{k} {str(P[k]).replace(" ", "_") if isinstance(P[k], str) and k.endswith("DIAMETER") else P[k]}' for k in have]
            L.append('')
    open(path, 'w').write('\n'.join(L) + '\n')
    return path


_NUM = re.compile(r'^-?\d+(\.\d+)?$')


def parse_output(text):
    lines = text.splitlines()
    out = {'ok': None, 'max_ratio': None, 'governing_note': None, 'checks': []}
    for i, ln in enumerate(lines):
        lab, _, val = ln.partition('|')
        lab, val = lab.strip(), val.strip()
        if lab.startswith('Connection is'):
            out['ok'] = 'NOT' not in lab
        elif lab.lower().startswith('maximum') and 'ratio' in lab.lower() and _NUM.match(val.split()[0] if val else ''):
            out['max_ratio'] = float(val.split()[0])
        elif lab.lower().startswith('fails in'):
            out['governing_note'] = lab
        elif 'ratio' in lab.lower() and not lab.lower().startswith(('maximum', '[')) and 'configuration' not in lab.lower():
            v = val
            if not _NUM.match(v.split()[0] if v else ''):
                nxt = lines[i + 1].partition('|')[2].strip() if i + 1 < len(lines) else ''
                v = nxt
            if v and _NUM.match(v.split()[0]):
                out['checks'].append({'check': re.sub(r'^Interaction ratio (in|for) ', '', lab, flags=re.I).strip(), 'ratio': float(v.split()[0])})
    return out


def run(kind, params, method='LRFD', units='NEWTON_MM', workdir=None, name=None):
    kind = kind_of(kind)
    exe = binary()
    workdir = workdir or tempfile.mkdtemp(prefix='sb_osoconn_')
    name = re.sub(r'[^A-Za-z0-9_\-]', '_', name or kind)
    cin = os.path.join(workdir, name + '.cin')
    write_input(kind, params, cin, method, units, cid=name)
    cwd = os.path.dirname(exe)                            # Osoconn reads data/AISCSections.db next to the executable
    r = subprocess.run([exe, cin], capture_output=True, text=True, cwd=cwd, timeout=120)
    txt = r.stdout
    if 'Run successful' not in txt:
        msg = txt.split('Running file')[-1].strip().replace('*', '').strip()
        msg = re.sub(r'^.*?\.cin\.\.\.\s*', '', msg, flags=re.S).strip() or 'Osoconn did not run'
        msg = msg.replace('Run unsuccessful.', '').strip()
        absent = [k for k in keys(kind) if k not in {str(x).upper().strip() for x in params}]
        if absent:
            msg += ' (inputs not given: ' + ', '.join(absent) + ')'
        raise ValueError(msg)
    cou = os.path.join(workdir, name + '.cou')
    res = parse_output(open(cou, errors='replace').read())
    res.update({'kind': kind, 'code': CODES[kind][0], 'method': str(method).upper(), 'units': units, 'output_file': os.path.basename(cou)})
    if res['checks']:
        g = max(res['checks'], key=lambda c: c['ratio'])
        res['governing'] = g
        res['failing'] = [c for c in res['checks'] if c['ratio'] > 1.0]
    res['plain_english'] = _words(res)
    return res


def _words(r):
    name = r['kind'].replace('_', ' ')
    g = r.get('governing')
    s = f"AISC 360 {r['method']} check of the {name} connection (Osoconn {r['code']}): " + ('the connection is OK' if r['ok'] else 'the connection is NOT OK')
    if r.get('max_ratio') is not None:
        s += f", maximum interaction ratio {r['max_ratio']:.3f}"
    if g:
        s += f"; governing check: {g['check']} ({g['ratio']:.3f})"
    if r.get('failing'):
        s += '. Over 1.0: ' + ', '.join(f"{c['check']} {c['ratio']:.2f}" for c in r['failing'][:6])
    if r.get('governing_note'):
        s += '. Osoconn says: ' + r['governing_note']
    return s + f". The full calculation is in {r['output_file']}."


def aisc_sections(kind='W'):
    return os.path.join(CLA, 'data', 'AISCSections.db')


def aisc_section(name):
    """AISC W shape from Osoconn's database -> {'h','b','tw','tf'} in mm (inch shapes converted); None when not found"""
    db = os.path.join(CLA, 'data', 'AISCSections.db')
    key = str(name).upper().replace(' ', '').replace('-', '')
    c = sqlite3.connect(db)
    try:
        row = c.execute('SELECT Section, d, bf, tw, tf, unit FROM Wsection WHERE UPPER(Section)=?', (key,)).fetchone()
    finally:
        c.close()
    if not row:
        return None
    f = 25.4 if row[5] == 'in' else 1.0
    return {'name': row[0], 'h': row[1] * f, 'b': row[2] * f, 'tw': row[3] * f, 'tf': row[4] * f}
