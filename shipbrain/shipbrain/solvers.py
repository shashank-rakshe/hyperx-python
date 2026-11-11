"""
Solvers installed on THIS workstation: find them, run one in batch on a model ShipBrain wrote, read the results back.

ShipBrain itself builds CAD and the mesh; the analysis runs in a solver the company already has. find() looks on the
PATH, in the usual install folders (Windows and Linux) and in a user list (solvers.json), so the assistant can offer
only what is really there; the user picks one; run() writes the right input, runs it, and reads the answer.

  solver      input written by ShipBrain   run command (batch)                              results read from
  calculix    .inp                         ccx -i job                                       .dat / .frd   (tested)
  nastran     .bdf                         nastran job.bdf scr=yes batch=no (MSC / NX / Simcenter)   .f06
  mystran     .bdf                         mystran job.bdf                                  .f06
  ansys       .mac (+ result export)       ANSYSxxx -b -i job.mac -o job.out                 job_result.txt
  abaqus      .inp (+ extract script)      abaqus job=job interactive; abaqus python x.py   job_result.json
  openfoam    (case folder)                found and reported; case set-up is guided for now

Only CalculiX could be tested where ShipBrain was built. The other adapters follow each solver's documented batch
interface; test them once on your workstation (python -m shipbrain.solvers --check).
"""
import glob, json, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
USER_LIST = os.environ.get('SHIPBRAIN_SOLVERS', os.path.join(os.path.expanduser('~'), '.shipbrain', 'solvers.json'))

# name -> executable names on PATH, glob patterns of usual install places
KNOWN = {
    'calculix': (['ccx', 'ccx_static', 'ccx_MT', 'ccx.exe'],
                 [r'C:\Program Files\bConverged\CalculiX\ccx\ccx*.exe', r'C:\PrePoMax*\Solver\ccx*.exe',
                  r'C:\Program Files\PrePoMax*\Solver\ccx*.exe', '/usr/bin/ccx*', '/usr/local/bin/ccx*']),
    'nastran': (['nastran', 'nast*.exe'],
                [r'C:\MSC.Software\MSC_Nastran\*\bin\nastran*.exe', r'C:\Program Files\MSC.Software\MSC_Nastran\*\bin\nastran*.exe',
                 r'C:\Program Files\Siemens\Simcenter*\NXNASTRAN\bin\nastran*.exe', r'C:\Program Files\Siemens\NX*\NXNASTRAN\bin\nastran*.exe',
                 '/opt/msc/MSC_Nastran/*/bin/nastran', '/usr/local/bin/nastran']),
    'mystran': (['mystran', 'MYSTRAN.exe', 'mystran.exe'], [r'C:\MYSTRAN\*.exe', '/usr/local/bin/mystran',
                                                            os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'mystran', 'Binaries', 'mystran*')]),
    'ansys': (['ansys241', 'ansys242', 'ansys232', 'ansys231', 'ansys222', 'mapdl'],
              [r'C:\Program Files\ANSYS Inc\v*\ansys\bin\winx64\ANSYS*.exe', r'C:\Program Files\ANSYS Inc\v*\ansys\bin\winx64\MAPDL.exe',
               '/ansys_inc/v*/ansys/bin/ansys*', '/usr/ansys_inc/v*/ansys/bin/ansys*']),
    'abaqus': (['abaqus', 'abq*'], [r'C:\SIMULIA\Commands\abaqus.bat', r'C:\SIMULIA\Commands\abq*.bat', '/opt/SIMULIA/Commands/abaqus',
                                    '/var/DassaultSystemes/SIMULIA/Commands/abaqus']),
    'openfoam': (['simpleFoam', 'interFoam', 'blockMesh'], [r'C:\Program Files\blueCFD-Core-*\OpenFOAM-*\platforms\*\bin\simpleFoam.exe',
                                                          '/opt/openfoam*/platforms/*/bin/simpleFoam', '/usr/lib/openfoam/openfoam*/platforms/*/bin/simpleFoam']),
    'code_aster': (['run_aster', 'as_run'], [r'C:\Code_Aster\*\bin\run_aster*', '/opt/aster/bin/as_run']),
}
ANALYSES = {'calculix': ['static', 'modal', 'buckling'], 'nastran': ['static', 'modal', 'buckling'], 'mystran': ['static', 'modal', 'buckling'],
            'ansys': ['static', 'modal', 'buckling'], 'abaqus': ['static', 'modal', 'buckling'], 'openfoam': ['cfd'], 'code_aster': []}
