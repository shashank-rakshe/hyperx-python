"""
Siemens NX automation (needs the user's own NX / Simcenter 3D; ShipBrain itself reads NX files without NX via cadmpeg):

  NX Open journals   nxopentse (https://github.com/theScriptingEngineer/nxopentse, AGPL-3.0, copied as written; the
                     packaged successor of NXOpen-CAE-python by the same author) holds ready NX Open Python functions:
                     CAD (bodies, faces, features, datum planes, points, splines, assemblies, layers, colours, mass
                     properties) and Simcenter CAE (mesh collectors, nodes, forces / moments / pressure on groups,
                     constraints, solutions, subcases, solver sets, solving, results: load, export, combine, envelope,
                     nodal / elemental values, screenshots, universal files).
                     catalogue() / find() / syntax() list them from the code itself (never invented); journal() writes a
                     journal that opens a part and calls them in order; run() starts it with NX's run_journal when NX
                     is installed, otherwise the user runs it in NX (File > Execute > NX Open... / Alt+F8).
  rename             NX File Renamer (https://github.com/nahidmubin/Siemens_NX_File_Renamer, GPL-3.0, copied as written):
                     renames a .prt and updates the assemblies / drawings in the same folder that use it, with NX's own
                     ug_edit_part_names (Windows, NX installed).
"""
import ast, glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TSE = os.path.join(HERE, 'vendor', 'nxopentse', 'repo', 'src')
RENAMER = os.path.join(HERE, 'vendor', 'nx_file_renamer', 'repo')
_CAT = None


# ====================================================================== the function library, read from its code
def catalogue():
    """'module.function' -> {module, name, args [{name, type, default, required}], returns, doc}"""
    global _CAT
    if _CAT is not None:
        return _CAT
    out = {}
    base = os.path.join(TSE, 'nxopentse')
    for dp, _, fs in os.walk(base):
        for f in sorted(fs):
            if not f.endswith('.py') or f == '__init__.py':
                continue
            path = os.path.join(dp, f)
            mod = 'nxopentse.' + os.path.relpath(path, base)[:-3].replace(os.sep, '.')
            tree = ast.parse(open(path, encoding='utf-8', errors='replace').read())
            for node in tree.body:
                if not isinstance(node, ast.FunctionDef) or node.name.startswith('_'):
                    continue
                a = node.args
                pos = a.args
                defaults = [None] * (len(pos) - len(a.defaults)) + list(a.defaults)
                args = [{'name': p.arg, 'type': ast.unparse(p.annotation) if p.annotation else None,
                         'default': ast.unparse(d) if d is not None else None, 'required': d is None}
                        for p, d in zip(pos, defaults)]
                out[f'{mod}.{node.name}'] = {'module': mod, 'name': node.name, 'args': args,
                                             'returns': ast.unparse(node.returns) if node.returns else None,
                                             'doc': (ast.get_docstring(node) or '').strip()}
    _CAT = out
    return out


def find(query, limit=12):
    """functions whose name or description match the words of the query"""
    words = [w for w in re.findall(r'[a-z0-9]+', query.lower()) if len(w) > 2]
    scored = []
    for k, v in catalogue().items():
        name, doc = v['name'].lower(), v['doc'].lower()[:600]
        s = sum(3 * (w in name) + (w in doc) for w in words)
        if s:
            scored.append((s, k))
    scored.sort(key=lambda x: (-x[0], x[1]))
    return [{'function': k, 'call': _sig(catalogue()[k]), 'what': catalogue()[k]['doc'].split('\n')[0][:200]}
            for _, k in scored[:limit]]


def _sig(v):
    return v['name'] + '(' + ', '.join(a['name'] + (f": {a['type']}" if a['type'] else '') +
                                       (f" = {a['default']}" if a['default'] else '') for a in v['args']) + ')' + \
        (f" -> {v['returns']}" if v['returns'] else '')


