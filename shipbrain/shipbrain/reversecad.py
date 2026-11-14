"""
ReverseCAD (https://github.com/grizlizora/reverse-cad, PolyForm Noncommercial 1.0.0 - used because ShipBrain is declared
non-commercial, see licence_mode.json), copied whole into vendor/reverse-cad/repo and run as written with Node.js.

Mesh (STL: scans, 3D-print files, mesh exports) -> STEP AP242 solid + engineering features, in seconds:
  STEP        one watertight B-Rep solid (planes / cylinders fitted; adaptive faceted where it cannot fit)
  summary     volume, area, centre of mass, inertia, mass for a material, holes, threads (ISO M2-M24),
              fillets, chamfers, slots, cavities, wall thickness, 3D-print advice
  report      its RSVS verification: watertight intake, surface coverage, coaxiality, B-Rep check, Hausdorff
              distance between the STEP and the STL (pass / fail)
  heatmap     a .glb picture of the deviation (optional)
Its MCP server (node dist/cli.js --mcp) has cad_analyze_stl, cad_detect_threads, cad_verify_rsvs, cad_convert_to_step;
ShipBrain lists it as the built-in MCP server "reverse-cad".

First use: copies the repo to ~/.shipbrain/reverse-cad, runs `npm install` and the TypeScript compiler (needs Node.js 20+
and internet once). Feature recognition is a guess from the mesh: the answers say so (a plain hole can be read as a
tapped hole, a sharp edge as a small chamfer).
"""
import json, os, shutil, subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'reverse-cad', 'repo')
BUILD = os.path.join(os.path.expanduser('~'), '.shipbrain', 'reverse-cad')
MATERIALS = ('steel', 'aluminum', 'pla', 'petg', 'abs', 'glass')


def available():
    return os.path.isdir(ROOT)


def node():
    return shutil.which('node') or shutil.which('node.exe')


def cli():
    """path of its built command-line program (builds it on first use)"""
    js = os.path.join(BUILD, 'dist', 'cli.js')
    if os.path.exists(js):
        return js
    if not node():
        raise RuntimeError('ReverseCAD needs Node.js 20+ (free: https://nodejs.org/en/download ).')
    npm = shutil.which('npm') or shutil.which('npm.cmd')
    if not npm:
        raise RuntimeError('ReverseCAD needs npm, which comes with Node.js (https://nodejs.org/en/download ).')
    if not os.path.isdir(BUILD):
        shutil.copytree(ROOT, BUILD)
    subprocess.run([npm, 'install', '--no-audit', '--no-fund'], cwd=BUILD, check=True, capture_output=True, timeout=900)
    tsc = os.path.join(BUILD, 'node_modules', '.bin', 'tsc' + ('.cmd' if os.name == 'nt' else ''))
    subprocess.run([tsc] if os.path.exists(tsc) else [npm, 'exec', 'tsc'], cwd=BUILD, check=True, capture_output=True,
                   timeout=900)
    if not os.path.exists(js):
        raise RuntimeError('ReverseCAD build did not produce dist/cli.js')
    return js


def mcp_command():
    return [node() or 'node', '--expose-gc', cli(), '--mcp']


def _features_text(fe):
    bits = []
    holes = fe.get('holes') or []
    if holes:
        ds = sorted({h.get('diameterMm') for h in holes if h.get('diameterMm')})
        bits.append(f"{len(holes)} hole(s) (diameter {', '.join(f'{d:g}' for d in ds)} mm)")
    th = fe.get('threads') or []
    if th:
        bits.append('threads ' + ', '.join(sorted({t.get('spec', '?') for t in th})))
    fl = fe.get('fillets') or []
    if fl:
        rs = sorted({round(f.get('radiusMm', 0)) for f in fl})
        bits.append(f"{len(fl)} fillet(s) of about R{'/'.join(map(str, rs))} mm")
    for k, w in (('chamfers', 'chamfer'), ('slots', 'slot / notch'), ('cavities', 'internal cavity'), ('patterns', 'pattern')):
        if fe.get(k):
            bits.append(f"{len(fe[k])} {w}(s)")
    return bits