TESTED = {'calculix', 'mystran'}           # mystran: static / modal / buckling checked against CalculiX + hand formulas


def find():
    """-> [{'solver', 'path', 'analyses', 'tested'}] for everything installed here (plus the user's list)"""
    found, seen = [], set()

    def add(name, path, source):
        p = os.path.abspath(path)
        if p in seen or not os.path.exists(p):
            return
        seen.add(p)
        found.append({'solver': name, 'path': p, 'analyses': ANALYSES.get(name, []), 'tested_adapter': name in TESTED, 'found_by': source})
    if os.path.exists(USER_LIST):
        try:
            for name, path in json.load(open(USER_LIST)).items():
                add(name.split('#')[0], path, 'your solvers.json')
        except Exception:
            pass
    for name, (exes, pats) in KNOWN.items():
        for e in exes:
            for hit in ([shutil.which(e)] if '*' not in e else []):
                if hit:
                    add(name, hit, 'PATH')
        for pat in pats:
            for hit in sorted(glob.glob(pat), reverse=True)[:2]:
                add(name, hit, 'install folder')
    if os.environ.get('CCX'):
        add('calculix', os.environ['CCX'], 'CCX variable')
    return found


def remember(name, path):
    """add a solver by hand (e.g. a company install in an unusual folder)"""
    os.makedirs(os.path.dirname(USER_LIST), exist_ok=True)
    d = json.load(open(USER_LIST)) if os.path.exists(USER_LIST) else {}
    d[name if name not in d else f'{name}#{len(d)}'] = path
    json.dump(d, open(USER_LIST, 'w'), indent=1)
    return {'saved': USER_LIST, 'solvers': d}


# ====================================================================== result readers
def read_f06(path):
    """Nastran / MYSTRAN .f06: max displacement magnitude, natural frequencies, buckling eigenvalues, fatal messages"""
    txt = open(path, errors='replace').read()
    out = {}
    fatal = re.findall(r'\*\*\* USER FATAL MESSAGE[^\n]*\n[^\n]*', txt)
    if fatal:
        out['fatal'] = [f.strip() for f in fatal[:5]]
    dmax = 0.0
    # Nastran: 'D I S P L A C E M E N T   V E C T O R', rows '<grid> G T1 T2 T3 ...';
    # MYSTRAN: 'D I S P L A C E M E N T S', rows '<grid> <coord sys> T1 T2 T3 ...'
    for blk in re.split(r'D I S P L A C E M E N T   V E C T O R|D I S P L A C E M E N T S', txt)[1:]:
        seen = False
        for line in blk.splitlines()[1:]:
            p = line.split()
            if len(p) >= 8 and p[0].isdigit() and (p[1] == 'G' or p[1].isdigit()):
                try:
                    t = [float(x.replace('D', 'E')) for x in p[2:5]]
                except ValueError:
                    continue
                seen = True
                dmax = max(dmax, (t[0] ** 2 + t[1] ** 2 + t[2] ** 2) ** 0.5)
            elif seen and (line.startswith('1') or re.search(r'[A-Z] [A-Z] [A-Z]', line) or 'PAGE' in line):
                break
    if dmax:
        out['max_displacement'] = round(dmax, 6)
    m = re.search(r'R E A L   E I G E N V A L U E S(.*?)(?:\n1|\Z)', txt, re.S)
    if m:
        f, ev, started = [], [], False
        for line in m.group(1).splitlines():
            p = line.split()
            if len(p) >= 3 and p[0].isdigit() and p[1].isdigit():
                try:                                           # MODE, ORDER, EIGENVALUE[, RADIANS, CYCLES, ...]
                    ev.append(float(p[2].replace('D', 'E')))   # buckling: the eigenvalue IS the load factor
                    if len(p) >= 5:
                        f.append(float(p[4].replace('D', 'E')))
                    started = True
                except ValueError:
                    pass
            elif started and not line.strip():
                break                                          # end of the eigenvalue table (MYSTRAN goes on to vectors)
        if ev:
            out['eigenvalues'] = ev[:20]
        if f:
            out['eigen_column_cycles'] = f[:20]
    return out


# ====================================================================== run one solver
def _run(cmd, cwd, timeout, shell=False):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, shell=shell)
    return (r.stdout or '') + (r.stderr or ''), r.returncode


