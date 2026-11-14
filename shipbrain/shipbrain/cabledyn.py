"""
CableDyn (https://github.com/SMI-Lab-Inha/CableDyn, Apache-2.0, copied as written in vendor/cabledyn; J. H. Seo et al.,
Ocean Engineering 368 (2026) 128332): geometrically exact finite-element analysis of mooring lines and dynamic power
cables - statics from the geometry alone, implicit dynamics (waves, current, vessel motion), bending stiffness, bend
stiffeners, torsion, seabed contact and friction, natural modes, VIV, fibre ropes; reads MoorDyn v2 decks; couples with
OpenFAST (CompMooring = 5). Its own validation: OrcaFlex 11.6d within 0.06-0.6 % on lazy-wave curvature and tension.

ShipBrain uses:
  driver()          its program: CABLEDYN_DRIVER, PATH, ~/.shipbrain/bin, the pip package `cabledyn` (wheels carry the
                    driver), else build() compiles the vendored source (gfortran + LAPACK + CMake, about 5 minutes)
  run(deck)         any CableDyn / MoorDyn v2 deck -> fairlead / anchor tensions, inclinations, the static profile
  chain(d, grade)   studless / studlink chain properties (mass, EA, hydrodynamic diameter, MBL to DNV-OS-E302)
  mooring(...)      a single catenary line from plain numbers (depth, length, anchor radius, chain size / grade), solved,
                    with the touchdown point, grounded length and the tension check to API RP 2SK (CableDyn's factors)
Units: SI (m, kg, N). Chain diameter d is the nominal bar diameter in mm.
"""
import glob, math, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'cabledyn', 'repo')
HOME_BIN = os.path.join(os.path.expanduser('~'), '.shipbrain', 'bin')

# MBL factor c in MBL = c * d^2 * (44 - 0.08 d) kN, d in mm (DNV-OS-E302 / API Spec 2F chain grades)
GRADE_MBL = {'R3': 0.0223, 'R3S': 0.0249, 'R4': 0.0274, 'R4S': 0.0304, 'R5': 0.0320}


def _pkg():
    """CableDyn's own Python package, as written (vendored)"""
    p = os.path.join(ROOT, 'python')
    if p not in sys.path:
        sys.path.insert(0, p)
    import cabledyn as cd
    return cd


def driver():
    for c in [os.environ.get('CABLEDYN_DRIVER'), shutil.which('cabledyn'), shutil.which('CableDyn_driver'),
              shutil.which('CableDyn_driver.exe'), os.path.join(HOME_BIN, 'cabledyn'), os.path.join(HOME_BIN, 'cabledyn.exe'),
              os.path.join(HOME_BIN, 'CableDyn_driver.exe')]:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    try:                                                   # pip install cabledyn: the wheel carries the driver
        import importlib.util
        spec = importlib.util.find_spec('cabledyn')
        if spec and spec.origin and os.path.join('vendor', 'cabledyn') not in spec.origin:
            from cabledyn.driver import bundled_driver
            b = bundled_driver()
            if b and os.path.exists(b):
                return str(b)
    except Exception:
        pass
    return None


def build(jobs=2):
    """compile the vendored source into ~/.shipbrain/bin/cabledyn (needs gfortran, LAPACK, CMake)"""
    for tool in ('cmake', 'gfortran'):
        if not shutil.which(tool):
            raise RuntimeError('CableDyn is not installed: pip install "cabledyn[post]" (carries the solver), or the Windows '
                               'driver from https://github.com/SMI-Lab-Inha/CableDyn/releases/latest ; building it needs '
                               f'{tool} (and LAPACK).')
    b = os.path.join(os.path.expanduser('~'), '.shipbrain', 'cabledyn-build')
    gen = ['-G', 'Ninja'] if shutil.which('ninja') else []
    subprocess.run(['cmake', '-S', ROOT, '-B', b, '-DCMAKE_BUILD_TYPE=Release'] + gen, check=True, capture_output=True)
    subprocess.run(['cmake', '--build', b, '--target', 'cabledyn', '-j', str(jobs)], check=True, capture_output=True)
    os.makedirs(HOME_BIN, exist_ok=True)
    exe = next((p for p in (os.path.join(b, 'cabledyn'), os.path.join(b, 'bin', 'cabledyn.exe')) if os.path.exists(p)), None)
    if not exe:
        raise RuntimeError('CableDyn build finished without the cabledyn program')
    dst = os.path.join(HOME_BIN, os.path.basename(exe))
    shutil.copy2(exe, dst)
    for so in glob.glob(os.path.join(b, 'libcabledyn.so*')):
        shutil.copy2(so, HOME_BIN)
    return dst


def _need():
    x = driver()
    if not x:
        raise RuntimeError('CableDyn is not installed: pip install "cabledyn[post]" (carries the solver), or the Windows '
                           'driver CableDyn_driver.exe from https://github.com/SMI-Lab-Inha/CableDyn/releases/latest '
                           '(or build it: python -c "from shipbrain import cabledyn; cabledyn.build()").')
    return x


