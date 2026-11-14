"""
1D finite volume cases by running the scripts of Finite-Volume-Method-for-1D-CFD-Simulations (MIT, Mohith Sai Gorla; copied unchanged in
vendor/fvm1d/repo) in Octave. ShipBrain only (1) copies a script, (2) replaces its input lines (k, A, L, n, Ta, Tb, q ...), (3) cuts the
plot lines, (4) runs it and reads the arrays back, and (5) compares with the exact solution where one exists. Needs Octave on the PATH.

Cases: diffusion (conduction, no source), heat_generation (conduction with uniform source), convection_diffusion (central scheme),
simple (1D duct, pressure-correction step: n = 4 and the initial velocity guess are fixed in the script).
"""
import math, os, re, shutil, subprocess, tempfile

import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'fvm1d', 'repo')
CASES = {
    'diffusion': ('oned_diffusion.m', ['k', 'A', 'l', 'n', 'Ta', 'Tb'], 'T'),
    'heat_generation': ('oned_diffusion_with_heat_generation.m', ['k', 'A', 'L', 'q', 'n', 'Ta', 'Tb'], 'T'),
    'convection_diffusion': ('oned_diffusion_convection_CDS.m', ['rho', 'u', 'K', 'L', 'n', 'phi_a', 'phi_b'], 'phi'),
    'simple': ('oned_SIMPLE_Algorithm.m', ['rho', 'A'], 'u'),
}


def octave():
    return shutil.which('octave-cli') or shutil.which('octave')


def _script(case, p):
    fn, names, _ = CASES[case]
    src = open(os.path.join(ROOT, fn), encoding='utf-8').read()
    for k, v in p.items():
        if k not in names:
            raise ValueError(f'{k} is not an input of {case}; inputs: {", ".join(names)}')
        src, n = re.subn(r'(?m)^(\s*' + re.escape(k) + r'\s*=\s*)[^;\n]*;', lambda m: m.group(1) + repr(float(v)) + ';', src, count=1)
        if n != 1:
            raise ValueError(f'input {k} not found in {fn}')
    m = re.search(r'(?mi)^%\s*Plot', src) or re.search(r'(?m)^figure', src)
    if m:
        src = src[:m.start()]
    return src


def run(case, workdir=None, **p):
    if case not in CASES:
        raise ValueError('case must be one of ' + ', '.join(CASES))
    exe = octave()
    if not exe:
        raise RuntimeError('Octave is not installed: install GNU Octave (free, https://octave.org) and ask again - these scripts are MATLAB/Octave code.')
    if case != 'simple' and 'n' in p and int(p['n']) < 3:
        raise ValueError('use at least 3 nodes')
    src = _script(case, p)
    var = CASES[case][2]
    src += f"\nprintf('RESULT:'); printf(' %.12g', {var}(:)'); printf('\\n');\n"
    if case == 'simple':
        src += "printf('PCOR:'); printf(' %.12g', p_cor(:)'); printf('\\n');\n"
    wd = workdir or tempfile.mkdtemp(prefix='sb_fvm_')
    path = os.path.join(wd, 'case.m')
    open(path, 'w', encoding='utf-8').write(src)
    r = subprocess.run([exe, '--no-gui', '--norc', path], capture_output=True, text=True, timeout=120, cwd=wd)
    line = next((l for l in r.stdout.splitlines() if l.startswith('RESULT:')), None)
    if r.returncode or not line:
        raise RuntimeError('Octave failed: ' + ' | '.join([l for l in (r.stdout + r.stderr).splitlines() if l.strip()][-3:]))
    vals = np.array([float(v) for v in line[7:].split()])
    out = {'case': case, 'script': CASES[case][0], 'inputs': dict(p)}
    if case == 'simple':
        out['velocity_m_s'] = [round(float(v), 6) for v in vals]
        pc = next(l for l in r.stdout.splitlines() if l.startswith('PCOR:'))
        out['pressure_correction_pa'] = [round(float(v), 6) for v in pc[5:].split()]
        rho, A = p.get('rho', 1.0), p.get('A', 1.0)
        out['mass_flow_kg_s'] = [round(float(rho * A * v), 6) for v in vals]
        return out
    n = int(p.get('n', {'diffusion': 5, 'heat_generation': 5, 'convection_diffusion': 5}[case]))
    L = float(p.get('l', p.get('L', {'diffusion': 0.5, 'heat_generation': 0.02, 'convection_diffusion': 1.0}[case])))
    dx = L / n
    x = np.concatenate([[0.0], dx / 2 + dx * np.arange(n), [L]])      # cell centres (the script's own x vector is only used for its plot)
    a, b = (p.get('Ta', {'diffusion': 100, 'heat_generation': 100}.get(case)), p.get('Tb', {'diffusion': 500, 'heat_generation': 200}.get(case)))
    if case == 'convection_diffusion':
        a, b = p.get('phi_a', 1.0), p.get('phi_b', 0.0)
        Pe = p.get('rho', 1.0) * p.get('u', 0.1) * L / p.get('K', 0.1)
        ex = a + (b - a) * np.expm1(Pe * x / L) / np.expm1(Pe) if abs(Pe) > 1e-9 else a + (b - a) * x / L
    else:
        ex = a + (b - a) * x / L
        if case == 'heat_generation':
            ex = ex + p.get('q', 1e6) * x * (L - x) / (2 * p.get('k', 0.5))
    err = np.abs(vals - ex)
    out.update({'x_m': [round(float(v), 6) for v in x], 'values': [round(float(v), 6) for v in vals], 'exact': [round(float(v), 6) for v in ex],
                'max_error': round(float(err.max()), 6), 'nodes': n, 'cell_size_m': round(dx, 6)})
    return out
