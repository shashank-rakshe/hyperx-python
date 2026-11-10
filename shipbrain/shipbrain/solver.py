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
