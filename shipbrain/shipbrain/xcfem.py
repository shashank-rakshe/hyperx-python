"""
XC (https://github.com/xcfem/xc, GPL-3, Luis C. Perez Tato and contributors): open source finite element analysis with structural
code checking - reinforced concrete (Eurocode 2, ACI 318, EHE, SIA 262), steel (Eurocode 3, AISC 360, EAE, SIA 263), fibre sections,
linear and non-linear static and dynamic analysis, construction phases. The whole repository is in the knowledge pack `xc` (library
source, Python modules, the verification examples that are worked models); ShipBrain does not copy the program (C++ with many
dependencies) but RUNS the user's installation of it:

  * a local XC install (Python can `import xc_base`; interpreter from XC_PYTHON if set), or
  * the Docker image engthiago/xcfem (the one the XC project documents), the work folder mounted at /home/ubuntu.

How an assessment uses it: the model finds the closest worked example in the pack (knowledge_search), writes an XC Python script for the
user's structure, calls xc_run, and reports the results the script printed or wrote (CSV / JSON / text) in plain words. Nothing here
fabricates results: the script's own output is what comes back.
"""
import os, re, shutil, subprocess, sys, time

IMAGE = 'engthiago/xcfem'


def _local_python():
    for c in (os.environ.get('XC_PYTHON'), shutil.which('python3'), sys.executable):
        if not c:
            continue
        try:
            if subprocess.run([c, '-c', 'import xc_base'], capture_output=True, timeout=60).returncode == 0:
                return c
        except Exception:
            pass
    return None


def exe():
    """['python'] for a local XC, [docker, image] for the Docker image, None when neither is there"""
    p = _local_python()
    if p:
        return [p]
    d = shutil.which('docker')
    if d and os.environ.get('SHIPBRAIN_XC_DOCKER', '1') != '0':
        try:
            if subprocess.run([d, 'image', 'inspect', IMAGE], capture_output=True, timeout=30).returncode == 0:
                return [d, IMAGE]
        except Exception:
            pass
    return None


def _need():
    x = exe()
    if not x:
        raise RuntimeError('XC is not installed: easiest is Docker - docker pull engthiago/xcfem (the image the XC project documents); '
                           'or the native build: https://github.com/xcfem/xc/blob/master/install/install.md (Linux).')
    return x


def run(script, workdir, name='xc_model', timeout=3600):
    """write the XC Python script into the work folder and run it; returns the exit code, the output and the files it made"""
    name = re.sub(r'[^A-Za-z0-9_\-]', '_', name)[:40] or 'xc_model'
    if not isinstance(script, str) or 'import' not in script:
        raise ValueError('script must be the Python text of an XC model (it starts with imports such as "import xc", "from model import predefined_spaces")')
    os.makedirs(workdir, exist_ok=True)
    path = os.path.join(workdir, name + '.py')
    open(path, 'w').write(script)
    before = {f: os.path.getmtime(os.path.join(workdir, f)) for f in os.listdir(workdir)}
    x = _need()
    if len(x) == 2:                                                  # docker
        cmd = [x[0], 'run', '--rm', '-v', f'{os.path.abspath(workdir)}:/home/ubuntu', '-w', '/home/ubuntu', x[1], 'python3', name + '.py']
    else:
        cmd = [x[0], name + '.py']
    t = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=workdir)
    out = (p.stdout or '') + (p.stderr or '')
    made = sorted(f for f in os.listdir(workdir) if f != name + '.py' and (f not in before or os.path.getmtime(os.path.join(workdir, f)) > before[f]))
    res = {'exit_code': p.returncode, 'seconds': round(time.time() - t, 1), 'output': out[-4000:], 'files': made[:40], 'script': name + '.py'}
    if p.returncode:
        err = [l for l in out.splitlines() if l.strip()][-6:]
        res['error'] = 'the XC script failed: ' + ' | '.join(err)
    else:
        res['plain_english'] = (f"XC ran {name}.py in {res['seconds']} s" + (f" and wrote {', '.join(made[:6])}" if made else '') +
                                '. What the script printed:\n' + out[-1500:].strip())
    return res
