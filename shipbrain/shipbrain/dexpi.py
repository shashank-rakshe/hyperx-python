"""
DEXPI P&IDs (the open ISO 15926-based P&ID exchange standard) with pyDEXPI (https://github.com/process-intelligence-
research/pyDEXPI, AGPL-3.0; DEXPI Studio is its desktop app). Copied whole into vendor/ (pyDEXPI, DEXPI-Studio) and
run as written, as its own program (its command line / its MCP server) - allowed because ShipBrain is declared open
and non-commercial (licence_mode.json).

  summary(file)         equipment (class + tag), instruments, piping systems / segments / components
  validate(file)        every DEXPI rule of pyDEXPI (+ what the loader could not read, with line numbers)
  tables(file, ...)     equipment / line / instrument / piping-component / valve lists (xlsx, csv, json)
  graph(file, level)    the plant graph (GraphML) for graph questions
  svg(file) / png(file) the drawing
  diff(old, new)        what was added, removed, moved, modified (two revisions of one model)
Files: DEXPI 2.0 / 2.0.1 XML or JSON, and Proteus XML (DEXPI 1.3).
"""
import json, os, re, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'pyDEXPI', 'repo')
DATA = os.path.join(ROOT, 'data')
_CLI = 'import sys; from pydexpi.cli import app; sys.argv[0] = "pydexpi"; app()'


def _run(*args, timeout=900):
    try:
        import pydexpi  # noqa: F401
    except ImportError:
        raise ModuleNotFoundError("No module named 'pydexpi'")
    r = subprocess.run([sys.executable, '-c', _CLI] + [str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or ''), (r.stderr or '')


def _words(cls):
    return re.sub(r'(?<!^)(?=[A-Z])', ' ', cls).lower()


def summary(path):
    """info with the lists kept (the CLI prints counts and lists under the same names)"""
    code, out, err = _run('info', path)
    if code and not out.strip():
        raise RuntimeError('pyDEXPI could not read the file: ' + err.strip()[-600:])
    counts, eq, ins, sec = {}, [], [], None
    for ln in out.splitlines():
        if not ln.strip():
            continue
        m = re.match(r'([A-Za-z][A-Za-z ]+?)(?: \(incl\. valves\))?:\s+(\d+)\s*(?:\(incl\. valves\))?$', ln)
        if m and not ln.startswith(' '):
            counts[m.group(1).strip().lower().replace(' ', '_')] = int(m.group(2))
            continue
        if ln.startswith('Equipment tags'):
            sec = 'eq'
        elif ln.startswith('Instrument tags'):
            sec = 'ins'
        elif ln.startswith(' ') and sec == 'eq':
            p = ln.split()
            eq.append({'class': p[0], 'tag': ' '.join(p[1:])} if len(p) > 1 else {'class': p[0], 'tag': ''})
        elif ln.startswith(' ') and sec == 'ins':
            ins.append(ln.strip())
    n_eq, n_in = counts.get('equipment', len(eq)), counts.get('instruments', len(ins))
    eqs = '; '.join(f"{e['tag'] or '(no tag)'} - {_words(e['class'])}" for e in eq[:30])
    pe = (f"This P&ID has {n_eq} equipment item(s)" + (f": {eqs}" if eqs else '') + '. '
          f"Piping: {counts.get('piping_network_systems', 0)} system(s), {counts.get('piping_segments', 0)} segment(s), "
          f"{counts.get('piping_components', 0)} component(s) including valves. "
          f"Instruments: {n_in}" + (f" ({', '.join(ins[:30])})" if ins else '') + '.')
    return {'counts': counts, 'equipment': eq, 'instruments': ins, 'plain_english': pe}


def validate(path):
    code, out, err = _run('validate', path)
    text = (out + '\n' + err).strip()
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    head = next((ln for ln in lines if 'issue(s)' in ln), '')
    m = re.search(r'(\d+) issue\(s\), (\d+) loader', head)
    issues, loader = (int(m.group(1)), int(m.group(2))) if m else (None, None)
    details = [ln for ln in lines if ln != head and not ln.startswith(('File:',))][:40]
    pe = (f"{os.path.basename(path)}: " + ('it follows every DEXPI rule pyDEXPI checks - no issues.' if issues == 0 and not loader else
          f"{issues} rule issue(s) and {loader} part(s) the loader could not read." + (f" First: {details[0]}" if details else '')))
    return {'issues': issues, 'loader_entries': loader, 'details': details, 'plain_english': pe}


def tables(path, out_stem, lists=('all',), fmt='xlsx'):
    args = ['export-table', path, '-o', out_stem, '-f', fmt]
    for l_ in lists:
        args += ['-l', l_]
    code, out, err = _run(*args)
    made = [f for f in (out_stem + '.' + fmt, out_stem + '.xlsx') if os.path.exists(f)]
    made += [os.path.join(os.path.dirname(out_stem) or '.', f) for f in os.listdir(os.path.dirname(out_stem) or '.')
             if f.startswith(os.path.basename(out_stem)) and f.endswith('.' + fmt) and os.path.join(os.path.dirname(out_stem) or '.', f) not in made]
    if not made:
        raise RuntimeError('table export failed: ' + (err or out).strip()[-600:])
    return {'files': sorted(set(made)), 'plain_english': f"Wrote {', '.join(os.path.basename(f) for f in sorted(set(made)))} "
                                                         f"(equipment, line, instrument, piping-component and valve lists)."}


def svg(path, out):
    code, o, err = _run('svg', path, '-o', out)
    if not os.path.exists(out):
        msg = (err or o).strip()
        if 'no diagram data' in msg:
            raise ValueError('this DEXPI file has no drawing data (only the plant data), so it cannot be drawn')
        raise RuntimeError('drawing failed: ' + msg[-600:])
    return out


def png(path, out, scale=1.0):
    s = svg(path, os.path.splitext(out)[0] + '.svg')
    r = subprocess.run([sys.executable, '-c', 'import sys; from pydexpi.exports.png_export import svg_to_png; '
                        'svg_to_png(open(sys.argv[1], encoding="utf-8").read(), sys.argv[2], float(sys.argv[3]))', s, out, str(scale)],
                       capture_output=True, text=True, timeout=600)
    if not os.path.exists(out):
        raise RuntimeError('picture failed: ' + (r.stderr or r.stdout).strip()[-600:])
    return out


def diff(old, new):
    code, out, err = _run('diff', old, new)
    text = out.strip() or err.strip()
    return {'diff': text[-6000:], 'plain_english': 'Changes between the two P&ID revisions: ' + re.sub(r'\s+', ' ', text)[:900]}


def examples():
    """the real DEXPI P&IDs shipped with pyDEXPI (reference P&ID, DEXPI training test cases, two real processes)"""
    out = []
    for dp, _, fs in os.walk(DATA):
        for f in fs:
            if f.lower().endswith('.xml') and 'Schema' not in f:
                out.append(os.path.join(dp, f))
    return sorted(out)
