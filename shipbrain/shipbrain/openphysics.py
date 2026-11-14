"""
OpenPhysicsAI (https://github.com/molanocortes/OpenPhysicsAI, Apache-2.0), copied whole into shipbrain/vendor and used as
written: more than twenty physics solvers in C (flow up to hypersonic shocks, heat, fire, water, sound, radar,
magnetics, fracture, impact, gears and mechanisms, metal / plastic 3D printing, topology optimisation), each checked
against a closed form or a measurement.

  build()            compile it once (C compiler + make; about 30 s on Linux; macOS too; on Windows use WSL)
  scenarios()        the example scenarios (domain, title)
  run(scenario)      a scenario (example name, a file or a JSON dict) through its own lab runner -> its JSON record
  server_command()   its MCP server (88 operations) - ShipBrain talks to it with shipbrain.mcp_client
"""
import glob, json, os, shutil, subprocess, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'OpenPhysicsAI', 'repo')
LABRUN = os.path.join(ROOT, 'build', 'labrun')
MCP = os.path.join(ROOT, 'openphysics-mcp')


def available():
    return os.path.isdir(ROOT)


def built():
    return os.path.exists(LABRUN) and os.path.exists(MCP)


def build(log=print):
    """make (servers, solvers) + make lab (lab runner, film, probe) in the copied repo"""
    if not available():
        raise RuntimeError('OpenPhysicsAI is not in shipbrain/vendor')
    if os.name == 'nt':
        raise RuntimeError('OpenPhysicsAI builds on Linux and macOS; on Windows run ShipBrain inside WSL (Ubuntu) for it')
    if not shutil.which('make') or not (shutil.which('clang') or shutil.which('gcc') or shutil.which('cc')):
        raise RuntimeError('a C compiler and make are needed: Linux `sudo apt install clang make`, macOS `xcode-select --install`')
    jobs = str(os.cpu_count() or 4)
    cc = [] if shutil.which('clang') else ['CC=' + ('gcc' if shutil.which('gcc') else 'cc')]   # its Makefile asks for clang
    for target in ([], ['lab']):
        r = subprocess.run(['make', '-j', jobs] + cc + target, cwd=ROOT, capture_output=True, text=True, timeout=3600)
        if r.returncode:
            raise RuntimeError('OpenPhysicsAI build failed: ' + (r.stderr or r.stdout)[-1500:])
    log and log('OpenPhysicsAI built')
    return built()


def ensure():
    if not built():
        build(log=None)


def scenarios(query=None):
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, 'examples', 'lab', '*.json'))):
        try:
            d = json.load(open(p, encoding='utf-8'))
        except Exception:
            continue
        item = {'name': os.path.splitext(os.path.basename(p))[0], 'domain': d.get('domain', '?'), 'title': d.get('title', '')}
        if not query or any(w in (item['name'] + ' ' + item['domain'] + ' ' + item['title']).lower() for w in query.lower().split()):
            out.append(item)
    return out


def scenario(name):
    p = os.path.join(ROOT, 'examples', 'lab', os.path.basename(name).replace('.json', '') + '.json')
    if not os.path.exists(p):
        raise ValueError(f'no example scenario {name}; see physics_lab action list')
    return json.load(open(p, encoding='utf-8'))


def _merge(base, changes):
    for k, v in (changes or {}).items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _merge(base[k], v)
        else:
            base[k] = v
    return base


def run(spec, changes=None, out_dir=None, timeout=3600):
    """spec: example name, path of a scenario JSON, or the scenario dict; changes: nested values to override"""
    ensure()
    if isinstance(spec, dict):
        sc = dict(spec)
    elif os.path.exists(str(spec)):
        sc = json.load(open(spec, encoding='utf-8'))
    else:
        sc = scenario(spec)
    sc = _merge(sc, changes)
    out_dir = out_dir or tempfile.mkdtemp(prefix='physics_')
    os.makedirs(out_dir, exist_ok=True)
    name = (os.path.splitext(os.path.basename(spec))[0] if isinstance(spec, str) else 'scenario').replace(' ', '_')
    sp, lab = os.path.join(out_dir, name + '.json'), os.path.join(out_dir, name + '.lab')
    json.dump(sc, open(sp, 'w', encoding='utf-8'), indent=1)
    r = subprocess.run([LABRUN, sp, lab], capture_output=True, text=True, timeout=timeout, cwd=ROOT)
    rec = None
    for line in reversed(r.stdout.strip().splitlines()):
        if line.startswith('{'):
            try:
                rec = json.loads(line)
                break
            except ValueError:
                pass
    if r.returncode or rec is None:
        raise RuntimeError('the physics lab refused or failed: ' + (r.stderr or r.stdout).strip()[-1200:])
    rec['report'] = r.stderr.strip()[-3000:]                 # its own plain-text summary (gauges, checks)
    rec['scenario_file'] = sp
    return rec


def server_command():
    ensure()
    return [MCP, '--lab', ROOT]
