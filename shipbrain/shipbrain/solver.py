"""
Run CalculiX (free, CPU) on an .inp written by mesh.py and read the results back (max displacement, max von Mises).
ccx must be on PATH (Windows: CalculiX from bConverged / PrePoMax; Linux: apt install calculix-ccx).
"""
import math, os, shutil, subprocess


def ccx_path():
    return os.environ.get('CCX') or shutil.which('ccx') or shutil.which('ccx_static') or shutil.which('ccx.exe')


def _blocks(frd):
    """yield (name, {node: [values]}) for each nodal result block of a .frd file (ASCII)"""
    name, data = None, None
    with open(frd, errors='replace') as f:
        for line in f:
            if line.startswith(' -4'):
                name, data = line.split()[1], {}
            elif name and line.startswith(' -1'):
                nid = int(line[3:13])
                vals = [float(line[13 + 12 * i: 25 + 12 * i]) for i in range((len(line.rstrip()) - 13) // 12)]
                data[nid] = vals
            elif name and line.startswith(' -3'):
                yield name, data
                name, data = None, None


def read_frd_full(frd):
    """node coordinates (incl. CalculiX's expanded shell/beam nodes) + nodal stress tensors [sxx syy szz sxy syz szx]"""
    xyz, stress, disp = {}, {}, {}
    mode = None
    with open(frd, errors='replace') as f:
        for line in f:
            if line.startswith('    2C'):
                mode = 'xyz'
                continue
            if line.startswith(' -4'):
                name = line.split()[1]
                mode = 'S' if name.startswith('STRESS') else ('U' if name.startswith('DISP') else None)
                continue
            if line.startswith(' -3'):
                mode = None
                continue
            if line.startswith(' -1') and mode:
                nid = int(line[3:13])
                vals = [float(line[13 + 12 * i: 25 + 12 * i]) for i in range((len(line.rstrip()) - 13) // 12)]
                (xyz if mode == 'xyz' else stress if mode == 'S' else disp)[nid] = vals
    return xyz, stress, disp


def read_frd(frd):
    out = {}
    for name, d in _blocks(frd):
        if name.startswith('DISP') and d:
            uz = {n: v[2] for n, v in d.items()}
            umag = {n: math.sqrt(sum(x * x for x in v[:3])) for n, v in d.items()}
            nmax = max(umag, key=umag.get)
            out['max_displacement_mm'] = round(umag[nmax], 4)
            out['max_displacement_node'] = nmax
            out['min_uz_mm'] = round(min(uz.values()), 4)
        elif name.startswith('STRESS') and d:
            def vm(v):
                sx, sy, sz, sxy, syz, szx = v[:6]
                return math.sqrt(0.5 * ((sx - sy) ** 2 + (sy - sz) ** 2 + (sz - sx) ** 2) + 3 * (sxy ** 2 + syz ** 2 + szx ** 2))
            v = {n: vm(x) for n, x in d.items()}
            nmax = max(v, key=v.get)
            out['max_von_mises_MPa'] = round(v[nmax], 2)
            out['max_von_mises_node'] = nmax
    return out


def run_calculix(inp, timeout=1800):
    exe = ccx_path()
    if not exe:
        raise RuntimeError('CalculiX (ccx) not found on PATH; set CCX=path\\to\\ccx.exe')
    inp = os.path.abspath(inp)
    job = inp[:-4] if inp.endswith('.inp') else inp
    r = subprocess.run([exe, '-i', os.path.basename(job)], cwd=os.path.dirname(job), capture_output=True, text=True, timeout=timeout)
    log = (r.stdout or '') + (r.stderr or '')
    if not os.path.exists(job + '.frd') or '*ERROR' in log:
        errs = [l for l in log.splitlines() if 'ERROR' in l][:10]
        raise RuntimeError('CalculiX failed: ' + ('; '.join(errs) or log[-800:]))
    res = read_frd(job + '.frd')
    res['frd'] = job + '.frd'
    res['note'] = 'nodal values extrapolated by CalculiX; shell stress is the max over top/bottom/mid fibres'
    return res


# ====================================================================== more analysis types from one model
def _split_step(lines):
    i = next(k for k, l in enumerate(lines) if l.strip().upper().startswith('*STEP'))
    j = max(k for k, l in enumerate(lines) if l.strip().upper().startswith('*END STEP'))
    return lines[:i], lines[i:j + 1]


def _blocks_of(step, keywords):
    """keep the keyword blocks of a step whose keyword is in keywords (e.g. *BOUNDARY, *CLOAD, *DLOAD)"""
    out, keep = [], False
    for l in step[1:-1]:
        if l.startswith('*'):
            keep = l.split(',')[0].strip().upper() in keywords
        if keep:
            out.append(l)
    return out


def make_analysis(inp, analysis='static', n_modes=10, out=None):
    """rewrite the step of a static .inp into another analysis of the same model:
    modal    natural frequencies + mode shapes (*FREQUENCY; loads dropped, supports kept)
    buckling linear buckling load factors for the applied loads (*BUCKLE)
    static   unchanged"""
    lines = open(inp).read().splitlines()
    head, step = _split_step(lines)
    bc = _blocks_of(step, {'*BOUNDARY'})
    loads = _blocks_of(step, {'*CLOAD', '*DLOAD'})
    if analysis == 'modal':
        new = ['*STEP', '*FREQUENCY', str(int(n_modes))] + bc + ['*NODE FILE', 'U', '*END STEP']
    elif analysis == 'buckling':
        if not loads:
            raise ValueError('buckling needs loads in the model (e.g. edge compression forces)')
        new = ['*STEP', '*BUCKLE', str(int(n_modes))] + bc + loads + ['*NODE FILE', 'U', '*END STEP']
    elif analysis == 'static':
        new = step
    else:
        raise ValueError('analysis: static | modal | buckling')
    out = out or inp[:-4] + f'_{analysis}.inp'
    open(out, 'w').write('\n'.join(head + new) + '\n')
    return out


def read_dat_table(dat, title):
    """rows of numbers after a CalculiX .dat heading such as 'E I G E N V A L U E   O U T P U T'"""
    rows, on = [], False
    for l in open(dat, errors='replace'):
        if title in l:
            on, rows = True, []
            continue
        if on:
            p = l.split()
            if p and p[0].isdigit():
                try:
                    rows.append([int(p[0])] + [float(x) for x in p[1:]])
                except ValueError:
                    pass
            elif rows and not l.strip():
                on = False
    return rows


def run_analysis(inp, analysis='static', n_modes=10, timeout=3600):
    """static / modal / buckling of an existing .inp (written by ShipBrain) with CalculiX; plain-English result"""
    if analysis == 'static':
        r = run_calculix(inp, timeout)
        r['plain_english'] = (f"Linear static: max displacement {r.get('max_displacement_mm')} mm, max von Mises "
                              f"{r.get('max_von_mises_MPa')} MPa.")
        return r
    var = make_analysis(inp, analysis, n_modes)
    exe = ccx_path()
    if not exe:
        raise RuntimeError('CalculiX (ccx) not found on PATH; set CCX=path\\to\\ccx.exe')
    job = os.path.abspath(var)[:-4]
    r = subprocess.run([exe, '-i', os.path.basename(job)], cwd=os.path.dirname(job), capture_output=True, text=True, timeout=timeout)
    log = (r.stdout or '') + (r.stderr or '')
    if '*ERROR' in log or not os.path.exists(job + '.dat'):
        errs = [l for l in log.splitlines() if 'ERROR' in l][:10]
        raise RuntimeError('CalculiX failed: ' + ('; '.join(errs) or log[-800:]))
    if analysis == 'modal':
        rows = read_dat_table(job + '.dat', 'E I G E N V A L U E   O U T P U T')
        f = [round(row[3], 3) for row in rows]                      # cycles/time = Hz in mm-N-t-s units
        return {'analysis': 'modal', 'frequencies_hz': f, 'frd': os.path.basename(job + '.frd'),
                'plain_english': f"Natural frequencies (first {len(f)}): " + ', '.join(f'{x:g} Hz' for x in f[:6])
                                 + '. Units: mm, N, tonne, s.'}
    rows = read_dat_table(job + '.dat', 'B U C K L I N G   F A C T O R   O U T P U T')
    lam = [round(row[1], 4) for row in rows]
    return {'analysis': 'buckling', 'load_factors': lam, 'frd': os.path.basename(job + '.frd'),
            'plain_english': (f"Lowest buckling load factor {lam[0]:g}: the structure buckles at {lam[0]:g} x the applied load"
                              + (' (it buckles BEFORE the applied load is reached).' if lam and lam[0] < 1 else '.')) if lam else
                             'No buckling factors found in the CalculiX output.'}