def convert(stl, out_dir, emit='step,summary,report', material=None, thread_mode=None, quality=None, timeout=900):
    """STL -> STEP + features + verification, all files in out_dir; returns the parsed results and a plain answer"""
    stl = os.path.abspath(stl)
    if not os.path.exists(stl):
        raise FileNotFoundError(stl)
    os.makedirs(out_dir, exist_ok=True)
    cmd = [node() or 'node', '--max-old-space-size=4096', '--expose-gc', cli(), stl, '-y', '-o', os.path.abspath(out_dir),
           '--emit', emit]
    if material:
        m = str(material).lower().replace('aluminium', 'aluminum')
        if m not in MATERIALS:
            raise ValueError(f'material: one of {", ".join(MATERIALS)}')
        cmd += ['-m', m]
    if thread_mode:
        cmd += ['--thread-mode', thread_mode]
    if quality:
        cmd += ['-q', quality]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    base = os.path.splitext(os.path.basename(stl))[0]
    f = {k: os.path.join(out_dir, base + ext) for k, ext in (
        ('step', '.step'), ('summary', '.cad_features.summary.json'), ('report', '.verification_report.json'),
        ('topology', '.cad_features.topology.json'), ('heatmap', '.heatmap.glb'))}
    files = {k: v for k, v in f.items() if os.path.exists(v)}
    if 'step' not in files and 'summary' not in files:
        raise RuntimeError('ReverseCAD did not convert the file: ' + (p.stderr or p.stdout)[-1200:])
    out = {'files': files}
    s = json.load(open(files['summary'])) if 'summary' in files else {}
    r = json.load(open(files['report'])) if 'report' in files else {}
    if s:
        mp = s.get('massProperties') or {}
        out['summary'] = {k: s.get(k) for k in ('boundingDimensionsMm', 'totalVolumeMm3', 'totalSurfaceAreaMm2', 'isWatertight',
                                                 'solidBodiesCount', 'cavitiesCount')}
        out['summary'].update(centre_of_mass=mp.get('centerOfMass'), inertia=mp.get('momentsOfInertia'),
                              min_wall_mm=mp.get('estimatedMinWallThicknessMm'),
                              mass_g=(s.get('materialsSummary') or {}).get('totalMassGrams'),
                              material=', '.join(sorted({e.get('materialName', '') for e in (s.get('materialsSummary') or {}).get('elements', [])})))
        out['features'] = s.get('engineeringFeatures') or {}
    if r:
        out['verification'] = {'overall': r.get('overallStatus'),
                               'gates': {k: g.get('status') for k, g in (r.get('gates') or {}).items() if isinstance(g, dict)}}
    sm = out.get('summary') or {}
    dims = sm.get('boundingDimensionsMm') or []
    pe = [f"Converted {os.path.basename(stl)} to a STEP solid ({os.path.basename(files['step'])})" if 'step' in files else
          f"Read {os.path.basename(stl)}"]
    if dims:
        pe[0] += (f": size {' x '.join(f'{d:g}' for d in dims)} mm, volume {sm.get('totalVolumeMm3', 0):,.0f} mm3, "
                  f"{'watertight' if sm.get('isWatertight') else 'NOT watertight'}, {sm.get('solidBodiesCount', 1)} body(ies)")
        if not material:
            pe[0] += ' (mass not given: no material was named)'
        elif sm.get('mass_g'):
            pe[0] += f", mass {sm['mass_g']:,.0f} g as {sm.get('material')}"
    pe[0] += '.'
    fb = _features_text(out.get('features') or {})
    if fb:
        pe.append('Features it recognised from the mesh (a guess - check them on the part): ' + '; '.join(fb) + '.')
    v = out.get('verification')
    if v:
        failed = [k for k, st in v['gates'].items() if st not in ('PASSED', 'SKIPPED')]
        pe.append(f"Its own verification (STEP against the mesh): {v['overall']}" +
                  (f", gates not passed: {', '.join(failed)}" if failed else '') + '.')
    pe.append('(ReverseCAD, PolyForm Noncommercial licence: non-commercial use only.)')
    out['plain_english'] = ' '.join(pe)
    if not material and out.get('summary'):
        out['summary'].pop('mass_g', None)
        out['summary'].pop('material', None)
    return out
