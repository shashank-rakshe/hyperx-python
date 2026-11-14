"""
MYSTRAN (https://github.com/MystranSolver/MYSTRANSolver, MIT): a free Nastran-compatible linear FE solver (static
SOL 101, natural frequencies SOL 103, buckling SOL 105) that reads the .bdf files ShipBrain writes. The source is copied
whole into shipbrain/vendor/MYSTRAN; ShipBrain runs it through shipbrain.solvers (`solve` tool, solver "mystran").

  Windows: download the ready mystran.exe from the MYSTRAN releases and tell ShipBrain once where it is
           (remember_solver), or put it on PATH.
  Linux / macOS / WSL: build() compiles it (gfortran + cmake + ninja; its SuperLU / METIS / LAPACK submodules are fetched
           by git): ~10 min once, into ~/.cache/shipbrain/mystran.
Checked (same 2 x 0.8 m and 2 x 1 m plates as CalculiX): pressure deflection 12.50 mm (CalculiX 12.40), first natural
frequency 44.06 Hz (hand 44.14, CalculiX 44.24), buckling factor 7.415 (hand 7.447, CalculiX 7.492).
"""
import os, shutil, subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'MYSTRAN', 'repo')
BUILD = os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'mystran')
EXE = os.path.join(BUILD, 'Binaries', 'mystran' + ('.exe' if os.name == 'nt' else ''))
URL = 'https://github.com/MystranSolver/MYSTRANSolver'


def built():
    return os.path.exists(EXE)


def build():
    """clone the same project with its submodules into the cache and compile it (the copy in vendor/ stays unchanged)"""
    for tool in ('git', 'cmake', 'gfortran'):
        if not shutil.which(tool):
            raise RuntimeError(f'{tool} is needed to build MYSTRAN (Linux: sudo apt install gfortran cmake ninja-build git); '
                               'on Windows use the ready mystran.exe from the MYSTRAN releases')
    if not os.path.isdir(os.path.join(BUILD, 'Source')):
        shutil.rmtree(BUILD, ignore_errors=True)
        subprocess.run(['git', 'clone', '-q', '--depth', '1', URL, BUILD], check=True, timeout=1800)
    subprocess.run(['git', 'submodule', 'update', '--init', '--depth', '1'], cwd=BUILD, check=True, timeout=1800)
    gen = ['-G', 'Ninja'] if shutil.which('ninja') else []
    subprocess.run(['cmake'] + gen + ['.'], cwd=BUILD, check=True, capture_output=True, timeout=1800)
    r = subprocess.run(['cmake', '--build', '.', '-j', str(os.cpu_count() or 4)], cwd=BUILD, capture_output=True, text=True, timeout=7200)
    if r.returncode or not built():
        raise RuntimeError('MYSTRAN build failed: ' + (r.stderr or r.stdout)[-1500:])
    from . import solvers
    solvers.remember('mystran', EXE)
    return EXE
