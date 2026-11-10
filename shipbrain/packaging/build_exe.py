"""
Build ONE executable of the ShipBrain app (GUI + tools) with PyInstaller.

    pip install pyinstaller numpy gmsh pymupdf
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
       '--collect-all', 'gmsh', '--hidden-import', 'fitz', entry]
try:
    import gmsh  # noqa: F401
except ImportError:
    cmd.remove('--collect-all'), cmd.remove('gmsh')
print(' '.join(cmd))
sys.exit(subprocess.call(cmd, cwd=ROOT))