def syntax(name):
    cat = catalogue()
    hits = [k for k in cat if k == name or k.endswith('.' + name)]
    if not hits:
        near = find(name.replace('_', ' '), 5)
        raise KeyError(f'no nxopentse function {name}; closest: ' + ', '.join(n['function'] for n in near))
    v = cat[hits[0]]
    return {'function': hits[0], 'call': _sig(v), 'args': v['args'], 'returns': v['returns'], 'doc': v['doc'][:3000]}


# ====================================================================== journals
def _lit(v, names):
    """a journal argument: a literal, "$name" / "$name[0]" for an earlier result, or {"nx": "NXOpen.X.Y"} for an NX constant"""
    if isinstance(v, dict) and set(v) == {'nx'}:          # an NX enum / constant, e.g. NXOpen.CAE.CaeSetGroupFilterType.GeomFace
        if not re.fullmatch(r'NXOpen(\.[A-Za-z_]\w*)+', str(v['nx'])):
            raise ValueError(f"not an NXOpen name: {v['nx']}")
        return v['nx']
    if isinstance(v, str) and re.fullmatch(r'\$[A-Za-z_]\w*(\[\d+\])?', v):
        base = v[1:].split('[')[0]
        if base not in names:
            raise ValueError(f'{v} refers to no earlier result (known: {", ".join(sorted(names)) or "none"})')
        return v[1:]
    return repr(v)


def journal(calls, part=None, out='shipbrain_journal.py', title='ShipBrain journal'):
    """NX Open Python journal: open `part` (optional), then each call {"fn", "args": {...}, "as": name, "for_each": "$x"}
    in order, every result printed to NX's listing window. Function and argument names are checked against nxopentse."""
    cat = catalogue()
    names, body = set(), []
    for i, c in enumerate(calls, 1):
        fn = c['fn']
        hits = [k for k in cat if k == fn or k.endswith('.' + fn)]
        if not hits:
            syntax(fn)                                   # raises with the closest names
        v = cat[hits[0]]
        args = dict(c.get('args') or {})
        known = {a['name'] for a in v['args']}
        bad = sorted(set(args) - known)
        if bad:
            raise ValueError(f"{v['name']} has no argument {', '.join(bad)}; its call is {_sig(v)}")
        each = c.get('for_each')
        item = None
        if each:
            item = 'item'
            names.add('item')
        missing = [a['name'] for a in v['args'] if a['required'] and a['name'] not in args]
        if missing and not (each and len(missing) == 1):
            raise ValueError(f"{v['name']} needs {', '.join(missing)}; its call is {_sig(v)}")
        if each and missing:
            args[missing[0]] = '$item'
        call = f"{v['module']}.{v['name']}(" + ', '.join(f'{k}={_lit(x, names)}' for k, x in args.items()) + ')'
        var = c.get('as') or f'r{i}'
        if not re.fullmatch(r'[A-Za-z_]\w*', var):
            raise ValueError(f'bad result name {var}')
        if each:
            src = _lit(each, names)
            body += [f'    {var} = []', f'    for item in {src}:', f'        {var}.append({call})',
                     f"    the_lw.WriteFullline('{v['name']}: ' + str(len({var})) + ' results')"]
        else:
            body += [f'    {var} = {call}', f"    the_lw.WriteFullline('{v['name']}: ' + str({var}))"]
        names.add(var)
    head = [f'# {title} - NX Open (Python) journal written by ShipBrain.',
            '# Uses nxopentse (AGPL-3.0, https://github.com/theScriptingEngineer/nxopentse) as written.',
            '# Run in NX: File > Execute > NX Open... (Alt+F8), or: run_journal.exe <this file> -args <part>.',
            'import sys', f'sys.path.insert(0, r"{TSE}")      # or: pip install nxopentse (into the Python NX uses)',
            'import NXOpen', 'import NXOpen.CAE', 'import nxopentse', 'import nxopentse.cad.code', 'import nxopentse.cae.preprocessing',
            'import nxopentse.cae.postprocessing', 'import nxopentse.cae.solving', 'import nxopentse.tools.general', '',
            'the_session = NXOpen.Session.GetSession()', 'the_lw = the_session.ListingWindow', '', '',
            'def main(args):', '    the_lw.Open()']
    if part:
        head += [f'    part_file = args[0] if args else r"{part}"',
                 '    base_part, status = the_session.Parts.OpenActiveDisplay(part_file, NXOpen.DisplayPartOption.AllowAdditional)',
                 '    status.Dispose()', "    the_lw.WriteFullline('opened ' + part_file)"]
    else:
        head += ['    # works on the part that is open in NX']
    text = '\n'.join(head + body + ['', '', "if __name__ == '__main__':", '    main(sys.argv[1:])', ''])
    ast.parse(text)                                      # the journal is valid Python
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(text)
    return out