# ====================================================================== line properties
def chain(d_mm, grade='R3', kind='studless'):
    """chain line type from the nominal diameter (standard equivalent properties used in mooring software)"""
    d = float(d_mm) / 1000.0
    g = str(grade).upper()
    if g not in GRADE_MBL:
        raise ValueError(f'grade: {", ".join(GRADE_MBL)}')
    if kind == 'studless':
        mass, EA, dh = 19.9e3 * d * d, 0.854e11 * d * d, 1.8 * d     # kg/m, N, m
    elif kind == 'studlink':
        mass, EA, dh = 21.9e3 * d * d, 1.01e11 * d * d, 1.89 * d
    else:
        raise ValueError('kind: studless | studlink')
    mbl = GRADE_MBL[g] * d_mm ** 2 * (44 - 0.08 * d_mm) * 1000.0     # N
    return {'name': f'chain{int(round(d_mm))}{g}', 'kind': kind, 'grade': g, 'd_mm': d_mm, 'diam_m': round(dh, 5),
            'mass_kg_m': round(mass, 3), 'EA_N': EA, 'MBL_N': mbl, 'Cd_n': 1.37 if kind == 'studless' else 1.2,
            'Cd_t': 0.64 if kind == 'studless' else 0.4, 'Ca_n': 1.0, 'Ca_t': 0.0 if kind == 'studless' else 0.5}


# ====================================================================== decks and runs
def _deck(lt, depth, length, radius, fairlead_z=0.0, nseg=None, current=None, title='ShipBrain mooring line'):
    nseg = nseg or max(20, min(200, int(round(length / 10.0))))
    cur = 'none      current           - Current model and velocity (m/s) {none; uniform; profile}'
    if current:
        cur = (f'uniform {float(current):g} 0 0      current           - Current model and velocity (m/s) {{none; uniform; profile}}\n'
               '0.05         dtM       - CableDyn internal time step (s)\n'
               '0.0          TMax      - Standalone simulation duration (s); 0 selects static initialisation only')
    return f"""--------------------- CableDyn Input File ------------------------------------
{title}
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam    MassDenInAir   EA        BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)     (kg/m)         (N)       (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
{lt['name']}   {lt['diam_m']:.5g}   {lt['mass_kg_m']:.6g}   {lt['EA_N']:.6g}   -1.0   0.0   {lt['Cd_n']}  {lt['Cd_t']}  {lt['Ca_n']}  {lt['Ca_t']}
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
1     Fixed     {radius:.6g}    0.0    {-depth:.6g}     0       0       0      0
2     Coupled   0.0      0.0    {fairlead_z:.6g}       0       0       0      0
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
1     2       1       p
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
1        {lt['name']}    {length:.6g}    {nseg}
--------------------- OPTIONS ------------------------------------------
9.80665      g         - Gravitational acceleration (m/s^2)
1025.0       rhoW      - Water density (kg/m^3)
{depth:.6g}       WtrDpth   - Water depth (m)
1.0e5        kBot      - Seabed penalty stiffness base (Pa/m)
1.0e4    cBot              - Seabed normal damping base (Pa-s/m)
{cur}
none      waves             - Wave model
--------------------- OUTPUTS ------------------------------------------
"FairTen1"
"AnchTen1"
"FairIncl1"
"AnchIncl1"
--------------------- need this line -----------------------------------
"""


def _table(path):
    rows, head = [], None
    for line in open(path, encoding='utf-8', errors='replace'):
        if line.startswith('#') or not line.strip():
            continue
        parts = line.split('\t') if '\t' in line else line.split()
        parts = [p.strip() for p in parts if p.strip()]
        if head is None:
            if '\t' not in line:                              # a title line before the column names
                continue
            head = parts
            continue
        if parts and parts[0].startswith('('):
            continue
        try:
            rows.append([float(p) for p in parts])
        except ValueError:
            continue
    return head or [], rows


def run(deck, root=None, timeout=1800):
    """run a deck; returns the output channels (last row and maxima), the static profile and the solver log"""
    deck = os.path.abspath(deck)
    root = root or os.path.splitext(os.path.basename(deck))[0]
    p = subprocess.run([_need(), deck, root], capture_output=True, text=True, timeout=timeout, cwd=os.path.dirname(deck))
    log = (p.stdout + p.stderr)
    base = os.path.join(os.path.dirname(deck), root)
    if p.returncode != 0 or not os.path.exists(base + '.out'):
        reason = [l.strip() for l in log.splitlines() if re.search(r'error|fail|stop|cannot|no equilibrium', l, re.I)]
        raise RuntimeError('CableDyn stopped: ' + ('; '.join(reason[-4:]) or log[-1500:]))
    head, rows = _table(base + '.out')
    out = {'out': base + '.out', 'channels': head, 'steps': len(rows), 'log': log[-3000:]}
    if rows:
        out['last'] = dict(zip(head, rows[-1]))
        if len(rows) > 1:
            out['max'] = {h: max(r[i] for r in rows) for i, h in enumerate(head) if i}
            out['min'] = {h: min(r[i] for r in rows) for i, h in enumerate(head) if i}
    if os.path.exists(base + '.static.out'):
        h, prof = _table(base + '.static.out')
        out['static_profile'] = {'columns': h, 'rows': prof}
        out['static_file'] = base + '.static.out'
    return out


