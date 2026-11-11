"""
The BREP kernel family of next.BREP.io (https://github.com/mmiscool/next.BREP.io_RUST_BREP_KERNEL, Rust), copied whole and
used UNCHANGED (its licence is MIT wording with extra conditions on modifications: ShipBrain never modifies it).

  stl2step   triangle mesh (STL) -> exact STEP solid: planes, cylinders, cones, spheres and tori recognised (RANSAC),
             the rest kept as facets; one solid per closed shell. Checked: a filleted plate with holes comes back with
             its 6 planes + 6 cylinders and the same volume (0.2 s).
  build()    cargo build --release -p BREP_STL2STEP (Rust from rustup.rs; the pinned toolchain installs itself; ~5 min
             once, Windows / Linux / macOS). Build output goes to ~/.cache/shipbrain/brep-target, not into the copy.
"""
import os, shutil, subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'BREP', 'repo')
TARGET = os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'brep-target')
EXE = os.path.join(TARGET, 'release', 'stl2step' + ('.exe' if os.name == 'nt' else ''))


def available():
    return os.path.isdir(ROOT)


def built():
    return os.path.exists(EXE)


def build():
    if not shutil.which('cargo'):
        raise RuntimeError('Rust is needed to build stl2step once: install it from https://rustup.rs, then run '
                           'python -c "from shipbrain import brep; brep.build()"')
    r = subprocess.run(['cargo', 'build', '--release', '-p', 'BREP_STL2STEP', '--target-dir', TARGET], cwd=ROOT,
                       capture_output=True, text=True, timeout=7200)
    if r.returncode or not built():
        raise RuntimeError('stl2step build failed: ' + (r.stderr or r.stdout)[-1500:])
    return EXE


def stl_to_step(stl, out=None, unit='mm', force=True):
    """-> (step path, its report text). unit: mm | cm | m | inch | foot | micron"""
    if not built():
        build()
    stl = os.path.abspath(stl)
    cmd = [EXE, stl, '--unit', unit] + (['--force'] if force else [])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    step = os.path.splitext(stl)[0] + '.step'
    if r.returncode or not os.path.exists(step):
        raise RuntimeError('stl2step failed: ' + (r.stderr or r.stdout).strip()[-1200:])
    if out and os.path.abspath(out) != step:
        shutil.move(step, out)
        step = out
    return step, (r.stdout + r.stderr).strip()