# ====================================================================== NX on this PC
def nx_dir():
    """NX's base folder: UGII_BASE_DIR, else the usual install folders"""
    d = os.environ.get('UGII_BASE_DIR')
    if d and os.path.isdir(d):
        return d
    cands = sorted(glob.glob(r'C:\Program Files\Siemens\NX*') + glob.glob(r'C:\Program Files\Siemens\Simcenter*') +
                   glob.glob('/opt/Siemens/NX*') + glob.glob('/usr/Siemens/NX*'), reverse=True)
    return cands[0] if cands else None


def _nxbin(exe):
    d = nx_dir()
    if not d:
        return None
    for c in (os.path.join(d, 'NXBIN', exe + '.exe'), os.path.join(d, 'NXBIN', exe), os.path.join(d, 'nxbin', exe)):
        if os.path.exists(c):
            return c
    return None


def run(journal_file, part=None, timeout=3600):
    rj = _nxbin('run_journal')
    if not rj:
        return {'ran': False, 'journal': journal_file,
                'plain_english': ('NX is not installed on this PC (or UGII_BASE_DIR is not set), so the journal was written but '
                                  f'not run. In NX: File > Execute > NX Open... (Alt+F8) and pick {os.path.basename(journal_file)}'
                                  + (f', with {os.path.basename(part)} open.' if part else '.'))}
    cmd = [rj, journal_file] + (['-args', part] if part else [])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return {'ran': True, 'exit_code': p.returncode, 'output': (p.stdout + p.stderr)[-6000:],
            'plain_english': f"Ran {os.path.basename(journal_file)} in NX (exit code {p.returncode})."}


# ====================================================================== rename with links kept
def rename(prt, new_name):
    """NX File Renamer as written: rename prt to new_name(.prt) and update every assembly / drawing in its folder"""
    if os.name != 'nt':
        raise RuntimeError('Renaming NX files with their links needs Windows with NX installed (NX File Renamer uses NX\'s '
                           'ug_edit_part_names). On this PC: rename it in NX (File > Save As / Assembly Navigator) instead.')
    if not _nxbin('ug_edit_part_names'):
        raise RuntimeError('NX is not found (set UGII_BASE_DIR to the NX folder): ug_edit_part_names is needed to keep the links.')
    os.environ.setdefault('UGII_BASE_DIR', nx_dir())
    sys.path.insert(0, RENAMER)
    try:
        from core.renamer_script import rename_nx_file          # needs pywin32 (win32com) like the original
    except ImportError as e:
        raise RuntimeError(f'NX File Renamer needs pywin32: pip install pywin32 ({e})')
    finally:
        sys.path.remove(RENAMER)
    log = []
    new = re.sub(r'\.prt$', '', new_name, flags=re.I)
    rename_nx_file(os.path.abspath(prt), new, log=lambda s: log.append(str(s).strip()))
    return {'file': os.path.join(os.path.dirname(prt), new + '.prt'), 'log': log,
            'plain_english': f"Renamed {os.path.basename(prt)} to {new}.prt; files told about it: "
                             + (', '.join(l.split(' is informed')[0] for l in log if 'informed' in l) or 'none in that folder') + '.'}