def mooring(depth, length, radius, d_mm=None, grade='R3', kind='studless', line=None, fairlead_z=0.0, current=None,
            condition='intact', analysis='quasi-static', workdir='.', name='mooring'):
    """one catenary mooring line from plain numbers, solved by CableDyn, with the API RP 2SK tension check"""
    lt = line or chain(d_mm or 84, grade, kind)
    span = math.hypot(float(radius), float(depth) + float(fairlead_z))
    if float(length) < span:
        raise ValueError(f'the line ({length:g} m) is shorter than the straight distance from fairlead to anchor ({span:.0f} m): '
                         'it would have to stretch. Use a longer line or move the anchor in.')
    os.makedirs(workdir, exist_ok=True)
    deck = os.path.join(workdir, f'{name}.dat')
    open(deck, 'w').write(_deck(lt, float(depth), float(length), float(radius), float(fairlead_z), current=current,
                                title=f'ShipBrain: {lt["name"]} line, depth {depth} m, length {length} m, anchor radius {radius} m'))
    r = run(deck, name)
    last = r.get('last', {})
    Tf, Ta = last.get('FairTen1'), last.get('AnchTen1')
    incl = last.get('FairIncl1')
    td = grounded = None
    prof = (r.get('static_profile') or {}).get('rows') or []
    pts = []                                               # (arc length from the fairlead, z) per node
    if prof:
        cols = r['static_profile']['columns']
        iz, ia = cols.index('Z'), cols.index('ArcLength')
        pts = [(row[ia], row[iz]) for row in prof]
    elif os.path.exists(os.path.join(workdir, f'{name}.Line1.p.out')):   # dynamic route (current): node positions
        h, rows = _table(os.path.join(workdir, f'{name}.Line1.p.out'))
        if rows:
            last = rows[-1][1:]
            xyz = [last[i:i + 3] for i in range(0, len(last) - 2, 3)]
            arc = 0.0
            for i, q in enumerate(xyz):
                if i:
                    arc += math.dist(q, xyz[i - 1])
                pts.append((arc, q[2]))
    on = [a for a, z in pts if z <= -float(depth) + 0.05 * lt['diam_m'] + 0.01]
    if on:
        td = on[0]
        grounded = float(length) - td
    SF = _pkg().API_RP_2SK_SAFETY_FACTORS[(condition, analysis)]
    util = Tf * SF / lt['MBL_N'] if Tf else None
    res = {'deck': deck, 'line': lt, 'fairlead_tension_kN': round(Tf / 1e3, 1) if Tf else None,
           'anchor_tension_kN': round(Ta / 1e3, 1) if Ta else None, 'fairlead_inclination_deg': round(incl, 2) if incl else None,
           'touchdown_arc_m': round(td, 1) if td is not None else None, 'grounded_length_m': round(grounded, 1) if grounded else 0.0,
           'MBL_kN': round(lt['MBL_N'] / 1e3), 'safety_factor': SF, 'utilisation': round(util, 3) if util else None,
           'ok': util is not None and util <= 1.0, 'run': {k: v for k, v in r.items() if k != 'static_profile'}}
    pe = (f"CableDyn solved the {lt['d_mm']:g} mm {lt['grade']} {lt['kind']} chain ({lt['mass_kg_m']:.0f} kg/m in air) in "
          f"{depth:g} m of water, {length:g} m long, anchor at {radius:g} m: fairlead tension {Tf / 1e3:,.0f} kN at "
          f"{incl:.1f} deg below horizontal, anchor tension {Ta / 1e3:,.0f} kN"
          + (f"; it touches the seabed {td:.0f} m from the fairlead and {grounded:.0f} m lies on the bottom" if grounded and grounded > 0.5
             else ('; NO chain lies on the seabed (the anchor is pulled upward - lengthen the line or move the anchor out)' if pts
                   else '; the touchdown point was not reported by this run'))
          + f". Breaking load {lt['MBL_N'] / 1e3:,.0f} kN; API RP 2SK {condition} {analysis} needs a factor of safety of {SF:g}, so "
          f"the utilisation is {util:.2f} - {'OK' if util <= 1 else 'NOT OK'}.")
    if current:
        pe += f' (Uniform current {current:g} m/s included.)'
    res['plain_english'] = pe + ' (Static equilibrium; run the dynamics with waves and vessel motion for the design tension.)'
    return res