def run(model_file, solver, analysis='static', n_modes=10, solver_path=None, timeout=7200):
    """model_file: a ShipBrain .inp / .bdf (or anything FEModel reads). Writes the solver's input next to it, runs it in
    batch, returns the main results + plain English. solver: calculix | nastran | mystran | ansys | abaqus"""
    from .femodel import FEModel
    from . import solver as ccx_solver
    model_file = os.path.abspath(model_file)
    wd = os.path.dirname(model_file)
    base = os.path.splitext(model_file)[0] + f'_{solver}'
    path = solver_path or next((s['path'] for s in find() if s['solver'] == solver), None)
    if not path:
        raise RuntimeError(f'{solver} was not found on this PC: give its path once with remember_solver')
    if solver == 'calculix':
        os.environ['CCX'] = path
        inp = model_file if model_file.endswith('.inp') else FEModel.read(model_file).write(base + '.inp')
        r = ccx_solver.run_analysis(inp, analysis, n_modes)
        r['solver'] = 'calculix'
        return r
    m = FEModel.read(model_file)
    if solver in ('nastran', 'mystran'):
        bdf = base + '.bdf'
        m.write_bdf(bdf)
        txt = open(bdf).read()
        sol = {'static': 'SOL 101', 'modal': 'SOL 103', 'buckling': 'SOL 105'}[analysis]
        txt = txt.replace('SOL 101', sol, 1)
        if analysis == 'modal':
            txt = txt.replace('  SPC = 1', f'  SPC = 1\n  METHOD = 99', 1).replace('BEGIN BULK', 'BEGIN BULK', 1)
            txt = txt.replace('ENDDATA', f'EIGRL   99                      {int(n_modes):<8d}\nENDDATA')
            txt = re.sub(r'\n  LOAD = 1', '', txt)
        elif analysis == 'buckling':
            txt = txt.replace('SUBCASE 1', 'SUBCASE 1', 1).replace('  STRESS = ALL', '  STRESS = ALL\nSUBCASE 2\n  SPC = 1\n  METHOD = 99', 1)
            txt = txt.replace('ENDDATA', f'EIGRL   99                      {int(n_modes):<8d}\nENDDATA')
        open(bdf, 'w').write(txt)
        cmd = [path, os.path.basename(bdf)] + (['scr=yes', 'batch=no'] if solver == 'nastran' else [])
        log, rc = _run(cmd, wd, timeout)
        name = os.path.basename(base).lower() + '.f06'              # job.f06, JOB.F06 or job.F06 (MYSTRAN)
        f06 = next((os.path.join(wd, f) for f in os.listdir(wd) if f.lower() == name), base + '.f06')
        if not os.path.exists(f06):
            raise RuntimeError(f'{solver} wrote no .f06 (exit {rc}): ' + log[-600:])
        r = read_f06(f06)
        r.update(solver=solver, analysis=analysis, f06=os.path.basename(f06))
    elif solver == 'ansys':
        mac = base + '.mac'
        m.write_apdl(mac)
        txt = open(mac).read()
        res = os.path.basename(base) + '_result'
        if analysis == 'modal':
            solve = f'/SOLU\nANTYPE,MODAL\nMODOPT,LANB,{int(n_modes)}\nSOLVE\nFINISH\n'
            post = (f'/POST1\n*DIM,F,ARRAY,{int(n_modes)}\n*DO,I,1,{int(n_modes)}\n*GET,F(I),MODE,I,FREQ\n*ENDDO\n'
                    f"*CFOPEN,{res},txt\n*VWRITE,F(1)\n(E16.8)\n*CFCLOS\n")
        elif analysis == 'buckling':
            solve = ('/SOLU\nANTYPE,STATIC\nPSTRES,ON\nSOLVE\nFINISH\n/SOLU\nANTYPE,BUCKLE\n'
                     f'BUCOPT,LANB,{int(n_modes)}\nSOLVE\nFINISH\n')
            post = (f'/POST1\n*DIM,F,ARRAY,{int(n_modes)}\n*DO,I,1,{int(n_modes)}\n*GET,F(I),MODE,I,FREQ\n*ENDDO\n'
                    f"*CFOPEN,{res},txt\n*VWRITE,F(1)\n(E16.8)\n*CFCLOS\n")
        else:
            solve = '/SOLU\nANTYPE,STATIC\nSOLVE\nFINISH\n'
            post = (f'/POST1\nSET,LAST\nNSORT,U,SUM\n*GET,UMAX,SORT,,MAX\nNSORT,S,EQV\n*GET,SMAX,SORT,,MAX\n'
                    f"*CFOPEN,{res},txt\n*VWRITE,UMAX,SMAX\n(2E16.8)\n*CFCLOS\n")
        txt = txt.replace('FINISH\n/SOLU\nANTYPE,STATIC\nSOLVE\nFINISH', 'FINISH\n' + solve + post)
        open(mac, 'w').write(txt)
        log, rc = _run([path, '-b', '-i', os.path.basename(mac), '-o', os.path.basename(base) + '.out'], wd, timeout)
        rf = os.path.join(wd, res + '.txt')
        if not os.path.exists(rf):
            raise RuntimeError(f'ANSYS wrote no result file (exit {rc}); see {os.path.basename(base)}.out: ' + log[-400:])
        vals = [float(x) for x in open(rf).read().split()]
        r = {'solver': 'ansys', 'analysis': analysis}
        if analysis == 'static':
            r.update(max_displacement=vals[0], max_von_mises=vals[1])
        elif analysis == 'modal':
            r['frequencies_hz'] = vals
        else:
            r['load_factors'] = vals
    elif solver == 'abaqus':
        inp = base + '.inp'
        m.write_inp(inp)
        if analysis != 'static':
            from .solver import make_analysis
            inp = make_analysis(inp, analysis, n_modes, out=inp)
        job = os.path.basename(base)
        log, rc = _run(f'"{path}" job={job} input={os.path.basename(inp)} interactive ask_delete=OFF', wd, timeout, shell=True)
        x = os.path.join(wd, job + '_extract.py')
        open(x, 'w').write(ABAQUS_EXTRACT.format(job=job))
        log2, rc2 = _run(f'"{path}" python {os.path.basename(x)}', wd, 600, shell=True)
        rf = os.path.join(wd, job + '_result.json')
        if not os.path.exists(rf):
            raise RuntimeError(f'Abaqus results not read (exit {rc}/{rc2}): ' + (log + log2)[-500:])
        r = json.load(open(rf))
        r.update(solver='abaqus', analysis=analysis)
    else:
        raise ValueError(f'running {solver} is not automated yet; ShipBrain can guide the set-up')
    if 'frequencies_hz' not in r and analysis == 'modal' and 'eigen_column_cycles' in r:
        r['frequencies_hz'] = r.pop('eigen_column_cycles')
    if 'load_factors' not in r and analysis == 'buckling' and r.get('eigenvalues'):
        r['load_factors'] = r.pop('eigenvalues')
        r.pop('eigen_column_cycles', None)
    r['plain_english'] = _explain(r)
    return r


