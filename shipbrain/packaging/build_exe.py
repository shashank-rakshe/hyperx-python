"""
Build ONE executable of the ShipBrain app (GUI + tools) with PyInstaller.

    pip install pyinstaller numpy scipy cadquery pymupdf
    python packaging/build_exe.py            ->  dist/shipbrain.exe (Windows) or dist/shipbrain (Linux)

Then on the workstation you need just two files:
    shipbrain.exe                 the app (this build)
    shipbrain.llamafile / .gguf   the model (see packaging/make_llamafile.md)
and run:   shipbrain.exe --model shipbrain.llamafile --knowledge D:\\ship_src
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sep = ';' if os.name == 'nt' else ':'
entry = os.path.join(ROOT, 'packaging', '_entry.py')
open(entry, 'w').write('from shipbrain.server import main\nmain()\n')
cmd = [sys.executable, '-m', 'PyInstaller', '--onefile', '--name', 'shipbrain', '--paths', ROOT,
       '--add-data', f"{os.path.join(ROOT, 'shipbrain', 'ui.html')}{sep}shipbrain",
       '--add-data', f"{os.path.join(ROOT, 'examples')}{sep}examples",
       '--hidden-import', 'fitz', '--collect-submodules', 'scipy.spatial', entry]
try:
    import cadquery  # noqa: F401   (large: OCP adds ~300 MB to the exe)
    cmd[-1:-1] = ['--collect-all', 'cadquery', '--collect-all', 'OCP']
except ImportError:
    print('cadquery not installed: the exe will mesh JSON plate assemblies but not STEP files')
print(' '.join(cmd))
sys.exit(subprocess.call(cmd, cwd=ROOT))