def _explain(r):
    s = r.get('solver', '')
    if r.get('fatal'):
        return f'{s} stopped with an error: ' + ' | '.join(r['fatal'])
    if r.get('frequencies_hz'):
        return f"{s}: natural frequencies " + ', '.join(f'{x:g} Hz' for x in r['frequencies_hz'][:6]) + '.'
    if r.get('load_factors'):
        return f"{s}: lowest buckling load factor {r['load_factors'][0]:g} (buckles at that multiple of the applied load)."
    if 'max_displacement' in r:
        return f"{s}: max displacement {r['max_displacement']:g}" + (f", max von Mises {r['max_von_mises']:g}" if 'max_von_mises' in r else '') + '.'
    return f'{s} finished; see its output files.'


ABAQUS_EXTRACT = '''# run with: abaqus python {job}_extract.py   (Abaqus' own Python; writes {job}_result.json)
from odbAccess import openOdb
import json, math
odb = openOdb('{job}.odb', readOnly=True)
out = {{}}
step = odb.steps.values()[-1]
fr = step.frames
if step.procedure.lower().startswith('*frequency') or 'freq' in step.procedure.lower():
    out['frequencies_hz'] = [f.frequency for f in fr[1:]]
elif 'buckle' in step.procedure.lower():
    out['load_factors'] = [float(f.description.split('=')[-1]) for f in fr[1:]]
else:
    u = fr[-1].fieldOutputs['U'].values
    out['max_displacement'] = max(math.sqrt(sum(c * c for c in v.data[:3])) for v in u)
    if 'S' in fr[-1].fieldOutputs.keys():
        out['max_von_mises'] = max(v.mises for v in fr[-1].fieldOutputs['S'].values)
json.dump(out, open('{job}_result.json', 'w'))
odb.close()
'''


if __name__ == '__main__':
    if '--check' in sys.argv:
        for s in find():
            print(f"{s['solver']:10s} {s['path']}  ({s['found_by']}; adapter {'tested' if s['tested_adapter'] else 'NOT yet tested here'})")
        if not find():
            print('no solvers found; add one: python -c "from shipbrain.solvers import remember; remember(\'ansys\', r\'C:\\\\path\\\\ANSYS241.exe\')"')
